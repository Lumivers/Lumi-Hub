"""
Lumi-Hub 2.0 — 独立 Agent Runtime
不依赖 AstrBot，纯 asyncio + WebSocket + LLM SDK

替代原来的 LumiHubAdapter(Platform) + LumiHub(Star)。
"""
import asyncio
import os
import json
import time
import uuid
import logging
import sys
from typing import Any, Callable, Coroutine

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("lumi")

from .ws_server import LumiWSServer
from .database.manager import DatabaseManager
from .mcp_manager import LumiMCPManager
from .agent_loop import AgentLoop
from .tool_registry import ToolRegistry
from .persona_manager import PersonaManager
from .memory_manager import MemoryManager
from .skill_manager import SkillManager
from .llm import create_provider
from .native_tools import (
    read_file as native_read_file,
    search_replace as native_search_replace,
    insert_content as native_insert_content,
    write_file as native_write_file,
    delete_file as native_delete_file,
    list_dir as native_list_dir,
    get_file_size as native_get_file_size,
    replace_content as native_replace_content,
    run_command as native_run_command,
    search_workspace as native_search_workspace,
    grep_code as native_grep_code,
    find_symbol as native_find_symbol,
    revert_file as native_revert_file,
)
from .handlers import (
    AuthHandlersMixin,
    HistoryHandlersMixin,
    McpHandlersMixin,
    PersonaHandlersMixin,
    SessionHandlersMixin,
    UploadHandlersMixin,
    VoiceHandlersMixin,
)
from .voice_extensions import (
    DashScopeTTSProvider,
    SpeechSessionController,
    VoiceExtensionRegistry,
)


class LumiHubApp(
    AuthHandlersMixin,
    HistoryHandlersMixin,
    McpHandlersMixin,
    PersonaHandlersMixin,
    SessionHandlersMixin,
    UploadHandlersMixin,
    VoiceHandlersMixin,
):
    """Lumi-Hub 2.0 主应用。

    整合所有组件：WebSocket、数据库、MCP、LLM、工具注册、人格管理。
    替代原来的 LumiHubAdapter(Platform) + LumiHub(Star)。
    """

    def __init__(self):
        # 路径初始化
        host_dir = os.path.dirname(os.path.realpath(__file__))
        project_root = os.path.dirname(host_dir)
        self.data_dir = os.path.join(project_root, "data")
        os.makedirs(self.data_dir, exist_ok=True)

        # 核心组件
        self.db = DatabaseManager(self.data_dir)
        self.ws_server = LumiWSServer(
            host=os.environ.get("LUMI_WS_HOST", "0.0.0.0"),
            port=int(os.environ.get("LUMI_WS_PORT", "8765")),
        )
        self.persona_manager = PersonaManager(self.data_dir)
        self.mcp_manager = LumiMCPManager(self.data_dir)
        self.tool_registry = ToolRegistry()
        self.llm = create_provider(data_dir=self.data_dir)
        self.memory_manager = MemoryManager(self.db, self.llm)
        self.skill_manager = SkillManager(self.data_dir)

        # 上传相关
        self.upload_root_dir = os.path.join(self.data_dir, "uploads")
        self.upload_staging_dir = os.path.join(self.upload_root_dir, "_staging")
        os.makedirs(self.upload_staging_dir, exist_ok=True)
        self.upload_sessions: dict[str, dict[str, Any]] = {}
        self.max_upload_size_bytes = 200 * 1024 * 1024  # 200MB
        self.allowed_mime_exact = {
            "application/pdf",
            "video/mp4",
            "video/webm",
            "video/quicktime",
        }
        self.allowed_mime_prefixes = ("image/", "audio/")

        # 会话管理
        self.active_sessions: dict[str, int] = {}  # ws_session_id -> user_id

        # 语音扩展
        self.voice_config_path = os.path.join(self.data_dir, "voice_config.json")
        self._voice_config_cache = self._load_voice_config()
        self._dashscope_provider: DashScopeTTSProvider | None = None
        self.voice_registry = VoiceExtensionRegistry()
        self.speech_sessions = SpeechSessionController()
        self._voice_turn_tasks: dict[tuple[str, str], asyncio.Task] = {}
        self._setup_voice_extensions()

        # 正在执行中的 AgentLoop (keyed by session_id and ws_session_id)
        self._active_agents: dict[str, AgentLoop] = {}

        # WebSocket 消息路由表
        self._message_handlers: dict[
            str, Callable[[dict, str], Coroutine[Any, Any, None]]
        ] = {
            "CHAT_REQUEST": self._handle_chat_request,
            "CHAT_CANCEL": self._handle_chat_cancel,
            "CHAT_INTERRUPT": self._handle_chat_cancel,
            "PERSONA_SWITCH": self._handle_persona_switch,
            "PERSONA_LIST": self._handle_persona_list,
            "AUTH_REGISTER": self._handle_auth_register,
            "AUTH_LOGIN": self._handle_auth_login,
            "AUTH_RESTORE": self._handle_auth_restore,
            "HISTORY_REQUEST": self._handle_history_request,
            "MCP_CONFIG_GET": self._handle_mcp_config_get,
            "MCP_CONFIG_UPDATE": self._handle_mcp_config_update,
            "PERSONA_CLEAR_HISTORY": self._handle_persona_clear_history,
            "MESSAGE_DELETE": self._handle_message_delete,
            "REVERT_FILES": self._handle_revert_files,
            "PERSONA_DELETE": self._handle_persona_delete,
            "FILE_UPLOAD_INIT": self._handle_file_upload_init,
            "FILE_UPLOAD_CHUNK": self._handle_file_upload_chunk,
            "FILE_UPLOAD_COMPLETE": self._handle_file_upload_complete,
            "VOICE_CONFIG_GET": self._handle_voice_config_get,
            "VOICE_CONFIG_SET": self._handle_voice_config_set,
            "VOICE_TTS_REQUEST": self._dispatch_voice_tts_request,
            "VOICE_INTERRUPT": self._handle_voice_interrupt,
            "TTS_CANCEL": self._handle_voice_interrupt,
            "LLM_CONFIG_GET": self._handle_llm_config_get,
            "LLM_CONFIG_SET": self._handle_llm_config_set,
            "LLM_SWITCH_MODEL": self._handle_llm_switch_model,
            "LLM_MODEL_SAVE": self._handle_llm_model_save,
            "LLM_MODEL_DELETE": self._handle_llm_model_delete,
            "LLM_TEST_CONNECTION": self._handle_llm_test_connection,
            "APP_STATUS": self._handle_app_status,
            "MEMORY_LIST": self._handle_memory_list,
            "MEMORY_ADD": self._handle_memory_add,
            "MEMORY_DELETE": self._handle_memory_delete,
            "MEMORY_CLEAR": self._handle_memory_clear,
            "SKILL_LIST": self._handle_skill_list,
            "SKILL_INSTALL": self._handle_skill_install,
            "SKILL_UNINSTALL": self._handle_skill_uninstall,
            "SESSION_LIST": self._handle_session_list,
            "SESSION_CREATE": self._handle_session_create,
            "SESSION_UPDATE": self._handle_session_update,
            "SESSION_DELETE": self._handle_session_delete,
        }

        # WebSocket 回调注册
        self.ws_server.on_message(self._handle_client_message)
        self.ws_server.on_disconnect(self._handle_ws_disconnect)

        # Agent prompt（IDE 模式指令）
        self._agent_prompt = ""

    def _setup_voice_extensions(self) -> None:
        """初始化语音扩展。"""
        provider_name = str(os.environ.get("LUMI_VOICE_PROVIDER", "dashscope")).strip().lower()
        if provider_name != "dashscope":
            logger.warning(f"[Lumi-Hub] Voice provider '{provider_name}' is not supported yet")
            return

        env_default_voice = str(os.environ.get("LUMI_DASHSCOPE_VOICE_ID", "")).strip()
        cached_default_voice = str(self._voice_config_cache.get("dashscope_voice_id", "")).strip()
        default_voice = env_default_voice or cached_default_voice

        provider = DashScopeTTSProvider(
            model=str(os.environ.get("LUMI_DASHSCOPE_MODEL", "cosyvoice-v3.5-plus")).strip(),
            default_voice=default_voice,
            websocket_url=str(os.environ.get("LUMI_DASHSCOPE_WS_URL", "")).strip(),
            http_url=str(os.environ.get("LUMI_DASHSCOPE_HTTP_URL", "")).strip(),
        )
        cached_api_key = str(self._voice_config_cache.get("dashscope_api_key", "")).strip()
        if cached_api_key:
            provider.set_api_key(cached_api_key)

        self.voice_registry.register_tts("dashscope", provider)
        self.voice_registry.set_default_tts("dashscope")
        self._dashscope_provider = provider

        if not provider.has_api_key():
            logger.warning("[Lumi-Hub] DASHSCOPE_API_KEY is empty. Voice synthesis requests will fail until configured.")

        logger.info("[Lumi-Hub] Voice extension registered: dashscope")

    def _load_voice_config(self) -> dict[str, Any]:
        if not os.path.exists(self.voice_config_path):
            return {}
        try:
            with open(self.voice_config_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except Exception as e:
            logger.warning(f"[Lumi-Hub] Failed to load voice config: {e}")
            return {}

    def _save_voice_config(self) -> None:
        try:
            with open(self.voice_config_path, "w", encoding="utf-8") as f:
                json.dump(self._voice_config_cache, f, ensure_ascii=False, indent=2)
        except Exception as e:
            logger.error(f"[Lumi-Hub] Failed to save voice config: {e}")

    def _register_native_tools(self):
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

    async def _build_agent_prompt(self):
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

    async def _handle_chat_request(self, message: dict, ws_session_id: str) -> None:
        """处理 CHAT_REQUEST：创建 AgentLoop 并执行。"""
        payload = message.get("payload", {})
        user_content = payload.get("content", "")
        original_user_content = str(user_content or "").strip()
        attachments = payload.get("attachments", []) or []
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        context_id = payload.get("context_id", ws_session_id)
        persona_id = payload.get("persona_id", "default")
        session_id = payload.get("session_id")
        workspace_path = payload.get("workspace_path", "")

        # 鉴权校验
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            logger.warning("[Lumi-Hub] 未登录用户尝试发送消息，已拒绝")
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "ERROR_ALERT",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"},
                },
            )
            return

        # 确保会话存在
        if session_id:
            sess = self.db.get_or_create_session(
                user_id=user_id,
                session_id=session_id,
                workspace_path=workspace_path,
                persona_id=persona_id,
            )
            if sess.get("workspace_path") and not workspace_path:
                workspace_path = sess["workspace_path"]
        else:
            session_id = f"lumi_hub!{user_id}!{context_id}!{persona_id}"

        # 处理附件
        attachment_lines: list[str] = []
        attachment_hints: list[str] = []
        if isinstance(attachments, list):
            for att in attachments:
                if not isinstance(att, dict):
                    continue
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "application/octet-stream"))
                size_bytes = int(att.get("size_bytes", 0) or 0)
                storage_path = str(att.get("storage_path", "") or "")

                attachment_lines.append(f"- {file_name} ({mime_type}, {size_bytes} bytes)")

                if mime_type == "application/pdf" and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    preview = self._extract_pdf_preview(abs_path)
                    if preview:
                        attachment_hints.append(f"\n[PDF节选: {file_name}]\n{preview}\n")
                    else:
                        attachment_hints.append(
                            f"\n[PDF提示: {file_name}] 当前未能提取 PDF 文本，请先基于文件名和上下文回答。\n"
                        )

        if attachment_lines:
            base = (user_content or "").strip()
            if not base:
                base = "我上传了附件，请先确认接收并根据附件内容回答。"
            user_content = f"{base}\n\n[附件列表]\n" + "\n".join(attachment_lines)
            if attachment_hints:
                user_content += "\n\n" + "\n".join(attachment_hints)

        logger.info(f"[Lumi-Hub] 收到消息 (session={session_id}, persona={persona_id}, ws={ws_session_id}): {user_content[:100]}")

        # 持久化用户消息
        if isinstance(attachments, list) and attachments:
            for att in attachments:
                att = att or {}
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "")).lower()
                local_path = str(att.get("local_path", "") or att.get("storage_path", ""))
                is_img = mime_type.startswith("image/") or file_name.endswith((".png", ".jpg", ".jpeg", ".webp"))
                prefix = "[图片]" if is_img else "[附件]"
                self.db.save_message(
                    user_id=user_id,
                    role="user",
                    content=f"{prefix} {local_path}|||{file_name}",
                    client_msg_id=f"{msg_id}_att_{file_name}",
                    persona_id=persona_id,
                    session_id=session_id,
                    extra=att,
                )

        if original_user_content:
            self.db.save_message(
                user_id=user_id,
                role="user",
                content=original_user_content,
                client_msg_id=msg_id,
                persona_id=persona_id,
                session_id=session_id,
            )

        # 多端实时同频：向该用户的其它在线终端广播该用户消息，同步渲染并做好回声抑制
        sync_msg = {
            "message_id": msg_id,
            "type": "CHAT_MESSAGE_SYNC",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "message_id": msg_id,
                "role": "user",
                "content": original_user_content,
                "session_id": session_id,
                "persona_id": persona_id,
                "attachments": attachments,
            },
        }
        await self.ws_server.broadcast_to_user(
            user_id, sync_msg, exclude_session_id=ws_session_id
        )

        # 获取人格
        persona = await self.persona_manager.get_persona(persona_id)
        if not persona:
            persona = await self.persona_manager.get_persona("default")

        # 获取历史消息
        history = self.db.get_messages(
            user_id=user_id,
            persona_id=persona_id,
            session_id=session_id,
            limit=50,
            offset=0,
        )

        # 如果指定了 Skill，渲染 Skill 提示词
        skill_name = payload.get("skill_name")
        skill_params = payload.get("skill_params", {}) or {}
        skill_prompt = ""
        if skill_name:
            skill_prompt = self.skill_manager.get_skill_prompt(skill_name, skill_params)

        # 创建 AgentLoop 并执行
        agent = AgentLoop(
            llm_provider=self.llm,
            tool_registry=self.tool_registry,
            persona_system_prompt=persona.system_prompt if persona else "",
            history_messages=history[:-1] if history else [],  # 排除刚保存的用户消息
            ws_server=self.ws_server,
            ws_session_id=ws_session_id,
            user_id=user_id,
            persona_id=persona_id,
            db=self.db,
            mcp_manager=self.mcp_manager,
            memory_manager=self.memory_manager,
            agent_prompt=self._agent_prompt,
            skill_prompt=skill_prompt,
            msg_id=msg_id,
            session_id=session_id,
            workspace_dir=workspace_path,
        )

        # 记录正在运行的 agent
        agent_key = session_id or ws_session_id
        old_agent = self._active_agents.get(agent_key)
        if old_agent:
            old_agent.cancel()

        self._active_agents[agent_key] = agent
        self._active_agents[ws_session_id] = agent

        async def run_agent_and_cleanup():
            try:
                await agent.run(user_content, attachments)
            finally:
                if self._active_agents.get(agent_key) is agent:
                    self._active_agents.pop(agent_key, None)
                if self._active_agents.get(ws_session_id) is agent:
                    self._active_agents.pop(ws_session_id, None)

        # 异步执行 Agent
        asyncio.create_task(run_agent_and_cleanup())

    async def _handle_chat_cancel(self, message: dict, ws_session_id: str) -> None:
        """处理 CHAT_CANCEL / CHAT_INTERRUPT：打断当前正在执行的 AgentLoop。"""
        payload = message.get("payload", {})
        session_id = payload.get("session_id")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        logger.info(f"[Lumi-Hub] 收到用户打断请求 (session={session_id}, ws={ws_session_id})")

        interrupted = False
        if session_id and session_id in self._active_agents:
            agent = self._active_agents.get(session_id)
            if agent:
                agent.cancel()
                interrupted = True

        for key, agent in list(self._active_agents.items()):
            if agent.ws_session_id == ws_session_id:
                agent.cancel()
                interrupted = True

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "CHAT_RESPONSE_END",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "interrupted": True,
                    "session_id": session_id,
                },
            },
        )

    async def _handle_revert_files(self, message: dict, ws_session_id: str) -> None:
        """处理 REVERT_FILES：批量回退指定文件的代码修改。"""
        msg_id = message.get("message_id", "")
        payload = message.get("payload", {})
        file_paths = payload.get("files", [])
        workspace_path = payload.get("workspace_path") or self._active_workspace
        results = []
        for p in file_paths:
            ok, msg = native_revert_file(p, workspace_dir=workspace_path)
            results.append({"path": p, "success": ok, "message": msg})

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "REVERT_FILES_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "results": results,
                },
            },
        )

    async def _handle_client_message(self, message: dict, ws_session_id: str) -> None:
        """处理从 WebSocket Client 收到的业务消息。"""
        msg_type = message.get("type", "")
        handler = self._message_handlers.get(msg_type)
        if handler is None:
            logger.warning(f"[Lumi-Hub] 未知消息类型: {msg_type}")
            return
        await handler(message, ws_session_id)

    async def _handle_ws_disconnect(self, ws_session_id: str) -> None:
        """WebSocket 断开后的资源清理。"""
        # 清理运行中的 Agent
        agent = self._active_agents.pop(ws_session_id, None)
        if agent:
            agent.cancel()

        self.active_sessions.pop(ws_session_id, None)
        self.ws_server.unregister_user(ws_session_id)

        # 清理语音会话
        active_turn = await self.speech_sessions.clear_session(ws_session_id)
        if active_turn:
            await self.voice_registry.cancel_all(ws_session_id, active_turn)

        stale_voice_keys = [key for key in self._voice_turn_tasks if key[0] == ws_session_id]
        for key in stale_voice_keys:
            task = self._voice_turn_tasks.pop(key, None)
            if task and not task.done():
                task.cancel()

        # 清理上传会话
        stale_upload_ids = [
            upload_id
            for upload_id, session in self.upload_sessions.items()
            if session.get("ws_session_id") == ws_session_id
        ]
        for upload_id in stale_upload_ids:
            self._discard_upload_session(upload_id)

    def _discard_upload_session(self, upload_id: str) -> None:
        """丢弃上传会话。"""
        session = self.upload_sessions.pop(upload_id, None)
        if not session:
            return
        tmp_path = session.get("tmp_path", "")
        try:
            if tmp_path and os.path.exists(tmp_path):
                os.remove(tmp_path)
        except Exception as e:
            logger.warning(f"[Lumi-Hub] 清理临时上传文件失败: {e}")

    def _extract_pdf_preview(self, abs_path: str, max_chars: int = 6000, max_pages: int = 5) -> str:
        """提取 PDF 预览文本。"""
        if not abs_path or not os.path.exists(abs_path):
            return ""
        try:
            from pypdf import PdfReader
        except Exception:
            return ""
        try:
            reader = PdfReader(abs_path)
            parts: list[str] = []
            for idx, page in enumerate(reader.pages):
                if idx >= max_pages:
                    break
                text = page.extract_text() or ""
                if text.strip():
                    parts.append(text.strip())
                if sum(len(p) for p in parts) >= max_chars:
                    break
            merged = "\n\n".join(parts).strip()
            return merged[:max_chars] if len(merged) > max_chars else merged
        except Exception as e:
            logger.warning(f"[Lumi-Hub] PDF 解析失败: {e}")
            return ""

    # ========== 配置管理接口 ==========

    @property
    def _llm_config_path(self) -> str:
        return os.path.join(self.data_dir, "llm_config.json")

    def _mask_key(self, api_key: str) -> str:
        if not api_key:
            return ""
        if len(api_key) > 8:
            return api_key[:4] + "*" * (len(api_key) - 8) + api_key[-4:]
        return "****"

    def _normalize_llm_config(self, data: dict) -> dict:
        """保证配置包含 active_model_id、models 列表以及顶层激活项。"""
        models = data.get("models")
        if not isinstance(models, list) or not models:
            # 兼容旧版本单模型配置
            default_id = "default"
            provider = data.get("provider", "openai")
            model = data.get("model", "deepseek-chat")
            base_url = data.get("base_url", "https://api.deepseek.com")
            api_key = data.get("api_key", "")
            preset = data.get("provider_preset", "deepseek")
            models = [{
                "id": default_id,
                "name": model or "默认模型",
                "provider": provider,
                "provider_preset": preset,
                "model": model,
                "base_url": base_url,
                "api_key": api_key,
            }]
            data["models"] = models
            data["active_model_id"] = default_id

        active_id = data.get("active_model_id")
        active_model = next((m for m in models if m.get("id") == active_id), models[0])
        data["active_model_id"] = active_model.get("id")
        # 同步顶层字段保持完全向后兼容
        data["provider"] = active_model.get("provider", "openai")
        data["provider_preset"] = active_model.get("provider_preset", data["provider"])
        data["model"] = active_model.get("model", "")
        data["base_url"] = active_model.get("base_url", "")
        data["api_key"] = active_model.get("api_key", "")
        return data

    def _load_llm_config(self) -> dict:
        """读取 LLM 配置文件。"""
        if os.path.exists(self._llm_config_path):
            try:
                with open(self._llm_config_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        return self._normalize_llm_config(data)
            except Exception:
                pass
        return self._normalize_llm_config({
            "provider": "openai",
            "provider_preset": "deepseek",
            "api_key": "",
            "base_url": "https://api.deepseek.com",
            "model": "deepseek-chat",
        })

    def _save_llm_config(self, config: dict) -> None:
        """保存 LLM 配置文件。"""
        with open(self._llm_config_path, "w", encoding="utf-8") as f:
            json.dump(config, f, ensure_ascii=False, indent=2)

    async def _reload_llm_provider(self, config: dict):
        """热重载 LLM Provider。"""
        try:
            from .llm import create_provider
            self.llm = create_provider(
                data_dir=self.data_dir,
                provider_type=config.get("provider"),
                api_key=config.get("api_key", ""),
                base_url=config.get("base_url") or None,
                default_model=config.get("model"),
            )
            self.memory_manager.llm = self.llm
            logger.info(f"[Lumi-Hub] LLM Provider 已热重载: {type(self.llm).__name__} (model={config.get('model')})")
        except Exception as e:
            logger.error(f"[Lumi-Hub] LLM Provider 热重载失败: {e}")
            raise

    async def _handle_llm_config_get(self, message: dict, ws_session_id: str) -> None:
        """获取 LLM 配置与用户已添加的所有模型列表。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        config = self._load_llm_config()

        models_safe = []
        for m in config.get("models", []):
            k = m.get("api_key", "")
            models_safe.append({
                "id": m.get("id", ""),
                "name": m.get("name", m.get("model", "")),
                "provider": m.get("provider", "openai"),
                "provider_preset": m.get("provider_preset", m.get("provider", "openai")),
                "model": m.get("model", ""),
                "base_url": m.get("base_url", ""),
                "api_key_configured": bool(k),
                "api_key_masked": self._mask_key(k),
            })

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_CONFIG_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "success",
                "active_model_id": config.get("active_model_id", "default"),
                "models": models_safe,
                "config": {
                    "provider": config.get("provider", "openai"),
                    "provider_preset": config.get("provider_preset", config.get("provider", "openai")),
                    "model": config.get("model", ""),
                    "base_url": config.get("base_url", ""),
                    "api_key_masked": self._mask_key(config.get("api_key", "")),
                    "api_key_configured": bool(config.get("api_key", "")),
                },
            },
        })

    async def _handle_llm_switch_model(self, message: dict, ws_session_id: str) -> None:
        """快速切换当前激活的模型 Profile。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        model_id = payload.get("model_id", "").strip()

        current = self._load_llm_config()
        models = current.get("models", [])
        target = next((m for m in models if m.get("id") == model_id), None)
        if not target:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_SWITCH_MODEL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": f"未找到模型: {model_id}"},
            })
            return

        current["active_model_id"] = model_id
        current = self._normalize_llm_config(current)
        self._save_llm_config(current)

        # 热重载
        await self._reload_llm_provider(current)

        # 回复发送端
        sync_payload = {
            "status": "success",
            "active_model_id": model_id,
            "name": target.get("name", target.get("model", "")),
            "model": target.get("model", ""),
            "provider": target.get("provider", "openai"),
        }
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_SWITCH_MODEL_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": sync_payload,
        })

    async def _handle_llm_model_save(self, message: dict, ws_session_id: str) -> None:
        """添加或更新一个模型 Profile。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        model_data = payload.get("model", {})
        set_active = payload.get("set_active", False)

        if not isinstance(model_data, dict):
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_MODEL_SAVE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Invalid model data"},
            })
            return

        current = self._load_llm_config()
        models = current.get("models", [])

        model_id = (model_data.get("id") or str(uuid.uuid4())[:8]).strip()
        name = (model_data.get("name") or model_data.get("model") or "未命名模型").strip()
        provider = (model_data.get("provider") or "openai").strip()
        preset = (model_data.get("provider_preset") or provider).strip()
        model_name = (model_data.get("model") or "").strip()
        base_url = (model_data.get("base_url") or "").strip()
        new_key = str(model_data.get("api_key", "")).strip()

        existing = next((m for m in models if m.get("id") == model_id), None)
        if existing:
            existing["name"] = name
            existing["provider"] = provider
            existing["provider_preset"] = preset
            existing["model"] = model_name
            existing["base_url"] = base_url
            if new_key:
                existing["api_key"] = new_key
        else:
            item = {
                "id": model_id,
                "name": name,
                "provider": provider,
                "provider_preset": preset,
                "model": model_name,
                "base_url": base_url,
                "api_key": new_key,
            }
            models.append(item)

        if set_active or len(models) == 1:
            current["active_model_id"] = model_id

        current["models"] = models
        current = self._normalize_llm_config(current)
        self._save_llm_config(current)

        if current.get("active_model_id") == model_id:
            await self._reload_llm_provider(current)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_MODEL_SAVE_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "model_id": model_id},
        })

    async def _handle_llm_model_delete(self, message: dict, ws_session_id: str) -> None:
        """删除一个模型 Profile。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        model_id = payload.get("model_id", "").strip()

        current = self._load_llm_config()
        models = current.get("models", [])
        if len(models) <= 1:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_MODEL_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "至少需要保留一个模型配置"},
            })
            return

        new_models = [m for m in models if m.get("id") != model_id]
        current["models"] = new_models
        if current.get("active_model_id") == model_id:
            current["active_model_id"] = new_models[0].get("id")

        current = self._normalize_llm_config(current)
        self._save_llm_config(current)
        await self._reload_llm_provider(current)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_MODEL_DELETE_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "active_model_id": current.get("active_model_id")},
        })

    async def _handle_llm_config_set(self, message: dict, ws_session_id: str) -> None:
        """更新 LLM 配置并热重载。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        new_config = payload.get("config", {})

        if not isinstance(new_config, dict):
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Invalid config format"},
            })
            return

        # 合并配置（保留未传入的字段）
        current = self._load_llm_config()
        for key in ("provider", "provider_preset", "api_key", "base_url", "model"):
            if key in new_config:
                current[key] = new_config[key]

        # 保存
        try:
            self._save_llm_config(current)
        except Exception as e:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": f"Save failed: {e}"},
            })
            return

        # 热重载
        try:
            await self._reload_llm_provider(current)
        except Exception as e:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": f"Reload failed: {e}"},
            })
            return

        # 需要登录才能操作
        user_id = self.active_sessions.get(ws_session_id)
        if user_id:
            # 更新人格中的 agent prompt
            await self._build_agent_prompt()
            default_persona = await self.persona_manager.get_persona("default")
            if default_persona:
                cleaned = default_persona.system_prompt
                for old_tag in ["### LUMI_AGENT_RULES ###", "### LUMI_IDE_AGENT_v1 ###", "### LUMI_IDE_AGENT_v2 ###"]:
                    if old_tag in cleaned:
                        idx = cleaned.find(old_tag)
                        cleaned = cleaned[:idx].strip()
                default_persona.system_prompt = cleaned + self._agent_prompt
                await self.persona_manager.save_persona(default_persona)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_CONFIG_SET_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "message": "LLM config updated and reloaded"},
        })

    async def _handle_llm_test_connection(self, message: dict, ws_session_id: str) -> None:
        """测试指定或当前 LLM 配置的连通性与网络延迟。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {}) or {}
        config = payload.get("config", {}) or {}

        saved_config = self._load_llm_config()
        api_key = str(config.get("api_key", "")).strip()
        if not api_key:
            api_key = saved_config.get("api_key", "")

        provider_type = config.get("provider") or saved_config.get("provider", "openai")
        base_url = config.get("base_url") if "base_url" in config else saved_config.get("base_url")
        model = config.get("model") or saved_config.get("model", "gpt-4o")

        if not api_key and provider_type not in ("ollama",):
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_TEST_CONNECTION_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "error",
                    "latency_ms": 0,
                    "message": "请先填写 API Key",
                },
            })
            return

        start_time = time.time()
        try:
            from .llm import create_provider
            test_provider = create_provider(
                data_dir=self.data_dir,
                provider_type=provider_type,
                api_key=api_key,
                base_url=base_url or None,
                default_model=model,
            )

            # 发送轻量请求以测试握手连通性
            response_text = ""
            async for chunk in test_provider.chat_stream(
                messages=[{"role": "user", "content": "Hi"}],
                max_tokens=10,
            ):
                if chunk.get("type") == "text":
                    response_text += chunk.get("content", "")
                    if len(response_text) >= 1:
                        break

            latency_ms = int((time.time() - start_time) * 1000)
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_TEST_CONNECTION_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "latency_ms": latency_ms,
                    "message": f"连接正常，延迟 {latency_ms}ms",
                    "reply_preview": response_text.strip()[:30],
                },
            })
        except Exception as e:
            latency_ms = int((time.time() - start_time) * 1000)
            logger.warning(f"[Lumi-Hub] LLM 连通性测试失败: {e}")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_TEST_CONNECTION_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "error",
                    "latency_ms": latency_ms,
                    "message": f"连接失败: {str(e)}",
                },
            })

    async def _handle_app_status(self, message: dict, ws_session_id: str) -> None:
        """返回应用状态（供客户端检查 LLM 是否已配置等）。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        config = self._load_llm_config()
        api_key = config.get("api_key", "")

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "APP_STATUS_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "version": "2.0.0",
                "llm_configured": bool(api_key),
                "llm_provider": config.get("provider", "openai"),
                "llm_model": config.get("model", ""),
                "active_model_id": config.get("active_model_id", "default"),
                "models": [
                    {
                        "id": m.get("id", ""),
                        "name": m.get("name", m.get("model", "")),
                        "model": m.get("model", ""),
                        "provider": m.get("provider", "openai"),
                    }
                    for m in config.get("models", [])
                ],
            },
        })

    # ========== 记忆系统接口 ==========

    async def _send_unauthorized(self, ws_session_id: str, msg_id: str):
        """辅助方法：发送未授权错误。"""
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "ERROR_ALERT",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"},
        })

    async def _handle_memory_list(self, message: dict, ws_session_id: str) -> None:
        """获取指定人格的记忆列表。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        category = payload.get("category")

        memories = self.memory_manager.list_memories(user_id, persona_id, category)
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_LIST_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "success",
                "persona_id": persona_id,
                "memories": memories,
            },
        })

    async def _handle_memory_add(self, message: dict, ws_session_id: str) -> None:
        """手动添加记忆。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        category = payload.get("category", "fact")
        content = str(payload.get("content", "")).strip()

        if not content:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "MEMORY_ADD_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Content cannot be empty"},
            })
            return

        self.memory_manager.add_memory(user_id, persona_id, category, content)
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_ADD_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success"},
        })

    async def _handle_memory_delete(self, message: dict, ws_session_id: str) -> None:
        """删除单条记忆。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        memory_id = payload.get("memory_id")
        if memory_id is not None:
            self.memory_manager.forget_memory(int(memory_id), user_id)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_DELETE_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "memory_id": memory_id},
        })

    async def _handle_memory_clear(self, message: dict, ws_session_id: str) -> None:
        """清空指定人格的所有记忆。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_unauthorized(ws_session_id, msg_id)
            return

        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        count = self.memory_manager.clear_memories(user_id, persona_id)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "MEMORY_CLEAR_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "cleared_count": count},
        })

    # ========== 技能系统接口 ==========

    async def _handle_skill_list(self, message: dict, ws_session_id: str) -> None:
        """获取所有已安装技能列表。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        skills = self.skill_manager.list_skills()

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "SKILL_LIST_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "skills": skills},
        })

    async def _handle_skill_install(self, message: dict, ws_session_id: str) -> None:
        """从 Git 仓库安装技能。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        git_url = payload.get("git_url", "").strip()

        if not git_url:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "SKILL_INSTALL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "git_url is required"},
            })
            return

        skill = await self.skill_manager.install_from_git(git_url)
        if skill:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "SKILL_INSTALL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "skill": {
                        "name": skill.name,
                        "version": skill.version,
                        "author": skill.author,
                        "description": skill.description,
                        "icon": skill.icon,
                        "params": skill.params_schema,
                    },
                },
            })
        else:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "SKILL_INSTALL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Failed to install skill from repository"},
            })

    async def _handle_skill_uninstall(self, message: dict, ws_session_id: str) -> None:
        """卸载指定技能。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        skill_name = payload.get("skill_name", "").strip()

        success = await self.skill_manager.uninstall(skill_name)
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "SKILL_UNINSTALL_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success" if success else "error", "skill_name": skill_name},
        })

    async def start(self):
        """启动应用。"""
        logger.info("[Lumi-Hub] Lumi-Hub 2.0 独立 Agent Runtime 启动中...")

        # 注册原生工具
        self._register_native_tools()

        # 初始化 MCP
        await self.mcp_manager.initialize()

        # 绑定 MCP Manager 到 ToolRegistry
        self.tool_registry.set_mcp_manager(self.mcp_manager)

        # 加载 Skill 工作流
        await self.skill_manager.load_all()

        # 构建 Agent Prompt（含 MCP 工具列表）
        await self._build_agent_prompt()

        # 注入 Agent Prompt 到默认人格
        default_persona = await self.persona_manager.get_persona("default")
        if default_persona:
            # 清理旧版指令标签
            cleaned = default_persona.system_prompt
            for old_tag in ["### LUMI_AGENT_RULES ###", "### LUMI_IDE_AGENT_v1 ###", "### LUMI_IDE_AGENT_v2 ###"]:
                if old_tag in cleaned:
                    idx = cleaned.find(old_tag)
                    cleaned = cleaned[:idx].strip()
            default_persona.system_prompt = cleaned + self._agent_prompt
            await self.persona_manager.save_persona(default_persona)
            logger.info("[Lumi-Hub] 已为默认人格注入 IDE-Style 及 MCP Agent 指令")

        # 启动 WebSocket Server
        await self.ws_server.start()
        logger.info("[Lumi-Hub] Lumi-Hub 2.0 已就绪！")

        # 保持运行
        try:
            await asyncio.Event().wait()
        except KeyboardInterrupt:
            pass

    async def stop(self):
        """停止应用。"""
        logger.info("[Lumi-Hub] 正在关闭...")
        await self.mcp_manager.shutdown()
        await self.ws_server.stop()
        logger.info("[Lumi-Hub] 已关闭")


def main():
    """应用入口。"""
    app = LumiHubApp()
    try:
        asyncio.run(app.start())
    except KeyboardInterrupt:
        logger.info("[Lumi-Hub] 收到中断信号，正在退出...")


if __name__ == "__main__":
    main()
