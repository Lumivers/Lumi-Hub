"""
Lumi-Hub 2.0 — Whisper 本地 STT Provider
使用 OpenAI 的 Whisper 模型进行本地语音识别。
"""
import logging
import tempfile
import os

from .provider import BaseSTTProvider

logger = logging.getLogger("lumi")


class WhisperProvider(BaseSTTProvider):
    """Whisper 本地语音识别。

    优点：
    - 完全本地运行，无需联网
    - 支持多种语言
    - 识别质量高

    缺点：
    - 首次加载模型较慢
    - 需要较大的磁盘空间（base 模型 ~150MB）
    """

    def __init__(self, model_size: str = "base"):
        """
        Args:
            model_size: 模型大小 tiny/base/small/medium/large
        """
        self._model_size = model_size
        self._model = None

    def _get_model(self):
        """延迟加载 Whisper 模型。"""
        if self._model is None:
            try:
                import whisper
                logger.info(f"[Whisper] 正在加载模型 '{self._model_size}'...")
                self._model = whisper.load_model(self._model_size)
                logger.info(f"[Whisper] 模型加载完成")
            except ImportError:
                raise RuntimeError("openai-whisper 未安装，请运行: pip install openai-whisper")
            except Exception as e:
                raise RuntimeError(f"Whisper 模型加载失败: {e}")
        return self._model

    async def transcribe(self, audio_data: bytes, language: str = "zh") -> str:
        """使用 Whisper 识别音频。"""
        model = self._get_model()

        # 写入临时文件
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(audio_data)
            tmp_path = tmp.name

        try:
            import whisper
            # 转为 Whisper 要求的格式
            audio = whisper.load_audio(tmp_path)
            audio = whisper.pad_or_trim(audio)

            # 识别
            result = model.transcribe(tmp_path, language=language)
            text = result.get("text", "").strip()
            logger.info(f"[Whisper] 识别结果: {text[:50]}...")
            return text
        except Exception as e:
            logger.error(f"[Whisper] 识别失败: {e}")
            return ""
        finally:
            # 清理临时文件
            try:
                os.unlink(tmp_path)
            except Exception:
                pass
