from __future__ import annotations

import json
import logging
from typing import Any

from ..native_tools import (
    delete_file as native_delete_file,
    find_symbol as native_find_symbol,
    get_file_size as native_get_file_size,
    grep_code as native_grep_code,
    insert_content as native_insert_content,
    list_dir as native_list_dir,
    read_file as native_read_file,
    replace_content as native_replace_content,
    run_command as native_run_command,
    search_replace as native_search_replace,
    search_workspace as native_search_workspace,
    write_file as native_write_file,
)

logger = logging.getLogger("lumi")


class ToolHandlersMixin:
    """负责原生工具注册与 IDE 模式 Agent Prompt 组装。"""

    def _register_native_tools(self) -> None:
        """注册所有原生工具到 ToolRegistry。"""
        registry = self.tool_registry

        @registry.register(
            name="read_file",
            description="Read file contents from the workspace. Supports line range pagination. Output line prefixes (Lx:) are 1-based line markers for reference, not part of the file content.",
            parameters={
                "path": {"type": "string", "description": "Absolute or workspace-relative path of the file to read"},
                "start_line": {"type": "integer", "description": "Start line number (1-based, inclusive), defaults to 1", "default": 1},
                "end_line": {"type": "integer", "description": "End line number (inclusive). Omit to read until the end of the file"},
            },
        )
        def read_file(path: str, start_line: int = 1, end_line: int = None) -> str:
            return native_read_file(path, start_line, end_line)

        @registry.register(
            name="search_replace",
            description="IDE-style search and replace. Replaces an exact unique search block with a replacement block. Automatically tracked and protected by Git versioning.",
            parameters={
                "path": {"type": "string", "description": "Path of the file to edit"},
                "search_block": {"type": "string", "description": "Exact multi-line block to be replaced (must be unique within the file, including exact indentation)"},
                "replace_block": {"type": "string", "description": "New replacement content block"},
            },
        )
        def search_replace(path: str, search_block: str, replace_block: str) -> str:
            return native_search_replace(path, search_block, replace_block)

        @registry.register(
            name="insert_content",
            description="Insert content at a specific line number (1-based). Automatically tracked and protected by Git versioning.",
            parameters={
                "path": {"type": "string", "description": "Path of the file to modify"},
                "line_number": {"type": "integer", "description": "Target line index (1-based) where content will be inserted"},
                "content": {"type": "string", "description": "Text content to insert"},
            },
        )
        def insert_content(path: str, line_number: int, content: str) -> str:
            return native_insert_content(path, line_number, content)

        @registry.register(
            name="list_dir",
            description="List entries (files and directories) in the specified folder.",
            parameters={
                "path": {"type": "string", "description": "Path of the directory to list"},
            },
        )
        def list_dir(path: str) -> str:
            return native_list_dir(path)

        @registry.register(
            name="write_file",
            description="Create a new file or overwrite an entire small file. For existing codebase files, DO NOT overwrite completely; use replace_content or search_replace for surgical modifications.",
            parameters={
                "path": {"type": "string", "description": "Target file path"},
                "content": {"type": "string", "description": "Full file content to write"},
            },
        )
        def write_file(path: str, content: str) -> str:
            return native_write_file(path, content)

        @registry.register(
            name="delete_file",
            description="Delete a file from the workspace. High-risk operation requiring explicit user approval.",
            parameters={
                "path": {"type": "string", "description": "Path of the file to delete"},
            },
            requires_auth=True,
            auth_action_type="FILE_DELETE",
        )
        def delete_file(path: str) -> str:
            return native_delete_file(path)

        @registry.register(
            name="replace_content",
            description="Surgically replace a unique snippet in a file. Must provide the unique old_content. Automatically tracked and protected by Git versioning.",
            parameters={
                "path": {"type": "string", "description": "Path of the file to edit"},
                "old_content": {"type": "string", "description": "Exact text snippet to be replaced (must match exactly once in the file)"},
                "new_content": {"type": "string", "description": "New text snippet to insert in its place"},
            },
        )
        def replace_content(path: str, old_content: str, new_content: str) -> str:
            return native_replace_content(path, old_content, new_content)

        @registry.register(
            name="get_file_size",
            description="Get the size of a file in bytes.",
            parameters={
                "path": {"type": "string", "description": "Path of the file"},
            },
        )
        def get_file_size(path: str) -> str:
            return native_get_file_size(path)

        @registry.register(
            name="run_command",
            description="Execute a shell command on the host system. High-risk operation requiring explicit user approval via client popup. Captures exit code, stdout, and stderr.",
            parameters={
                "command": {"type": "string", "description": "Shell command line to execute"},
                "cwd": {"type": "string", "description": "Working directory for the command (defaults to workspace root)", "default": ""},
                "timeout": {"type": "integer", "description": "Timeout in seconds, defaults to 60", "default": 60},
            },
            requires_auth=True,
            auth_action_type="COMMAND_RUN",
        )
        async def run_command(command: str, cwd: str = "", timeout: int = 60) -> str:
            return await native_run_command(command=command, cwd=cwd or None, timeout=timeout)

        @registry.register(
            name="search_workspace",
            description="Search files and directories matching a glob pattern (e.g. '*.dart', '*test*') recursively across the workspace.",
            parameters={
                "pattern": {"type": "string", "description": "File name keyword or glob pattern (e.g. '*.py', '*controller*')"},
                "workspace_dir": {"type": "string", "description": "Root directory to search (defaults to workspace root)", "default": ""},
                "max_results": {"type": "integer", "description": "Maximum number of results to return (default 50)", "default": 50},
            },
        )
        def search_workspace(pattern: str, workspace_dir: str = "", max_results: int = 50) -> str:
            return native_search_workspace(pattern=pattern, workspace_dir=workspace_dir or None, max_results=max_results)

        @registry.register(
            name="grep_code",
            description="Fast regex or literal text search across files in the workspace. Quickly locates matching lines and file paths without traversing manually.",
            parameters={
                "query": {"type": "string", "description": "Text substring or regex pattern to search for"},
                "path": {"type": "string", "description": "Target file or directory path (defaults to workspace root)", "default": ""},
                "is_regex": {"type": "boolean", "description": "Whether query is a regular expression, defaults to false", "default": False},
                "case_sensitive": {"type": "boolean", "description": "Whether search is case-sensitive, defaults to false", "default": False},
                "max_results": {"type": "integer", "description": "Maximum number of matched lines, defaults to 50", "default": 50},
                "file_extension": {"type": "string", "description": "Optional file extension filter (e.g. '.dart' or '.py')", "default": ""},
            },
        )
        def grep_code(query: str, path: str = "", is_regex: bool = False, case_sensitive: bool = False, max_results: int = 50, file_extension: str = "") -> str:
            return native_grep_code(query=query, path=path or None, is_regex=is_regex, case_sensitive=case_sensitive, max_results=max_results, file_extension=file_extension)

        @registry.register(
            name="find_symbol",
            description="Quickly locate code symbol definitions (classes, functions, methods, structs, interfaces, enums) across the workspace.",
            parameters={
                "symbol": {"type": "string", "description": "Name of the symbol to locate (e.g. 'AgentLoop', 'ChatMessage', 'main')"},
                "path": {"type": "string", "description": "Target search directory (defaults to workspace root)", "default": ""},
                "max_results": {"type": "integer", "description": "Maximum number of matches to return (default 30)", "default": 30},
            },
        )
        def find_symbol(symbol: str, path: str = "", max_results: int = 30) -> str:
            return native_find_symbol(symbol=symbol, path=path or None, max_results=max_results)

        @registry.register(
            name="ask_user_question",
            description=(
                "Ask the user one or more multiple-choice questions to resolve architectural decisions, clarify requirements, or obtain confirmation. "
                "Suspends execution and presents an interactive dialog on the client. Put the recommended choice first with '(Recommended)' appended."
            ),
            parameters={
                "questions": {
                    "type": "array",
                    "description": "List of questions to present to the user",
                    "items": {
                        "type": "object",
                        "required": ["question", "options"],
                        "properties": {
                            "id": {"type": "string", "description": "Unique identifier for the question, e.g. q1, arch_choice"},
                            "question": {"type": "string", "description": "Question text presented to the user"},
                            "options": {
                                "type": "array",
                                "items": {"type": "string"},
                                "description": "Candidate option strings, e.g. ['(Recommended) Option A', 'Option B']",
                            },
                            "is_multi_select": {"type": "boolean", "description": "Whether multiple selections are allowed, defaults to false", "default": False},
                        },
                    },
                },
            },
        )
        def ask_user_question(questions: list[dict] = None) -> str:
            return json.dumps({
                "answers": [
                    {
                        "id": q.get("id", f"q{i+1}"),
                        "selected": [q.get("options", ["(Recommended) 确认"])[0]] if q.get("options") else ["确认"]
                    }
                    for i, q in enumerate(questions or [])
                ]
            }, ensure_ascii=False)

        logger.info(f"[Lumi-Hub] 已注册 {len(self.tool_registry.list_tools())} 个原生工具")

    async def _build_agent_prompt(self) -> None:
        """构建 IDE 模式的 Agent 指令（含 MCP 工具列表）。"""
        mcp_tools = await self.mcp_manager.get_all_tools()
        mcp_prompt = ""
        if mcp_tools:
            mcp_prompt = "\n【外部 MCP 工具列表（必须严格匹配 Server 与 Tool 名称调用）】\n"
            for t in mcp_tools:
                mcp_prompt += (
                    f"■ Server: `{t['server_name']}`, Tool: `{t['tool_name']}`\n"
                    f"  Desc: {t.get('description', '')}\n"
                    f"  Schema: {json.dumps(t.get('inputSchema', {}), ensure_ascii=False)}\n"
                )

        self._agent_prompt = (
            "\n\n### LUMI_IDE_AGENT_v2 ###\n"
            "【核心指令集: IDE 模式】\n"
            "You are a senior software engineer Agent. Your efficiency depends on 'do more, talk less'.\n"
            "1. ReAct Loop: When receiving code modification requests, follow: [think -> read -> think -> modify -> verify].\n"
            "2. No Interrupt: Once read_file returns successfully, you MUST immediately analyze and call search_replace or insert_content. Never report file content back to the user unless your modification is complete.\n"
            "3. Precise Edit: Prefer search_replace. Provide a unique original code block (SEARCH) and the replacement block (REPLACE). Indentation must match exactly.\n"
            "4. Code Search & Navigation: Prioritize `search_workspace` to locate files, `grep_code` to search code text and lines, and `find_symbol` to locate class/function definitions across the project. Use `list_dir` only for single directory inspection.\n"
            "5. MCP Tools: See the external tool list below. Use the exact tool names and follow the Schema strictly.\n"
            "########################"
            f"{mcp_prompt}"
        )
