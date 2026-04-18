from __future__ import annotations

from typing import Optional

from .base import VoiceTTSProvider


class VoiceExtensionRegistry:
    def __init__(self) -> None:
        # provider_name -> provider 实例
        self._tts_providers: dict[str, VoiceTTSProvider] = {}
        self._default_tts_provider: str = ""

    def register_tts(self, name: str, provider: VoiceTTSProvider) -> None:
        key = (name or "").strip().lower()
        if not key:
            raise ValueError("TTS provider name must not be empty")
        self._tts_providers[key] = provider

    def set_default_tts(self, name: str) -> None:
        key = (name or "").strip().lower()
        if key not in self._tts_providers:
            raise KeyError(f"TTS provider not registered: {name}")
        self._default_tts_provider = key

    def get_tts(self, name: str | None = None) -> Optional[VoiceTTSProvider]:
        key = (name or "").strip().lower()
        if key:
            return self._tts_providers.get(key)
        if self._default_tts_provider:
            return self._tts_providers.get(self._default_tts_provider)
        return None

    def list_tts(self) -> list[str]:
        return sorted(self._tts_providers.keys())

    async def cancel_all(self, ws_session_id: str, turn_id: str) -> None:
        # 广播中断请求给全部 provider，保持行为一致。
        for provider in self._tts_providers.values():
            await provider.cancel(ws_session_id, turn_id)
