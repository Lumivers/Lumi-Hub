"""
Lumi-Hub 2.0 — LLM Provider 抽象基类
定义所有 LLM Provider 必须实现的接口。
"""
from abc import ABC, abstractmethod
from typing import AsyncGenerator, Optional


class BaseLLMProvider(ABC):
    """LLM Provider 抽象基类。

    所有 LLM 适配器（OpenAI、Anthropic、Ollama）都继承此类，
    提供统一的流式调用接口给 AgentLoop 使用。
    """

    @abstractmethod
    async def chat_stream(
        self,
        messages: list[dict],
        tools: Optional[list[dict]] = None,
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> AsyncGenerator[dict, None]:
        """流式调用 LLM。

        Args:
            messages: 对话历史，格式 [{"role": "user/assistant/system", "content": "..."}]
            tools: OpenAI function calling 格式的工具列表（可选）
            model: 模型名称（可选，不填使用默认模型）
            temperature: 温度参数
            max_tokens: 最大输出 token 数

        Yields:
            {"type": "text", "content": "..."}     — 文本片段
            {"type": "text_end"}                     — 文本生成结束
            {"type": "tool_calls", "calls": [...]}   — 工具调用（聚合后）
            {"type": "error", "message": "..."}      — 错误信息
        """
        ...
        # 使生成器类型检查通过
        yield  # type: ignore[misc]

    @abstractmethod
    def get_default_model(self) -> str:
        """返回当前 Provider 的默认模型名称。"""
        ...
