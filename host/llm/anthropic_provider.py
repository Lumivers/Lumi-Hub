"""
Lumi-Hub 2.0 — Anthropic (Claude) LLM Provider
支持 Claude 系列模型的流式调用和 tool use。
"""
import json
import logging
from typing import AsyncGenerator, Optional

from .provider import BaseLLMProvider

logger = logging.getLogger("lumi")


class AnthropicProvider(BaseLLMProvider):
    """Anthropic Claude API 适配器。

    与 OpenAI 不同的点：
    - system prompt 是单独参数，不放在 messages 里
    - tool_use 返回的是完整块（不需要分片拼接）
    - 需要处理 content blocks（text + tool_use 可能交替出现）
    """

    def __init__(
        self,
        api_key: str,
        default_model: str = "claude-sonnet-4-20250514",
    ):
        self._api_key = api_key
        self._default_model = default_model
        self._client = None

    def _get_client(self):
        if self._client is None:
            from anthropic import AsyncAnthropic
            self._client = AsyncAnthropic(api_key=self._api_key)
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

        # Anthropic 的 system prompt 是单独参数
        system_prompt = ""
        api_messages = []
        for msg in messages:
            if msg["role"] == "system":
                system_prompt = msg["content"]
            else:
                api_messages.append(msg)

        # 将 OpenAI 格式的 tools 转为 Anthropic 格式
        anthropic_tools = None
        if tools:
            anthropic_tools = []
            for t in tools:
                func = t.get("function", t)
                anthropic_tools.append({
                    "name": func["name"],
                    "description": func.get("description", ""),
                    "input_schema": func.get("parameters", {"type": "object", "properties": {}}),
                })

        kwargs = {
            "model": use_model,
            "messages": api_messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        if system_prompt:
            kwargs["system"] = system_prompt
        if anthropic_tools:
            kwargs["tools"] = anthropic_tools

        try:
            async with client.messages.stream(**kwargs) as stream:
                # Anthropic 的 stream 返回 content block events
                tool_uses = []
                text_started = False

                async for event in stream:
                    # 文本增量
                    if event.type == "content_block_delta":
                        if hasattr(event.delta, "text"):
                            if not text_started:
                                text_started = True
                            yield {"type": "text", "content": event.delta.text}
                        # tool_use 的 input 是 JSON 字符串增量
                        elif hasattr(event.delta, "partial_json"):
                            # Anthropic 的 tool_use input 是分片的 JSON
                            # 需要在 content_block_stop 时聚合
                            pass

                    # content_block_start: 新的 content block 开始
                    elif event.type == "content_block_start":
                        block = event.content_block
                        if block.type == "tool_use":
                            tool_uses.append({
                                "id": block.id,
                                "name": block.name,
                                "input_json": "",
                            })

                    # content_block_stop: block 结束
                    elif event.type == "content_block_stop":
                        pass

                    # message_delta: 包含 stop_reason
                    elif event.type == "message_delta":
                        if event.delta.stop_reason == "end_turn":
                            yield {"type": "text_end"}
                        elif event.delta.stop_reason == "tool_use":
                            # 收集所有 tool_use blocks
                            calls = []
                            for tu in tool_uses:
                                try:
                                    args = json.loads(tu["input_json"]) if tu["input_json"] else {}
                                except json.JSONDecodeError:
                                    args = {}
                                calls.append({
                                    "id": tu["id"],
                                    "name": tu["name"],
                                    "arguments": args,
                                })
                            yield {"type": "tool_calls", "calls": calls}

                # 处理遗留的 tool_uses（stream 正常结束但没有 message_delta）
                if tool_uses:
                    calls = []
                    for tu in tool_uses:
                        # 从 stream 的最终 message 中获取 input
                        try:
                            final_message = await stream.get_final_message()
                            for block in final_message.content:
                                if block.type == "tool_use":
                                    calls.append({
                                        "id": block.id,
                                        "name": block.name,
                                        "arguments": block.input if isinstance(block.input, dict) else {},
                                    })
                            break  # 只需要处理一次
                        except Exception:
                            pass
                    if calls:
                        yield {"type": "tool_calls", "calls": calls}

        except Exception as e:
            logger.error(f"[Anthropic Provider] 调用失败: {e}")
            yield {"type": "error", "message": str(e)}
