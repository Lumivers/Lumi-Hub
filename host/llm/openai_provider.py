"""
Lumi-Hub 2.0 — OpenAI LLM Provider
支持 OpenAI API 及所有兼容接口（如 Deepseek、Moonshot、vLLM 等）。
"""
import json
import logging
from typing import AsyncGenerator, Optional

from .provider import BaseLLMProvider

logger = logging.getLogger("lumi")


class OpenAIProvider(BaseLLMProvider):
    """OpenAI API 适配器。

    支持：
    - OpenAI 官方 API
    - 任何兼容 OpenAI 格式的第三方 API（Deepseek、Moonshot、Together 等）
    - 自部署的 vLLM / Ollama OpenAI-compatible 端点
    """

    def __init__(
        self,
        api_key: str,
        base_url: Optional[str] = None,
        default_model: str = "gpt-4o",
    ):
        self._api_key = api_key
        self._base_url = base_url
        self._default_model = default_model
        self._client = None

    def _get_client(self):
        """延迟初始化客户端（避免在 import 时就要求 openai 包）。"""
        if self._client is None:
            from openai import AsyncOpenAI
            self._client = AsyncOpenAI(
                api_key=self._api_key,
                base_url=self._base_url,
            )
        return self._client

    def get_default_model(self) -> str:
        return self._default_model

    async def chat_stream(
        self,
        messages: list[dict],
        tools: Optional[list[dict]] = None,
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> AsyncGenerator[dict, None]:
        client = self._get_client()
        use_model = model or self._default_model

        kwargs = {
            "model": use_model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": True,
        }

        if tools:
            kwargs["tools"] = tools
            kwargs["tool_choice"] = "auto"

        try:
            stream = await client.chat.completions.create(**kwargs)

            # 用于聚合分片的 tool_calls 缓冲区
            # OpenAI 的 tool_call 是分片的（index 字段标识），需要拼接
            tool_calls_buffer: dict[int, dict] = {}
            text_started = False

            async for chunk in stream:
                if not chunk.choices:
                    continue

                choice = chunk.choices[0]
                delta = choice.delta

                # 处理文本内容
                if delta and delta.content:
                    if not text_started:
                        text_started = True
                    yield {"type": "text", "content": delta.content}

                # 处理 tool_calls（增量分片）
                if delta and delta.tool_calls:
                    for tc_delta in delta.tool_calls:
                        idx = tc_delta.index
                        if idx not in tool_calls_buffer:
                            tool_calls_buffer[idx] = {
                                "id": tc_delta.id or "",
                                "function": {
                                    "name": tc_delta.function.name if tc_delta.function and tc_delta.function.name else "",
                                    "arguments": "",
                                },
                            }
                        else:
                            # 拼接 id（有时第一片没有 id）
                            if tc_delta.id:
                                tool_calls_buffer[idx]["id"] = tc_delta.id
                            # 拼接函数名
                            if tc_delta.function and tc_delta.function.name:
                                tool_calls_buffer[idx]["function"]["name"] = tc_delta.function.name
                            # 拼接参数片段
                            if tc_delta.function and tc_delta.function.arguments:
                                tool_calls_buffer[idx]["function"]["arguments"] += tc_delta.function.arguments

                # 检查是否结束
                if choice.finish_reason == "stop":
                    yield {"type": "text_end"}
                elif choice.finish_reason == "tool_calls":
                    # 聚合完成，输出完整的 tool_calls
                    calls = []
                    for idx in sorted(tool_calls_buffer.keys()):
                        tc = tool_calls_buffer[idx]
                        # 解析 arguments JSON 字符串
                        try:
                            args = json.loads(tc["function"]["arguments"]) if tc["function"]["arguments"] else {}
                        except json.JSONDecodeError:
                            args = {"raw": tc["function"]["arguments"]}
                        calls.append({
                            "id": tc["id"],
                            "name": tc["function"]["name"],
                            "arguments": args,
                        })
                    yield {"type": "tool_calls", "calls": calls}

        except Exception as e:
            logger.error(f"[OpenAI Provider] 调用失败: {e}")
            yield {"type": "error", "message": str(e)}
