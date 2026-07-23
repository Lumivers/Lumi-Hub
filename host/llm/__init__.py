"""
Lumi-Hub 2.0 — LLM Provider 抽象层
替代 AstrBot 的 LLM 管道，提供统一的流式调用接口。
"""
import os
import json
import logging

from .provider import BaseLLMProvider
from .openai_provider import OpenAIProvider
from .anthropic_provider import AnthropicProvider
from .ollama_provider import OllamaProvider

logger = logging.getLogger("lumi")


def _load_config_file(data_dir: str) -> dict:
    """从 data/llm_config.json 加载配置。"""
    config_path = os.path.join(data_dir, "llm_config.json")
    if os.path.exists(config_path):
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            logger.warning(f"[LLM] 读取配置文件失败: {e}")
    return {}


def create_provider(data_dir: str = None, provider_type: str = None, **kwargs) -> BaseLLMProvider:
    """创建 LLM Provider 实例。

    优先级：参数 > 环境变量 > data/llm_config.json > 默认值

    配置文件 data/llm_config.json 格式:
    {
        "provider": "openai",
        "api_key": "sk-xxx",
        "base_url": "https://api.deepseek.com/v1",
        "model": "gpt-4o"
    }
    """
    file_config = _load_config_file(data_dir) if data_dir else {}

    ptype = (
        provider_type
        or os.environ.get("LUMI_LLM_PROVIDER")
        or file_config.get("provider")
        or "openai"
    ).strip().lower()

    def _get(key, env_key, default=None):
        """按优先级获取配置值。"""
        return (
            kwargs.get(key)
            or os.environ.get(env_key)
            or file_config.get(key)
            or default
        )

    if ptype == "openai":
        api_key = _get("api_key", "LUMI_LLM_API_KEY", "")
        base_url = _get("base_url", "LUMI_LLM_BASE_URL")
        default_model = _get("model", "LUMI_LLM_MODEL", "gpt-4o")
        if not api_key:
            logger.warning("[LLM] OpenAI API Key 未配置，LLM 调用将失败")
        provider = OpenAIProvider(api_key=api_key, base_url=base_url, default_model=default_model)
        logger.info(f"[LLM] 使用 OpenAI Provider (model={default_model})")
        return provider

    elif ptype == "anthropic":
        api_key = _get("api_key", "LUMI_LLM_API_KEY", "")
        default_model = _get("model", "LUMI_LLM_MODEL", "claude-sonnet-4-20250514")
        if not api_key:
            logger.warning("[LLM] Anthropic API Key 未配置，LLM 调用将失败")
        provider = AnthropicProvider(api_key=api_key, default_model=default_model)
        logger.info(f"[LLM] 使用 Anthropic Provider (model={default_model})")
        return provider

    elif ptype == "ollama":
        base_url = _get("base_url", "LUMI_OLLAMA_URL", "http://localhost:11434/v1")
        default_model = _get("model", "LUMI_LLM_MODEL", "qwen2.5:latest")
        provider = OllamaProvider(base_url=base_url, default_model=default_model)
        logger.info(f"[LLM] 使用 Ollama Provider (model={default_model}, url={base_url})")
        return provider

    else:
        raise ValueError(f"不支持的 LLM Provider 类型: {ptype}，可选: openai, anthropic, ollama")
