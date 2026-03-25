"""
Lumi-Hub WebSocket Server
负责与 Flutter Client 的 WebSocket 通信。
"""
import asyncio
import json
import uuid
import time
import os
from typing import Dict, Set, Optional, Callable, Awaitable

import websockets
from websockets.server import WebSocketServerProtocol
from astrbot.api import logger


class LumiWSServer:
    """Lumi-Hub WebSocket 服务端，管理与 Client 的连接和消息收发。"""

    def __init__(self, host: str = "0.0.0.0", port: int = 8765):
        self.host = host
        self.port = port
        self.clients: Dict[str, WebSocketServerProtocol] = {}  # session_id -> ws
        self._connected_sessions: Set[str] = set()
        self.server: Optional[websockets.WebSocketServer] = None
        self._message_handler: Optional[Callable[[dict, str], Awaitable[None]]] = None
        self._disconnect_handler: Optional[Callable[[str], Awaitable[None]]] = None
        # 用于等待特定消息 ID 的响应: (session_id, message_id) -> Future
        self._pending_responses: Dict[tuple[str, str], asyncio.Future] = {}
        self._session_last_seen: Dict[str, float] = {}
        self._idle_timeout_seconds = int(os.environ.get("LUMI_WS_IDLE_TIMEOUT", "1800"))
        self._cleanup_task: Optional[asyncio.Task] = None
        self._access_key = os.environ.get("LUMI_WS_ACCESS_KEY", "").strip()
        self._failed_connect: Dict[str, Dict[str, float]] = {}
        self._max_failed_attempts = 5
        self._block_seconds = 300
        self._connect_attempts: Dict[str, list[float]] = {}
        self._connect_rate_window_seconds = int(
            os.environ.get("LUMI_WS_CONNECT_RATE_WINDOW", "60")
        )
        self._connect_rate_max_attempts = int(
            os.environ.get("LUMI_WS_CONNECT_RATE_MAX", "30")
        )

        if self._access_key:
            logger.info("[Lumi-Hub] WS 握手密钥已启用。")
        else:
            logger.warning("[Lumi-Hub] 未设置 LUMI_WS_ACCESS_KEY，当前 CONNECT 握手不校验密钥。")

    def on_message(self, handler: Callable[[dict, str], Awaitable[None]]):
        """注册消息处理回调。handler(message_dict, session_id)"""
        self._message_handler = handler

    def on_disconnect(self, handler: Callable[[str], Awaitable[None]]):
        """注册断连回调。handler(session_id)"""
        self._disconnect_handler = handler

    async def start(self):
        """启动 WebSocket 服务端。"""
        self.server = await websockets.serve(
            self._handle_connection,
            self.host,
            self.port,
            ping_interval=20,
            ping_timeout=10,
        )
        self._cleanup_task = asyncio.create_task(self._cleanup_idle_sessions())
        logger.info(f"[Lumi-Hub] WebSocket Server 已启动: ws://{self.host}:{self.port}")

    async def stop(self):
        """停止 WebSocket 服务端。"""
        if self._cleanup_task and not self._cleanup_task.done():
            self._cleanup_task.cancel()
            try:
                await self._cleanup_task
            except asyncio.CancelledError:
                pass
        if self.server:
            self.server.close()
            await self.server.wait_closed()
            logger.info("[Lumi-Hub] WebSocket Server 已停止")

    async def send_to_client(self, session_id: str, message: dict):
        """向指定 Client 发送消息。"""
        ws = self.clients.get(session_id)
        if ws:
            try:
                await ws.send(json.dumps(message, ensure_ascii=False))
            except Exception as e:
                logger.error(f"[Lumi-Hub] 发送消息失败 (session={session_id}): {e}")

    async def wait_for_response(self, session_id: str, message_id: str, timeout: int = 30) -> Optional[dict]:
        """异步等待某个消息 ID 的响应。"""
        future = asyncio.get_running_loop().create_future()
        key = (session_id, message_id)
        self._pending_responses[key] = future
        
        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            logger.warning(f"[Lumi-Hub] 等待响应超时 (session={session_id}, msg_id={message_id})")
            return None
        finally:
            self._pending_responses.pop(key, None)

    async def broadcast(self, message: dict):
        """向所有已连接的 Client 广播消息。"""
        disconnected = []
        for session_id, ws in self.clients.items():
            try:
                await ws.send(json.dumps(message, ensure_ascii=False))
            except Exception:
                disconnected.append(session_id)
        for sid in disconnected:
            self.clients.pop(sid, None)

    # ---------- 内部方法 ----------

    async def _handle_connection(self, ws: WebSocketServerProtocol):
        """处理单个 WebSocket 连接的完整生命周期。"""
        session_id = str(uuid.uuid4())[:8]
        self.clients[session_id] = ws
        self._session_last_seen[session_id] = time.time()
        remote = ws.remote_address if ws.remote_address else ('unknown', 0)
        client_info = f"{remote[0]}:{remote[1]}"
        logger.info(f"[Lumi-Hub] Client 已连接: {client_info} (session={session_id})")

        try:
            async for raw_message in ws:
                try:
                    message = json.loads(raw_message)
                    await self._dispatch_message(message, session_id)
                except json.JSONDecodeError:
                    logger.warning(f"[Lumi-Hub] 收到无效 JSON (session={session_id})")
                    await self._send_error(session_id, "INVALID_JSON", "消息格式无效，请发送 JSON")
        except websockets.exceptions.ConnectionClosed as e:
            logger.info(f"[Lumi-Hub] Client 断开: {client_info} (code={e.code})")
        except Exception as e:
            logger.error(f"[Lumi-Hub] 连接异常: {client_info} - {e}")
        finally:
            self.clients.pop(session_id, None)
            self._connected_sessions.discard(session_id)
            self._session_last_seen.pop(session_id, None)
            if self._disconnect_handler:
                try:
                    await self._disconnect_handler(session_id)
                except Exception as e:
                    logger.warning(f"[Lumi-Hub] 断连回调执行失败(session={session_id}): {e}")

    def _client_ip(self, ws: WebSocketServerProtocol) -> str:
        remote = ws.remote_address
        if isinstance(remote, tuple) and len(remote) >= 1:
            return str(remote[0])
        return "unknown"

    def _is_blocked(self, ip: str) -> bool:
        state = self._failed_connect.get(ip)
        if not state:
            return False
        blocked_until = state.get("blocked_until", 0)
        return blocked_until > time.time()

    def _record_failed_connect(self, ip: str):
        state = self._failed_connect.get(ip, {"count": 0, "blocked_until": 0})
        state["count"] = int(state.get("count", 0)) + 1
        if state["count"] >= self._max_failed_attempts:
            state["blocked_until"] = time.time() + self._block_seconds
            state["count"] = 0
            logger.warning(f"[Lumi-Hub] IP {ip} 因握手失败被临时封禁 {self._block_seconds} 秒")
        self._failed_connect[ip] = state

    def _reset_failed_connect(self, ip: str):
        if ip in self._failed_connect:
            self._failed_connect.pop(ip, None)

    def _is_rate_limited(self, ip: str) -> bool:
        now = time.time()
        window_start = now - self._connect_rate_window_seconds
        history = self._connect_attempts.get(ip, [])
        history = [ts for ts in history if ts >= window_start]

        if len(history) >= self._connect_rate_max_attempts:
            self._connect_attempts[ip] = history
            return True

        history.append(now)
        self._connect_attempts[ip] = history
        return False

    async def _dispatch_message(self, message: dict, session_id: str):
        """根据消息类型分发处理。"""
        msg_type = message.get("type", "")
        msg_id = message.get("message_id", "")
        ws = self.clients.get(session_id)
        self._session_last_seen[session_id] = time.time()

        # 检查是否是正在等待的响应 (通过让前端回传相同的 message_id 或在 payload 里包含 task_id)
        # 根据 protocol.json, AUTH_RESPONSE 会包含相同的 message_id 或 payload.task_id
        # 这里我们优先检查 message_id
        key = (session_id, msg_id)
        if key in self._pending_responses:
            self._pending_responses[key].set_result(message)
            return

        if ws and self._is_blocked(self._client_ip(ws)):
            await self._send_error(session_id, "CONNECT_BLOCKED", "连接失败次数过多，请稍后再试")
            await ws.close(code=4003, reason="connect blocked")
            return

        # 心跳处理
        if msg_type == "PING":
            if session_id not in self._connected_sessions:
                await self._send_error(session_id, "NOT_CONNECTED", "请先发送 CONNECT 完成握手")
                return
            await self.send_to_client(session_id, {
                "message_id": message.get("message_id", str(uuid.uuid4())),
                "type": "PONG",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {}
            })
            return

        # 连接握手
        if msg_type == "CONNECT":
            logger.info(f"[Lumi-Hub] Client 握手: {message.get('payload', {})}")

            ip = self._client_ip(ws) if ws else "unknown"
            if self._is_rate_limited(ip):
                await self._send_error(
                    session_id,
                    "RATE_LIMITED",
                    "CONNECT 请求过于频繁，请稍后重试",
                )
                if ws:
                    await ws.close(code=4008, reason="connect rate limited")
                return

            if self._access_key:
                payload = message.get("payload", {})
                provided = str(payload.get("access_key", "") or "").strip()
                if provided != self._access_key:
                    self._record_failed_connect(ip)
                    await self._send_error(session_id, "INVALID_ACCESS_KEY", "接入密钥无效")
                    if ws:
                        await ws.close(code=4001, reason="invalid access key")
                    return
                self._reset_failed_connect(ip)

            self._connected_sessions.add(session_id)
            await self.send_to_client(session_id, {
                "message_id": message.get("message_id", str(uuid.uuid4())),
                "type": "CONNECT",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "connected",
                    "session_id": session_id,
                    "server_version": "0.1.0"
                }
            })
            return

        if session_id not in self._connected_sessions:
            await self._send_error(session_id, "NOT_CONNECTED", "请先发送 CONNECT 完成握手")
            return

        # 其余消息交给外部注册的 handler 处理
        if self._message_handler:
            await self._message_handler(message, session_id)
        else:
            logger.warning(f"[Lumi-Hub] 未注册消息处理器，丢弃消息: {msg_type}")

    async def _send_error(self, session_id: str, code: str, detail: str):
        """发送错误响应。"""
        await self.send_to_client(session_id, {
            "message_id": str(uuid.uuid4()),
            "type": "ERROR_ALERT",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "error_code": code,
                "detail": detail
            }
        })

    async def _cleanup_idle_sessions(self):
        while True:
            await asyncio.sleep(30)
            if self._idle_timeout_seconds <= 0:
                continue

            now = time.time()
            expired: list[str] = []
            for session_id, last_seen in list(self._session_last_seen.items()):
                if now - last_seen > self._idle_timeout_seconds:
                    expired.append(session_id)

            for session_id in expired:
                ws = self.clients.get(session_id)
                if ws is None:
                    self._session_last_seen.pop(session_id, None)
                    continue

                await self._send_error(session_id, "SESSION_EXPIRED", "会话空闲超时，请重新连接")
                try:
                    await ws.close(code=4004, reason="session expired")
                except Exception:
                    pass
