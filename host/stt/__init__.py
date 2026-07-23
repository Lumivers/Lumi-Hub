"""
Lumi-Hub 2.0 — STT (Speech-to-Text) Provider 抽象层
"""
from .provider import BaseSTTProvider
from .whisper_provider import WhisperProvider

__all__ = ["BaseSTTProvider", "WhisperProvider"]
