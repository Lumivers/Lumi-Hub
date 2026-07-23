"""
Lumi-Hub 2.0 — STT Provider 抽象基类
"""
from abc import ABC, abstractmethod


class BaseSTTProvider(ABC):
    """STT Provider 抽象基类。"""

    @abstractmethod
    async def transcribe(self, audio_data: bytes, language: str = "zh") -> str:
        """将音频转为文本。

        Args:
            audio_data: 音频数据（PCM/WAV/Opus 格式）
            language: 语言代码（默认中文）

        Returns:
            识别出的文本
        """
        ...
