from __future__ import annotations

import time
import uuid
import logging
logger = logging.getLogger("lumi")


class SessionHandlersMixin:
    """工作区与会话处理能力。"""

    async def _handle_session_list(self, message: dict, ws_session_id: str) -> None:
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            logger.warning("[Lumi-Hub] 拒绝未登录用户的会话列表请求")
            return

        payload = message.get("payload", {})
        workspace_path = payload.get("workspace_path")
        sessions = self.db.list_sessions(user_id=user_id, workspace_path=workspace_path)

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "SESSION_LIST_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "sessions": sessions,
                    "workspace_path": workspace_path,
                },
            },
        )

    async def _handle_session_create(self, message: dict, ws_session_id: str) -> None:
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            return

        payload = message.get("payload", {})
        workspace_path = payload.get("workspace_path", "")
        title = payload.get("title", "新对话")
        persona_id = payload.get("persona_id", "default")

        session_dict = self.db.create_session(
            user_id=user_id,
            workspace_path=workspace_path,
            title=title,
            persona_id=persona_id,
        )

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "SESSION_CREATE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "session": session_dict,
                },
            },
        )

    async def _handle_session_update(self, message: dict, ws_session_id: str) -> None:
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            return

        payload = message.get("payload", {})
        session_id = payload.get("session_id")
        if not session_id:
            return

        ok = self.db.update_session(
            session_id=session_id,
            title=payload.get("title"),
            persona_id=payload.get("persona_id"),
            workspace_path=payload.get("workspace_path"),
        )

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "SESSION_UPDATE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "session_id": session_id,
                    "status": "success" if ok else "error",
                },
            },
        )

    async def _handle_session_delete(self, message: dict, ws_session_id: str) -> None:
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            return

        payload = message.get("payload", {})
        session_id = payload.get("session_id")
        if not session_id:
            return

        ok = self.db.delete_session(user_id=user_id, session_id=session_id)

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "SESSION_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "session_id": session_id,
                    "status": "success" if ok else "error",
                },
            },
        )
