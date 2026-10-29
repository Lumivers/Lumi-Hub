from __future__ import annotations

import logging
import time
import uuid
from typing import Any

logger = logging.getLogger("lumi")


class MemorySkillHandlersMixin:
    """负责记忆档案与技能系统的请求分发。"""

    async def _send_unauthorized(self, ws_session_id: str, msg_id: str):
        """发送 401 未认证提示。"""
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "ERROR_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "error",
                "code": 401,
                "message": "Unauthorized: Please login first",
            },
        })

    # ========== 记忆系统接口 ==========

    async def _handle_memory_list(self, message: dict, ws_session_id: str) -> None:
        """获取指定人格的记忆列表。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        category = payload.get("category")

        memories = self.memory_manager.list_memories(user_id, persona_id, category)
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_LIST_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "success",
                "persona_id": persona_id,
                "memories": memories,
            },
        })

    async def _handle_memory_add(self, message: dict, ws_session_id: str) -> None:
        """手动添加记忆。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        category = payload.get("category", "fact")
        content = str(payload.get("content", "")).strip()

        if not content:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "MEMORY_ADD_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Content cannot be empty"},
            })
            return

        self.memory_manager.add_memory(user_id, persona_id, category, content)
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_ADD_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success"},
        })

    async def _handle_memory_delete(self, message: dict, ws_session_id: str) -> None:
        """删除单条记忆。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        memory_id = payload.get("memory_id")
        if memory_id is not None:
            self.memory_manager.forget_memory(int(memory_id), user_id)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_DELETE_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "memory_id": memory_id},
        })

    async def _handle_memory_clear(self, message: dict, ws_session_id: str) -> None:
        """清空指定人格的所有记忆。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        count = self.memory_manager.clear_memories(user_id, persona_id)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_CLEAR_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "cleared_count": count},
        })

    # ========== 技能系统接口 ==========

    async def _handle_skill_list(self, message: dict, ws_session_id: str) -> None:
        """获取所有已安装技能列表。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        skills = self.skill_manager.list_skills()

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "SKILL_LIST_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "skills": skills},
        })

    async def _handle_skill_install(self, message: dict, ws_session_id: str) -> None:
        """从 Git 仓库安装技能。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        git_url = payload.get("git_url", "").strip()

        if not git_url:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "SKILL_INSTALL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "git_url is required"},
            })
            return

        skill = await self.skill_manager.install_from_git(git_url)
        if skill:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "SKILL_INSTALL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "skill": {
                        "name": skill.name,
                        "version": skill.version,
                        "author": skill.author,
                        "description": skill.description,
                        "icon": skill.icon,
                        "params": skill.params_schema,
                    },
                },
            })
        else:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "SKILL_INSTALL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Failed to install skill from repository"},
            })

    async def _handle_skill_uninstall(self, message: dict, ws_session_id: str) -> None:
        """卸载指定技能。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        skill_name = payload.get("skill_name", "").strip()

        success = await self.skill_manager.uninstall(skill_name)
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "SKILL_UNINSTALL_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success" if success else "error", "skill_name": skill_name},
        })
