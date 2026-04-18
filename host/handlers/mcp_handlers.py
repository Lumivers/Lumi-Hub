from __future__ import annotations

import uuid

from astrbot.api import logger


class McpHandlersMixin:
    async def _handle_mcp_config_get(self, message: dict, ws_session_id: str) -> None:
        """获取当前 MCP 配置"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        mcp_manager = self._shared_state.get("mcp_manager")

        if mcp_manager:
            config = mcp_manager.get_config()
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "MCP_CONFIG_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "success", "config": config},
                },
            )
        else:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "MCP_CONFIG_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": "MCP Manager not initialized"},
                },
            )

    async def _handle_mcp_config_update(self, message: dict, ws_session_id: str) -> None:
        """更新并热重载 MCP 配置"""
        payload = message.get("payload", {})
        config = payload.get("config", {})
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        mcp_manager = self._shared_state.get("mcp_manager")
        if mcp_manager:
            try:
                await mcp_manager.update_config(config)
                await self.ws_server.send_to_client(
                    ws_session_id,
                    {
                        "message_id": msg_id,
                        "type": "MCP_CONFIG_UPDATE_RESPONSE",
                        "source": "host",
                        "target": "client",
                        "payload": {
                            "status": "success",
                            "message": "Config updated and servers hot-reloaded",
                        },
                    },
                )
            except Exception as e:
                logger.error(f"[Lumi-Hub] 热重载 MCP 失败: {e}")
                await self.ws_server.send_to_client(
                    ws_session_id,
                    {
                        "message_id": msg_id,
                        "type": "MCP_CONFIG_UPDATE_RESPONSE",
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
                    "type": "MCP_CONFIG_UPDATE_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "payload": {"status": "error", "message": "MCP Manager not initialized"},
                },
            )
