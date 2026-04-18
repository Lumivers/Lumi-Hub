from .base import (
    AudioChunk,
    SpeechStylePlan,
    TTSRequest,
    VoiceProviderError,
    VoiceTTSProvider,
)
from .registry import VoiceExtensionRegistry
from .session import SpeechSessionController
from .planner import plan_style_for_text
from .ssml import build_style_plan, compile_ssml
from .providers import DashScopeTTSProvider

# 统一导出语音扩展对外 API，供 handlers 侧直接引用。
__all__ = [
    "AudioChunk",
    "DashScopeTTSProvider",
    "SpeechSessionController",
    "SpeechStylePlan",
    "TTSRequest",
    "VoiceExtensionRegistry",
    "VoiceProviderError",
    "VoiceTTSProvider",
    "plan_style_for_text",
    "build_style_plan",
    "compile_ssml",
]
