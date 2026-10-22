from __future__ import annotations

import time
import uuid

import logging
logger = logging.getLogger("lumi")


class AuthHandlersMixin:
    async def _handle_auth_register(self, message: dict, ws_session_id: str) -> None:
        # 注册成功后立即建立 active_sessions 绑定。
        payload = message.get("payload", {})
        username = payload.get("username", "")
        password = payload.get("password", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        try:
            result = self.db.create_user(username, password)
        except Exception as e:
            logger.error(f"[Lumi-Hub] 注册时数据库异常: {e}")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "AUTH_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": f"Server error: {e}"},
                },
            )
            return

        if "error" in result:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "AUTH_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": result["error"]},
                },
            )
        else:
            self.active_sessions[ws_session_id] = result["id"]
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "AUTH_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {
                        "status": "success",
                        "user": {"id": result["id"], "username": result["username"]},
                        "token": result.get("token", ""),
                    },
                },
            )
            logger.info(f"[Lumi-Hub] 用户注册并登录成功: {username}")

    async def _handle_auth_login(self, message: dict, ws_session_id: str) -> None:
        # 登录成功会刷新 token（在 DB 层处理），并同步到当前 WS 会话。
        payload = message.get("payload", {})
        username = payload.get("username", "")
        password = payload.get("password", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        try:
            result = self.db.verify_user(username, password)
        except Exception as e:
            logger.error(f"[Lumi-Hub] 登录时数据库异常: {e}")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "AUTH_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": f"Server error: {e}"},
                },
            )
            return

        if "error" in result:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "AUTH_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": result["error"]},
                },
            )
        else:
            self.active_sessions[ws_session_id] = result["id"]
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "AUTH_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {
                        "status": "success",
                        "user": {"id": result["id"], "username": result["username"]},
                        "token": result.get("token", ""),
                    },
                },
            )
            logger.info(f"[Lumi-Hub] 用户登录成功: {username}")

    async def _handle_auth_restore(self, message: dict, ws_session_id: str) -> None:
        # 单机免密支持：若 token 有效则使用对应用户；若 token 为空或失效，自动回退到默认本地用户
        payload = message.get("payload", {})
        token = payload.get("token", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        user = None
        if token:
            user = self.db.get_user_by_token(token)

        if not user:
            user = self.db.get_or_create_default_user()

        self.active_sessions[ws_session_id] = user["id"]
        actual_token = user.get("token") or token
        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "AUTH_RESPONSE",
                "source": "host",
                "target": "client",
                "payload": {
                    "status": "success",
                    "user": {"id": user["id"], "username": user["username"]},
                    "token": actual_token,
                },
            },
        )
        logger.info(f"[Lumi-Hub] 用户会话恢复成功: {user['username']} (ID: {user['id']})")
