from __future__ import annotations

import asyncio
import os

from ..base import AudioChunk, TTSRequest, VoiceProviderError, VoiceTTSProvider


class DashScopeTTSProvider(VoiceTTSProvider):
    provider_name = "dashscope"
    output_format = "mp3"
    sample_rate = 24000
    supports_ssml = True

    def __init__(
        self,
        model: str,
        default_voice: str = "",
        api_key_env: str = "DASHSCOPE_API_KEY",
        websocket_url: str = "",
        http_url: str = "",
    ) -> None:
        # 运行期可覆盖 env key，便于前端设置页动态下发。
        self.model = model
        self.default_voice = default_voice
        self.api_key_env = api_key_env
        self.websocket_url = websocket_url
        self.http_url = http_url
        self._runtime_api_key = ""
        self._cancelled_turns: set[tuple[str, str]] = set()
        self._cancel_lock = asyncio.Lock()

    def set_api_key(self, api_key: str | None) -> None:
        self._runtime_api_key = str(api_key or "").strip()

    def _resolve_api_key(self) -> str:
        if self._runtime_api_key:
            return self._runtime_api_key
        return os.environ.get(self.api_key_env, "").strip()

    def has_api_key(self) -> bool:
        return bool(self._resolve_api_key())

    def get_api_key_source(self) -> str:
        if self._runtime_api_key:
            return "runtime"
        if os.environ.get(self.api_key_env, "").strip():
            return "env"
        return "missing"

    def get_masked_api_key(self) -> str:
        key = self._resolve_api_key()
        if not key:
            return ""
        if len(key) <= 8:
            return "*" * len(key)
        return f"{key[:4]}{'*' * (len(key) - 8)}{key[-4:]}"

    async def cancel(self, ws_session_id: str, turn_id: str) -> None:
        async with self._cancel_lock:
            self._cancelled_turns.add((ws_session_id, turn_id))

    async def _is_cancelled(self, ws_session_id: str, turn_id: str) -> bool:
        async with self._cancel_lock:
            return (ws_session_id, turn_id) in self._cancelled_turns

    async def _clear_cancelled(self, ws_session_id: str, turn_id: str) -> None:
        async with self._cancel_lock:
            self._cancelled_turns.discard((ws_session_id, turn_id))

    async def synthesize_stream(self, request: TTSRequest):
        # 主流程：校验 -> 调用 DashScope -> 按 chunk_bytes 切片输出。
        api_key = self._resolve_api_key()
        if not api_key:
            raise VoiceProviderError(
                f"Missing API key. Configure via VOICE_CONFIG_SET or env: {self.api_key_env}"
            )

        voice_id = (request.voice_id or self.default_voice).strip()
        if not voice_id:
            raise VoiceProviderError("voice_id is required for DashScope provider")

        if not (request.ssml if request.use_ssml else request.text).strip():
            raise VoiceProviderError("synthesis text is empty")

        try:
            import dashscope
            from dashscope.audio.tts_v2 import SpeechSynthesizer
        except ImportError as exc:
            raise VoiceProviderError(
                "dashscope package is not installed. Please add it to runtime dependencies."
            ) from exc

        dashscope.api_key = api_key
        if self.websocket_url:
            dashscope.base_websocket_api_url = self.websocket_url
        if self.http_url:
            dashscope.base_http_api_url = self.http_url

        text_to_speak = request.ssml if request.use_ssml and request.ssml else request.text

        def _blocking_call() -> bytes:
            # 官方 SDK 同步调用，放在线程池中避免阻塞事件循环。
            synthesizer = SpeechSynthesizer(model=self.model, voice=voice_id)
            return synthesizer.call(text_to_speak)

        try:
            audio_data = await asyncio.to_thread(_blocking_call)
        except Exception as exc:
            if "WebSocketApp" in str(exc):
                raise VoiceProviderError(
                    "Python websocket package conflict detected. "
                    "Please uninstall 'websocket' and keep 'websocket-client': "
                    "pip uninstall websocket ; pip install -U websocket-client"
                ) from exc
            raise

        if await self._is_cancelled(request.ws_session_id, request.turn_id):
            await self._clear_cancelled(request.ws_session_id, request.turn_id)
            return

        # 限制分片大小范围，兼顾延迟和传输开销。
        chunk_size = max(4096, min(int(request.chunk_bytes or 32768), 262144))
        seq = 0
        for offset in range(0, len(audio_data), chunk_size):
            if await self._is_cancelled(request.ws_session_id, request.turn_id):
                break
            yield AudioChunk(seq=seq, data=audio_data[offset: offset + chunk_size])
            seq += 1

        await self._clear_cancelled(request.ws_session_id, request.turn_id)
