from __future__ import annotations

import time
import uuid

from astrbot.api import logger


class HistoryHandlersMixin:
    """历史消息处理能力。"""

    async def _handle_history_request(self, message: dict, ws_session_id: str) -> None:
        # 1) 鉴权：历史记录只对已登录用户开放
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            logger.warning("[Lumi-Hub] 拒绝未登录用户的历史记录请求")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "ERROR_ALERT",
                    "source": "host",
                    "target": "client",
                    "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"},
                },
            )
            return

        # 2) 解析分页参数并读取数据库
        payload = message.get("payload", {})
        limit = payload.get("limit", 50)
        offset = payload.get("offset", 0)
        persona_id = payload.get("persona_id", "default")

        messages = self.db.get_messages(
            user_id=user_id,
            persona_id=persona_id,
            limit=limit,
            offset=offset,
        )

        # 3) 按协议返回 HISTORY_RESPONSE
        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "HISTORY_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "messages": messages,
                    "has_more": len(messages) == limit,
                },
            },
        )
