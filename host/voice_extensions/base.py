from __future__ import annotations

import abc
from dataclasses import dataclass, field
from typing import AsyncGenerator


@dataclass(slots=True)
class SpeechStylePlan:
    rate: float = 1.0
    pitch: float = 1.0
    volume: int = 50
    effect: str = ""
    effect_value: str = ""
    leading_break_ms: int = 0
    trailing_break_ms: int = 0
    auto_break: bool = False
    comma_break_ms: int = 120
    sentence_break_ms: int = 220
    say_as: list[dict[str, str]] = field(default_factory=list)
    phoneme: list[dict[str, str]] = field(default_factory=list)


@dataclass(slots=True)
class TTSRequest:
    ws_session_id: str
    turn_id: str
    request_id: str
    text: str
    voice_id: str = ""
    use_ssml: bool = False
    ssml: str = ""
    style_plan: SpeechStylePlan | None = None
    chunk_bytes: int = 32768


@dataclass(slots=True)
class AudioChunk:
    seq: int
    data: bytes


class VoiceProviderError(RuntimeError):
    pass


class VoiceTTSProvider(abc.ABC):
    provider_name: str = "unknown"
    output_format: str = "mp3"
    sample_rate: int = 24000
    supports_ssml: bool = False

    @abc.abstractmethod
    async def synthesize_stream(self, request: TTSRequest) -> AsyncGenerator[AudioChunk, None]:
        raise NotImplementedError

    async def cancel(self, ws_session_id: str, turn_id: str) -> None:
        return None
