"""
Lumi-Hub 2.0 — 统一工具注册中心
替代 AstrBot 的 @filter.llm_tool 装饰器，管理 native tools 和 MCP tools。
"""
import inspect
import json
import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

logger = logging.getLogger("lumi")


@dataclass
class ToolDef:
    """工具定义。"""
    name: str
    description: str
    fn: Callable
    schema: dict  # OpenAI function calling 格式
    requires_auth: bool = False
    auth_action_type: str = "TOOL_CALL"


class ToolRegistry:
    """统一工具注册中心。

    替代 AstrBot 的 @filter.llm_tool 装饰器。
    管理两种工具：
    1. Native Tools — 本地文件操作等，通过 @register 装饰器注册
    2. MCP Tools — 外部 MCP Server 提供的工具，运行时动态加载
    """

    def __init__(self):
        self._tools: dict[str, ToolDef] = {}
        self._mcp_manager = None  # 延迟绑定

    def set_mcp_manager(self, mcp_manager):
        """绑定 MCP Manager，使 MCP 工具可被统一调用。"""
        self._mcp_manager = mcp_manager

    def register(
        self,
        name: str,
        description: str,
        parameters: dict,
        requires_auth: bool = False,
        auth_action_type: str = "TOOL_CALL",
    ):
        """装饰器：注册一个工具函数。

        用法：
            @tool_registry.register(
                name="read_file",
                description="读取文件内容",
                parameters={
                    "path": {"type": "string", "description": "文件路径"},
                }
            )
            def read_file(path: str) -> str:
                ...
        """
        schema = {
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": {
                    "type": "object",
                    "properties": parameters,
                    "required": [k for k, v in parameters.items() if not self._is_optional(v)],
                },
            },
        }

        def decorator(fn: Callable):
            self._tools[name] = ToolDef(
                name=name,
                description=description,
                fn=fn,
                schema=schema,
                requires_auth=requires_auth,
                auth_action_type=auth_action_type,
            )
            logger.debug(f"[ToolRegistry] 注册工具: {name}")
            return fn

        return decorator

    def _is_optional(self, param_schema: dict) -> bool:
        """检查参数是否可选（有 default 值）。"""
        return "default" in param_schema

    def get_all_schemas(self) -> list[dict]:
        """获取所有工具的 OpenAI function schema。

        包括 native tools 和 MCP tools。
        """
        schemas = [td.schema for td in self._tools.values()]

        # 添加 MCP 工具（动态获取）
        # MCP 工具通过 call_mcp_tool 统一入口调用，不在这里单独暴露
        # 因为 MCP 工具的 schema 格式需要转换

        return schemas

    def get_native_schemas(self) -> list[dict]:
        """仅获取 native tools 的 schema。"""
        return [td.schema for td in self._tools.values()]

    async def get_all_schemas_with_mcp(self) -> list[dict]:
        """获取所有工具 schema（包括动态加载的 MCP 工具）。"""
        schemas = self.get_native_schemas()

        if self._mcp_manager:
            try:
                mcp_tools = await self._mcp_manager.get_all_tools()
                for t in mcp_tools:
                    schemas.append({
                        "type": "function",
                        "function": {
                            "name": f"mcp__{t['server_name']}__{t['tool_name']}",
                            "description": f"[MCP:{t['server_name']}] {t.get('description', '')}",
                            "parameters": t.get("inputSchema", {"type": "object", "properties": {}}),
                        },
                    })
            except Exception as e:
                logger.warning(f"[ToolRegistry] 获取 MCP 工具列表失败: {e}")

        return schemas

    async def execute(self, name: str, arguments: dict, auth_callback: Optional[Callable] = None) -> str:
        """执行工具调用。

        Args:
            name: 工具名称
            arguments: 工具参数
            auth_callback: 审批回调函数 (action_type, target_path, description, tool_name, diff_preview) -> bool

        Returns:
            工具执行结果的字符串
        """
        # 1. 查找 native tool
        tool = self._tools.get(name)
        if tool:
            # 检查是否需要审批
            if tool.requires_auth and auth_callback:
                approved = await auth_callback(
                    action_type=tool.auth_action_type,
                    target_path=arguments.get("path", ""),
                    description=f"执行工具: {name}",
                    tool_name=name,
                    diff_preview=json.dumps(arguments, indent=2, ensure_ascii=False)[:500],
                )
                if not approved:
                    return "Error: User rejected the tool execution."

            try:
                # 调用函数
                result = tool.fn(**arguments)
                # 如果是协程，await 它
                if inspect.isawaitable(result):
                    result = await result
                return str(result) if result is not None else ""
            except TypeError as e:
                return f"Error: 工具参数错误 - {e}"
            except Exception as e:
                logger.error(f"[ToolRegistry] 执行工具 {name} 失败: {e}")
                return f"Error: {e}"

        # 2. 查找 MCP 工具 (格式: mcp__server_name__tool_name)
        if name.startswith("mcp__"):
            parts = name.split("__", 2)
            if len(parts) == 3:
                _, server_name, tool_name = parts
                return await self._execute_mcp_tool(
                    server_name, tool_name, arguments, auth_callback
                )

        return f"Error: 未知工具 '{name}'"

    async def _execute_mcp_tool(
        self,
        server_name: str,
        tool_name: str,
        arguments: dict,
        auth_callback: Optional[Callable] = None,
    ) -> str:
        """执行 MCP 工具。"""
        if not self._mcp_manager:
            return "Error: MCP Manager 未初始化"

        # MCP 工具默认需要审批
        if auth_callback:
            approved = await auth_callback(
                action_type="MCP_TOOL_CALL",
                target_path=f"[{server_name}] {tool_name}",
                description=f"调用外部 MCP 工具: {tool_name}",
                tool_name="call_mcp_tool",
                diff_preview=json.dumps(arguments, indent=2, ensure_ascii=False)[:500],
            )
            if not approved:
                return "Error: User rejected the MCP tool call."

        try:
            result = await self._mcp_manager.call_tool(server_name, tool_name, arguments)
            return json.dumps(result, ensure_ascii=False) if not isinstance(result, str) else result
        except Exception as e:
            logger.error(f"[ToolRegistry] MCP 工具执行失败: {e}")
            return f"Error: {e}"

    def get_tool(self, name: str) -> Optional[ToolDef]:
        """获取工具定义（仅 native tools）。"""
        return self._tools.get(name)

    def list_tools(self) -> list[dict]:
        """列出所有已注册的 native tools。"""
        return [
            {
                "name": td.name,
                "description": td.description,
                "requires_auth": td.requires_auth,
            }
            for td in self._tools.values()
        ]
