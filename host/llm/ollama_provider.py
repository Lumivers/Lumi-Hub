"""
Lumi-Hub 2.0 — Ollama LLM Provider
通过 Ollama 的 OpenAI-compatible API 调用本地模型。
"""
import logging
from typing import Optional

from .openai_provider import OpenAIProvider

logger = logging.getLogger("lumi")


class OllamaProvider(OpenAIProvider):
    """Ollama 本地模型适配器。

    Ollama 提供了 OpenAI 兼容的 /v1 端点，
    因此直接继承 OpenAIProvider，仅修改默认配置。
    """

    def __init__(
        self,
        base_url: str = "http://localhost:11434/v1",
        default_model: str = "qwen2.5:latest",
    ):
        super().__init__(
            api_key="ollama",  # Ollama 不需要真实 key，但 OpenAI SDK 要求非空
            base_url=base_url,
            default_model=default_model,
        )
        logger.info(f"[Ollama Provider] 初始化完成 (url={base_url}, model={default_model})")
