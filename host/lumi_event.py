"""
Lumi-Hub 自定义消息事件
继承 AstrMessageEvent，重写 send() 和 send_streaming()，
将 AstrBot 的 LLM 回复通过 WebSocket 转发回 Flutter Client。
"""
import json
import uuid
import time
from collections.abc import AsyncGenerator

from astrbot.api import logger
from astrbot.core.platform.astr_message_event import AstrMessageEvent
from astrbot.core.message.message_event_result import MessageChain
from astrbot.core.message.components import Plain, Image


class LumiMessageEvent(AstrMessageEvent):
    """Lumi-Hub 的消息事件。

    AstrBot EventBus 处理完消息后，会调用 event.send() 或 event.send_streaming()
    发送回复。我们在这里将回复转为 JSON，通过 WebSocket 发回给 Client。
    """

    def __init__(
        self,
        message_str: str,
        message_obj,
        platform_meta,
        session_id: str,
        ws_server=None,
        ws_session_id: str = "",
        db=None,
        user_id: int = None,
        persona_id: str = "default",
    ) -> None:
        super().__init__(message_str, message_obj, platform_meta, session_id)
        self._ws_server = ws_server
        self._ws_session_id = ws_session_id
        self._db = db
        self._user_id = user_id
        self._persona_id = persona_id

    def _chain_to_text(self, chain: MessageChain) -> str:
        """将 MessageChain 转为纯文本。"""
        parts = []
        for comp in chain.chain:
            if isinstance(comp, Plain):
                parts.append(comp.text)
            elif isinstance(comp, Image):
                parts.append("[图片]")
            else:
                parts.append(f"[{comp.type}]")
        return "".join(parts)

    async def send(self, message: MessageChain) -> None:
        """AstrBot 调用此方法发送回复。我们将其转发到 WebSocket Client。"""
        if not self._ws_server or not self._ws_session_id:
            logger.warning("[Lumi-Hub] 无法发送回复：ws_server 或 ws_session_id 未设置")
            return

        text = self._chain_to_text(message)
        if not text.strip():
            logger.info("[Lumi-Hub] 跳过空回复，避免写入空 assistant 消息")
            return
            
        # 当前策略：直接透传标准 CHAT_RESPONSE 包给前端。

        response = {
            "message_id": getattr(self.message_obj, "message_id", str(uuid.uuid4())),
            "type": "CHAT_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "content": text,
                "status": "success",
                "persona": self._persona_id,
            },
        }

        if self._db and self._user_id:
            # assistant 消息持久化到 DB，供历史记录分页读取。
            self._db.save_message(
                user_id=self._user_id,
                role="assistant",
                content=text,
                client_msg_id=f"{getattr(self.message_obj, 'message_id', str(uuid.uuid4()))}_ai",
                persona_id=self._persona_id,
            )

        logger.info(f"[Lumi-Hub] 发送 LLM 回复 (session={self._ws_session_id}): {text[:80]}{'...' if len(text) > 80 else ''}") 
        await self._ws_server.send_to_client(self._ws_session_id, response)

    async def send_streaming(
        self, generator: AsyncGenerator[MessageChain, None], use_fallback: bool = False
    ) -> None:
        """处理流式 LLM 输出，逐块发送 CHAT_STREAM_CHUNK。"""
        if not self._ws_server or not self._ws_session_id:
            logger.warning("[Lumi-Hub] 无法发送流式回复")
            return

        msg_id = getattr(self.message_obj, "message_id", str(uuid.uuid4()))
        chunk_index = 0
        full_text = ""

        async for chain in generator:
            chunk_text = self._chain_to_text(chain)
            if not chunk_text:
                continue

            full_text += chunk_text

            chunk_msg = {
                "message_id": msg_id,
                "type": "CHAT_STREAM_CHUNK",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "chunk": chunk_text,
                    "index": chunk_index,
                    "finished": False,
                },
            }

            await self._ws_server.send_to_client(self._ws_session_id, chunk_msg)
            chunk_index += 1

        # 发送完成标记，告知前端结束流式拼接。
        finish_msg = {
            "message_id": msg_id,
            "type": "CHAT_STREAM_CHUNK",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "chunk": "",
                "index": chunk_index,
                "finished": True,
            },
        }
        await self._ws_server.send_to_client(self._ws_session_id, finish_msg)

        # 发送最终聚合文本，兼容依赖完整响应的前端逻辑。
        final_msg = {
            "message_id": msg_id,
            "type": "CHAT_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "content": full_text,
                "status": "success",
                "persona": self._persona_id,
            },
        }
        
        if self._db and self._user_id:
            self._db.save_message(
                user_id=self._user_id,
                role="assistant",
                content=full_text,
                client_msg_id=f"{msg_id}_ai",
                persona_id=self._persona_id,
            )

        await self._ws_server.send_to_client(self._ws_session_id, final_msg)

        logger.info(f"[Lumi-Hub] 流式回复完成 (session={self._ws_session_id}): {full_text[:80]}...")
        # 不再向父类二次回传，避免重复输出与额外延迟。

    async def wait_for_auth(self, action_type: str, target_path: str, description: str, tool_name: str = "", diff_preview: str = "") -> bool:
        """
        向客户端发送 AUTH_REQUIRED 并等待 AUTH_RESPONSE。
        返回 True 表示已获批准，False 表示拒绝或超时。
        """
        if not self._ws_server or not self._ws_session_id:
            logger.error("[Lumi-Hub] 无法申请审批：未连接到 WebSocket")
            return False

        auth_msg_id = f"auth-{str(uuid.uuid4())[:8]}"
        
        auth_req = {
            "message_id": auth_msg_id,
            "type": "AUTH_REQUIRED",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "task_id": auth_msg_id, # 这里 task_id 和 message_id 保持一致，方便追踪
                "action_type": action_type,
                "risk_level": "HIGH",
                "target_path": target_path,
                "description": description,
                "tool_name": tool_name,
                "diff_preview": diff_preview,
                "timeout_seconds": 60
            }
        }

        logger.info(f"[Lumi-Hub] 已发送审批请求 ({action_type}): {target_path}")
        await self._ws_server.send_to_client(self._ws_session_id, auth_req)

        # 进入异步等待：基于 message_id 关联审批结果。
        resp = await self._ws_server.wait_for_response(self._ws_session_id, auth_msg_id, timeout=60)
        
        if not resp:
            logger.warning(f"[Lumi-Hub] 审批超时或无响应: {action_type}")
            return False
            
        payload = resp.get("payload", {})
        decision = payload.get("decision", "REJECTED")
        
        if decision == "APPROVED":
            logger.info(f"[Lumi-Hub] 用户已批准操作: {action_type}")
            return True
        else:
            logger.warning(f"[Lumi-Hub] 用户拒绝了操作: {action_type}")
            return False
