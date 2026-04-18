from __future__ import annotations

import asyncio
import os
import time
import uuid

from astrbot.api import logger
from astrbot.core.message.components import Image, Plain, Video
from astrbot.core.platform import AstrBotMessage, MessageMember, MessageType

from ..lumi_event import LumiMessageEvent


class ChatHandlersMixin:
    async def _handle_chat_request(self, message: dict, ws_session_id: str) -> None:
        """
        处理 CHAT_REQUEST：
        1. 构造 AstrBotMessage
        2. 包装为 LumiMessageEvent
        3. commit_event() 注入 AstrBot 事件队列
        4. AstrBot 自动调 LLM -> 调用 event.send() -> WebSocket 回传
        """
        payload = message.get("payload", {})
        user_content = payload.get("content", "")
        original_user_content = str(user_content or "").strip()
        attachments = payload.get("attachments", []) or []
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        context_id = payload.get("context_id", ws_session_id)
        persona_id = payload.get("persona_id", "default")

        attachment_lines: list[str] = []
        attachment_hints: list[str] = []
        image_components: list[Image] = []
        video_components: list[Video] = []
        if isinstance(attachments, list):
            for att in attachments:
                if not isinstance(att, dict):
                    continue
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "application/octet-stream"))
                size_bytes = int(att.get("size_bytes", 0) or 0)
                storage_path = str(att.get("storage_path", "") or "")

                attachment_lines.append(
                    f"- {file_name} ({mime_type}, {size_bytes} bytes)"
                )

                if mime_type.startswith("image/") and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    if os.path.exists(abs_path):
                        try:
                            image_components.append(Image.fromFileSystem(abs_path))
                        except Exception as e:
                            logger.warning(f"[Lumi-Hub] 附加图片组件失败({file_name}): {e}")

                if mime_type.startswith("video/") and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    if os.path.exists(abs_path):
                        try:
                            video_components.append(Video.fromFileSystem(abs_path))
                        except Exception as e:
                            logger.warning(f"[Lumi-Hub] 附加视频组件失败({file_name}): {e}")

                if mime_type == "application/pdf" and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    preview = self._extract_pdf_preview(abs_path)
                    if preview:
                        attachment_hints.append(
                            f"\n[PDF节选: {file_name}]\n{preview}\n"
                        )
                    else:
                        attachment_hints.append(
                            f"\n[PDF提示: {file_name}] 当前未能提取 PDF 文本，请先基于文件名和上下文回答，并提示用户可粘贴关键段落。\n"
                        )

        if attachment_lines:
            base = (user_content or "").strip()
            if not base:
                base = "我上传了附件，请先确认接收并根据附件内容回答。"
            user_content = (
                f"{base}\n\n"
                f"[附件列表]\n" + "\n".join(attachment_lines)
            )
            if image_components or video_components:
                user_content += (
                    "\n\n[提示] 多媒体附件已作为原始文件随消息提供，请直接识别内容，"
                    "不要调用 fetch_url 访问 file:// 本地路径。"
                )
            if attachment_hints:
                user_content += "\n\n" + "\n".join(attachment_hints)

        logger.info(f"[Lumi-Hub] 收到消息 (session={ws_session_id}, persona={persona_id}): {user_content}")

        # 鉴权校验
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            logger.warning("[Lumi-Hub] 未登录用户尝试发送消息，已拒绝")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "ERROR_ALERT",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"},
                },
            )
            return

        # 把附件作为独立消息存入数据库，与前端拆分展示逻辑对齐
        if isinstance(attachments, list) and attachments:
            for att in attachments:
                att = att or {}
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "")).lower()
                local_path = str(att.get("local_path", "") or att.get("storage_path", ""))

                is_img = mime_type.startswith("image/") or file_name.endswith(
                    (".png", ".jpg", ".jpeg", ".webp")
                )
                prefix = "[图片]" if is_img else "[附件]"

                self.db.save_message(
                    user_id=user_id,
                    role="user",
                    content=f"{prefix} {local_path}|||{file_name}",
                    client_msg_id=f"{msg_id}_att_{file_name}",
                    persona_id=persona_id,
                )

        if original_user_content:
            self.db.save_message(
                user_id=user_id,
                role="user",
                content=original_user_content,
                client_msg_id=msg_id,
                persona_id=persona_id,
            )

        # 确保 AstrBot 当前的默认人格是用户正在对话的人格
        pm = self._shared_state.get("persona_manager")
        if pm:
            try:
                pm.default_persona = persona_id
            except Exception as e:
                logger.error(f"[Lumi-Hub] 同步人格状态失败: {e}")

        # 1. 构造 AstrBotMessage（和 WebChatAdapter 做法一致）
        abm = AstrBotMessage()
        abm.self_id = "lumi_hub"
        # 使用绑定的真实账号 user_id 而不是动态 session_id 作为识别，让大模型持久记忆用户
        abm.sender = MessageMember(user_id=str(user_id), nickname=f"User_{user_id}")
        abm.type = MessageType.FRIEND_MESSAGE
        # SessionID 格式: lumi_hub!user_id!context_id!persona_id
        abm.session_id = f"lumi_hub!{user_id}!{context_id}!{persona_id}"
        abm.message_id = msg_id
        abm_message_chain = [Plain(user_content)]
        if image_components:
            abm_message_chain.extend(image_components)
        if video_components:
            abm_message_chain.extend(video_components)

        abm.message = abm_message_chain
        abm.message_str = user_content
        abm.raw_message = message
        abm.timestamp = int(time.time())

        # 2. 包装为 LumiMessageEvent
        event = LumiMessageEvent(
            message_str=user_content,
            message_obj=abm,
            platform_meta=self.metadata,
            session_id=abm.session_id,
            ws_server=self.ws_server,
            ws_session_id=ws_session_id,
            db=self.db,
            user_id=user_id,
            persona_id=persona_id,
        )

        # 3. 注入 AstrBot 事件队列（EventBus 会自动 handle、调 LLM、调 event.send()）
        self.commit_event(event)
        logger.info(f"[Lumi-Hub] 事件已提交到 AstrBot 队列 (msg_id={msg_id})")

        # 4. 后台轮询跟踪该事件的生命周期，待其跑完整个 Pipeline 后发送 CHAT_RESPONSE_END 给客户端解锁UI
        async def wait_for_event_completion() -> None:
            # 阶段 A: 等待 EventBus 从 _event_queue 中读取并转移到 active_event_registry
            while True:
                if event not in self._event_queue._queue:
                    break
                await asyncio.sleep(0.1)

            # 给 Scheduler 注册事件留出一点点时间
            await asyncio.sleep(0.2)

            # 阶段 B: 等待 PipelineScheduler 彻底释放该活跃事件
            try:
                from astrbot.core.utils.active_event_registry import active_event_registry

                umo = event.unified_msg_origin
                while True:
                    active_events = active_event_registry._events.get(umo, set())
                    if event not in active_events:
                        break
                    await asyncio.sleep(0.5)
            except Exception as e:
                logger.warning(f"[Lumi-Hub] 跟踪事件生命周期时出错: {e}，将立即解锁。")

            # 阶段 C: 事件生命周期完全结束，发送解锁信号
            logger.debug(f"[Lumi-Hub] 消息 (msg_id={msg_id}) 管道执行已彻底结束，发送 CHAT_RESPONSE_END")
            try:
                await self.ws_server.send_to_client(
                    ws_session_id,
                    {
                        "message_id": msg_id,
                        "type": "CHAT_RESPONSE_END",
                        "source": "host",
                        "target": "client",
                        "timestamp": int(time.time() * 1000),
                        "payload": {"status": "success"},
                    },
                )
            except Exception as e:
                logger.error(f"[Lumi-Hub] 发送 CHAT_RESPONSE_END 失败: {e}")

        asyncio.create_task(wait_for_event_completion())
