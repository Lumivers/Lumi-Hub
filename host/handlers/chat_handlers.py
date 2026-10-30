from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from typing import Any

from ..agent_loop import AgentLoop
from ..native_tools import revert_file as native_revert_file

logger = logging.getLogger("lumi")


class ChatHandlersMixin:
    """负责 CHAT_REQUEST、CHAT_CANCEL、REVERT_FILES 与 APP_STATUS 处理。"""

    async def _handle_chat_request(self, message: dict, ws_session_id: str) -> None:
        """处理 CHAT_REQUEST：创建 AgentLoop 并执行。"""
        payload = message.get("payload", {})
        user_content = payload.get("content", "")
        original_user_content = str(user_content or "").strip()
        attachments = payload.get("attachments", []) or []
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        context_id = payload.get("context_id", ws_session_id)
        persona_id = payload.get("persona_id", "default")
        session_id = payload.get("session_id")
        workspace_path = payload.get("workspace_path", "")

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

        # 确保会话存在
        if session_id:
            sess = self.db.get_or_create_session(
                user_id=user_id,
                session_id=session_id,
                workspace_path=workspace_path,
                persona_id=persona_id,
            )
            if sess.get("workspace_path") and not workspace_path:
                workspace_path = sess["workspace_path"]
        else:
            session_id = f"lumi_hub!{user_id}!{context_id}!{persona_id}"

        # 处理附件
        attachment_lines: list[str] = []
        attachment_hints: list[str] = []
        if isinstance(attachments, list):
            for att in attachments:
                if not isinstance(att, dict):
                    continue
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "application/octet-stream"))
                size_bytes = int(att.get("size_bytes", 0) or 0)
                storage_path = str(att.get("storage_path", "") or "")

                attachment_lines.append(f"- {file_name} ({mime_type}, {size_bytes} bytes)")

                if mime_type == "application/pdf" and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    preview = self._extract_pdf_preview(abs_path)
                    if preview:
                        attachment_hints.append(f"\n[PDF节选: {file_name}]\n{preview}\n")
                    else:
                        attachment_hints.append(
                            f"\n[PDF提示: {file_name}] 当前未能提取 PDF 文本，请先基于文件名和上下文回答。\n"
                        )

        if attachment_lines:
            base = (user_content or "").strip()
            if not base:
                base = "我上传了附件，请先确认接收并根据附件内容回答。"
            user_content = f"{base}\n\n[附件列表]\n" + "\n".join(attachment_lines)
            if attachment_hints:
                user_content += "\n\n" + "\n".join(attachment_hints)

        logger.info(f"[Lumi-Hub] 收到消息 (session={session_id}, persona={persona_id}, ws={ws_session_id}): {user_content[:100]}")

        # 持久化用户消息
        if isinstance(attachments, list) and attachments:
            for att in attachments:
                att = att or {}
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "")).lower()
                local_path = str(att.get("local_path", "") or att.get("storage_path", ""))
                is_img = mime_type.startswith("image/") or file_name.endswith((".png", ".jpg", ".jpeg", ".webp"))
                prefix = "[图片]" if is_img else "[附件]"
                self.db.save_message(
                    user_id=user_id,
                    role="user",
                    content=f"{prefix} {local_path}|||{file_name}",
                    client_msg_id=f"{msg_id}_att_{file_name}",
                    persona_id=persona_id,
                    session_id=session_id,
                    extra=att,
                )

        if original_user_content:
            self.db.save_message(
                user_id=user_id,
                role="user",
                content=original_user_content,
                client_msg_id=msg_id,
                persona_id=persona_id,
                session_id=session_id,
            )

        # 多端实时同频：向该用户的其它在线终端广播该用户消息，同步渲染并做好回声抑制
        sync_msg = {
            "message_id": msg_id,
            "type": "CHAT_MESSAGE_SYNC",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "message_id": msg_id,
                "role": "user",
                "content": original_user_content,
                "session_id": session_id,
                "persona_id": persona_id,
                "attachments": attachments,
            },
        }
        await self.ws_server.broadcast_to_user(
            user_id, sync_msg, exclude_session_id=ws_session_id
        )

        # 获取人格
        persona = await self.persona_manager.get_persona(persona_id)
        if not persona:
            persona = await self.persona_manager.get_persona("default")

        # 获取历史消息
        history = self.db.get_messages(
            user_id=user_id,
            persona_id=persona_id,
            session_id=session_id,
            limit=50,
            offset=0,
        )

        # 如果指定了 Skill，渲染 Skill 提示词
        skill_name = payload.get("skill_name")
        skill_params = payload.get("skill_params", {}) or {}
        skill_prompt = ""

        # 解析 Slash 动作指令与 @Mention 上下文
        command_prompt = ""
        clean_content = original_user_content.strip()
        lower_content = clean_content.lower()

        if clean_content.startswith("/plan"):
            command_prompt = (
                "\n\n[PLAN MODE ACTIVATED]\n"
                "The user explicitly invoked /plan mode. STRICT DIRECTIVE: Do NOT modify code files, delete files, or execute destructive commands yet. "
                "Produce a thorough, structured step-by-step implementation plan including architectural considerations, affected files, potential risks, and verification criteria."
            )
        elif clean_content.startswith("/grill-me"):
            command_prompt = (
                "\n\n[GRILL-ME MODE ACTIVATED]\n"
                "The user explicitly invoked /grill-me mode. STRICT DIRECTIVE: Do NOT write code yet. "
                "Act as a meticulous senior software architect interviewing the user: ask 2-4 critical, high-signal questions to clarify edge cases, requirements, and design trade-offs."
            )
        elif clean_content.startswith("/goal"):
            command_prompt = (
                "\n\n[GOAL MODE ACTIVATED]\n"
                "The user explicitly invoked /goal autonomous mode. Operate with deep self-direction: iterate continuously, run unit tests to verify changes, self-heal on errors, and do not stop until the objective is completely achieved."
            )
        elif clean_content.startswith("/btw"):
            command_prompt = (
                "\n\n[BTW MODE ACTIVATED]\n"
                "The user asked a quick side question (/btw). Answer concisely and directly without altering workspace files or disrupting the ongoing project context."
            )
        elif clean_content.startswith("/code-reviewer"):
            skill_name = "code-reviewer"
        elif clean_content.startswith("/daily-summary"):
            skill_name = "daily-summary"

        # 处理 @Git 提及
        if "@git" in lower_content and workspace_path and os.path.isdir(workspace_path):
            try:
                import subprocess
                git_status = subprocess.run(
                    ["git", "status", "-s"],
                    cwd=workspace_path,
                    capture_output=True,
                    text=True,
                    timeout=3,
                ).stdout
                if git_status:
                    command_prompt += f"\n\n[GIT STATUS CONTEXT]\nWorkspace git status:\n{git_status.strip()}"
            except Exception:
                pass

        # 处理 @Rules 提及
        if "@rules" in lower_content:
            rules_found = []
            if workspace_path:
                for rule_file in [".antigravity/rules", ".cursorrules", "RULES.md"]:
                    rp = os.path.join(workspace_path, rule_file)
                    if os.path.isfile(rp):
                        try:
                            with open(rp, "r", encoding="utf-8") as rf:
                                rules_found.append(f"Rules from {rule_file}:\n{rf.read()[:2000]}")
                        except Exception:
                            pass
            if rules_found:
                command_prompt += f"\n\n[PROJECT RULES CONTEXT]\n" + "\n\n".join(rules_found)

        if skill_name:
            skill_prompt = self.skill_manager.get_skill_prompt(skill_name, skill_params)
        if command_prompt:
            skill_prompt = (skill_prompt + "\n" + command_prompt).strip()

        # 推理思考等级 (low / medium / high)
        req_effort = payload.get("reasoning_effort") or self._reasoning_effort

        # 创建 AgentLoop 并执行
        agent = AgentLoop(
            llm_provider=self.llm,
            tool_registry=self.tool_registry,
            persona_system_prompt=persona.system_prompt if persona else "",
            history_messages=history[:-1] if history else [],  # 排除刚保存的用户消息
            ws_server=self.ws_server,
            ws_session_id=ws_session_id,
            user_id=user_id,
            persona_id=persona_id,
            db=self.db,
            mcp_manager=self.mcp_manager,
            memory_manager=self.memory_manager,
            agent_prompt=self._agent_prompt,
            skill_prompt=skill_prompt,
            msg_id=msg_id,
            session_id=session_id,
            workspace_dir=workspace_path,
            reasoning_effort=req_effort,
        )

        # 记录正在运行的 agent
        agent_key = session_id or ws_session_id
        old_agent = self._active_agents.get(agent_key)
        if old_agent:
            old_agent.cancel()

        self._active_agents[agent_key] = agent
        self._active_agents[ws_session_id] = agent

        async def run_agent_and_cleanup():
            try:
                await agent.run(user_content, attachments)
            finally:
                if self._active_agents.get(agent_key) is agent:
                    self._active_agents.pop(agent_key, None)
                if self._active_agents.get(ws_session_id) is agent:
                    self._active_agents.pop(ws_session_id, None)

        # 异步执行 Agent
        asyncio.create_task(run_agent_and_cleanup())

    async def _handle_chat_cancel(self, message: dict, ws_session_id: str) -> None:
        """处理 CHAT_CANCEL / CHAT_INTERRUPT：打断当前正在执行的 AgentLoop。"""
        payload = message.get("payload", {})
        session_id = payload.get("session_id")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        logger.info(f"[Lumi-Hub] 收到用户打断请求 (session={session_id}, ws={ws_session_id})")

        interrupted = False
        if session_id and session_id in self._active_agents:
            agent = self._active_agents.get(session_id)
            if agent:
                agent.cancel()
                interrupted = True

        for key, agent in list(self._active_agents.items()):
            if agent.ws_session_id == ws_session_id:
                agent.cancel()
                interrupted = True

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "CHAT_RESPONSE_END",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "interrupted": True,
                    "session_id": session_id,
                },
            },
        )

    async def _handle_revert_files(self, message: dict, ws_session_id: str) -> None:
        """处理 REVERT_FILES：批量回退指定文件的代码修改。"""
        msg_id = message.get("message_id", "")
        payload = message.get("payload", {})
        file_paths = payload.get("files", [])
        workspace_path = payload.get("workspace_path") or self._active_workspace
        results = []
        for p in file_paths:
            ok, msg = native_revert_file(p, workspace_dir=workspace_path)
            results.append({"path": p, "success": ok, "message": msg})

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "REVERT_FILES_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "results": results,
                },
            },
        )

    async def _handle_app_status(self, message: dict, ws_session_id: str) -> None:
        """返回应用状态（供客户端检查 LLM 是否已配置等）。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        config = self._load_llm_config()
        api_key = config.get("api_key", "")

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "APP_STATUS_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "version": "2.0.0",
                "llm_configured": bool(api_key),
                "llm_provider": config.get("provider", "openai"),
                "llm_model": config.get("model", ""),
                "active_model_id": config.get("active_model_id", "default"),
                "models": [
                    {
                        "id": m.get("id", ""),
                        "name": m.get("name", m.get("model", "")),
                        "model": m.get("model", ""),
                        "provider": m.get("provider", "openai"),
                    }
                    for m in config.get("models", [])
                ],
            },
        })
