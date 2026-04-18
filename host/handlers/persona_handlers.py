from __future__ import annotations

import time
import uuid

from astrbot.api import logger
from astrbot.core import db_helper


class PersonaHandlersMixin:
    async def _handle_persona_switch(self, message: dict, ws_session_id: str) -> None:
        """处理人格切换请求：真实切换 AstrBot 的默认人格。"""
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        pm = self._shared_state.get("persona_manager")
        if pm:
            try:
                pm.default_persona = persona_id
                logger.info(f"[Lumi-Hub] 人格已切换至: {persona_id}")
                status = "switched"
            except Exception as e:
                logger.error(f"[Lumi-Hub] 切换人格失败: {e}")
                status = "error"
        else:
            logger.warning("[Lumi-Hub] persona_manager 未初始化，无法切换人格")
            status = "error"

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "PERSONA_SWITCH",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"persona_id": persona_id, "status": status},
            },
        )

    async def _handle_persona_clear_history(self, message: dict, ws_session_id: str) -> None:
        """清空当前登录用户的所有聊天记录。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")

        if not user_id:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "PERSONA_CLEAR_HISTORY_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": "未登录"},
                },
            )
            return
        try:
            count = self.db.clear_messages(user_id, persona_id)
            logger.info(f"[Lumi-Hub] 用户 {user_id} 对人格 {persona_id} 的聊天记录已清空，共 {count} 条")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "PERSONA_CLEAR_HISTORY_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "success", "deleted_count": count},
                },
            )
        except Exception as e:
            logger.error(f"[Lumi-Hub] 清空聊天记录失败: {e}")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "PERSONA_CLEAR_HISTORY_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": str(e)},
                },
            )

    async def _handle_message_delete(self, message: dict, ws_session_id: str) -> None:
        """删除当前登录用户在指定人格下的指定消息。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        message_ids = payload.get("message_ids", [])

        if not user_id:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "MESSAGE_DELETE_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": "未登录"},
                },
            )
            return

        if not isinstance(message_ids, list) or not message_ids:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "MESSAGE_DELETE_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": "message_ids 不能为空"},
                },
            )
            return

        try:
            deleted_count = self.db.delete_messages(
                user_id=user_id,
                message_ids=message_ids,
                persona_id=persona_id,
            )
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "MESSAGE_DELETE_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "success", "deleted_count": deleted_count},
                },
            )
        except Exception as e:
            logger.error(f"[Lumi-Hub] 删除消息失败: {e}")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "MESSAGE_DELETE_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": str(e)},
                },
            )

    async def _handle_persona_delete(self, message: dict, ws_session_id: str) -> None:
        """从 AstrBot 中删除指定人格。"""
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        pm = self._shared_state.get("persona_manager")
        if pm and persona_id:
            try:
                await pm.delete_persona(persona_id)
                logger.info(f"[Lumi-Hub] 人格 '{persona_id}' 已删除")
                await self.ws_server.send_to_client(
                    ws_session_id,
                    {
                        "message_id": msg_id,
                        "type": "PERSONA_DELETE_RESPONSE",
                        "source": "host",
                        "target": "client",
                        "payload": {"status": "success", "persona_id": persona_id},
                    },
                )
            except Exception as e:
                logger.error(f"[Lumi-Hub] 删除人格 '{persona_id}' 失败: {e}")
                await self.ws_server.send_to_client(
                    ws_session_id,
                    {
                        "message_id": msg_id,
                        "type": "PERSONA_DELETE_RESPONSE",
                        "source": "host",
                        "target": "client",
                        "payload": {"status": "error", "message": str(e)},
                    },
                )
        else:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "PERSONA_DELETE_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {
                        "status": "error",
                        "message": "persona_manager 未初始化或 persona_id 为空",
                    },
                },
            )

    async def _handle_persona_list(self, message: dict, ws_session_id: str) -> None:
        """返回 AstrBot 中已有的人格列表。"""
        try:
            personas = await db_helper.get_personas()
            persona_list = []
            for p in personas:
                persona_list.append(
                    {
                        "id": p.persona_id,
                        "name": p.persona_id,
                        "system_prompt_preview": (p.system_prompt[:200] + "...")
                        if len(p.system_prompt) > 200
                        else p.system_prompt,
                        "has_begin_dialogs": bool(p.begin_dialogs),
                        "tools": p.tools,
                        "skills": p.skills,
                    }
                )
            logger.info(f"[Lumi-Hub] 返回 {len(persona_list)} 个人格")
        except Exception as e:
            logger.error(f"[Lumi-Hub] 读取人格列表失败: {e}")
            persona_list = []

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": message.get("message_id", str(uuid.uuid4())[:8]),
                "type": "PERSONA_LIST",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "personas": persona_list,
                },
            },
        )
