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
)
from .handlers import (
    AuthHandlersMixin,
    HistoryHandlersMixin,
    McpHandlersMixin,
    PersonaHandlersMixin,
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

        # WebSocket 消息路由表
        self._message_handlers: dict[
            str, Callable[[dict, str], Coroutine[Any, Any, None]]
        ] = {
            "CHAT_REQUEST": self._handle_chat_request,
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
            "APP_STATUS": self._handle_app_status,
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
            description="读取本地指定路径文件的内容。支持分页读取。输出中的 Lx: 前缀是行号参考，不是文件内容。",
            parameters={
                "path": {"type": "string", "description": "文件的结构完整路径"},
                "start_line": {"type": "integer", "description": "起始行号，默认为 1", "default": 1},
                "end_line": {"type": "integer", "description": "结束行号（包左不包右），不填则读取到末尾"},
            },
        )
        def read_file(path: str, start_line: int = 1, end_line: int = None) -> str:
            return native_read_file(path, start_line, end_line)

        @registry.register(
            name="search_replace",
            description="【最推荐】IDE 风格的搜索替换。提供待修改的唯一原始代码块(SEARCH)和替换后的代码块(REPLACE)。",
            parameters={
                "path": {"type": "string", "description": "文件完整路径"},
                "search_block": {"type": "string", "description": "待替换的原始代码片段（必须唯一，包含正确缩进）"},
                "replace_block": {"type": "string", "description": "替换后的新代码片段"},
            },
            requires_auth=True,
            auth_action_type="FILE_MODIFY",
        )
        def search_replace(path: str, search_block: str, replace_block: str) -> str:
            return native_search_replace(path, search_block, replace_block)

        @registry.register(
            name="insert_content",
            description="【推荐】在文件的指定行号位置插入新内容。",
            parameters={
                "path": {"type": "string", "description": "文件的结构完整路径"},
                "line_number": {"type": "integer", "description": "要插入的目标行号（1-indexed）"},
                "content": {"type": "string", "description": "要插入的文本内容"},
            },
            requires_auth=True,
            auth_action_type="FILE_MODIFY",
        )
        def insert_content(path: str, line_number: int, content: str) -> str:
            return native_insert_content(path, line_number, content)

        @registry.register(
            name="list_dir",
            description="列出本地指定目录下的文件和文件夹。",
            parameters={
                "path": {"type": "string", "description": "文件夹的结构完整路径"},
            },
        )
        def list_dir(path: str) -> str:
            return native_list_dir(path)

        @registry.register(
            name="write_file",
            description="【高危操作】将内容写入到本地文件中。操作前会自动备份原文件。如果文件不存在则新建。",
            parameters={
                "path": {"type": "string", "description": "文件的结构完整路径"},
                "content": {"type": "string", "description": "要写入的完整内容"},
            },
            requires_auth=True,
            auth_action_type="FILE_MODIFY",
        )
        def write_file(path: str, content: str) -> str:
            return native_write_file(path, content)

        @registry.register(
            name="delete_file",
            description="【高危操作】删除本地指定路径的文件。操作前会自动备份原文件到 .Lumi_cache。",
            parameters={
                "path": {"type": "string", "description": "文件的结构完整路径"},
            },
            requires_auth=True,
            auth_action_type="FILE_DELETE",
        )
        def delete_file(path: str) -> str:
            return native_delete_file(path)

        @registry.register(
            name="replace_content",
            description="【推荐】精确修改文件内容。仅当您只需修改文件的一小部分时使用。必须提供唯一的 old_content。",
            parameters={
                "path": {"type": "string", "description": "文件的结构完整路径"},
                "old_content": {"type": "string", "description": "要被替换的原始代码片段（必须唯一）"},
                "new_content": {"type": "string", "description": "替换后的新代码片段"},
            },
            requires_auth=True,
            auth_action_type="FILE_MODIFY",
        )
        def replace_content(path: str, old_content: str, new_content: str) -> str:
            return native_replace_content(path, old_content, new_content)

        @registry.register(
            name="get_file_size",
            description="获取文件的字节数大小。",
            parameters={
                "path": {"type": "string", "description": "文件的结构完整路径"},
            },
        )
        def get_file_size(path: str) -> str:
            return native_get_file_size(path)

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
            "4. Proactive: If unsure about file paths, use list_dir first. When encountering errors, use read_file on the error line. Everything is problem-solving oriented.\n"
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

        logger.info(f"[Lumi-Hub] 收到消息 (session={ws_session_id}, persona={persona_id}): {user_content[:100]}")

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
                )

        if original_user_content:
            self.db.save_message(
                user_id=user_id,
                role="user",
                content=original_user_content,
                client_msg_id=msg_id,
                persona_id=persona_id,
            )

        # 获取人格
        persona = await self.persona_manager.get_persona(persona_id)
        if not persona:
            persona = await self.persona_manager.get_persona("default")

        # 获取历史消息
        history = self.db.get_messages(
            user_id=user_id,
            persona_id=persona_id,
            limit=50,
            offset=0,
        )

        # 创建 AgentLoop 并执行
        session_id = f"lumi_hub!{user_id}!{context_id}!{persona_id}"
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
            agent_prompt=self._agent_prompt,
            msg_id=msg_id,
            session_id=session_id,
        )

        # 异步执行 Agent
        asyncio.create_task(agent.run(user_content, attachments))

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
        self.active_sessions.pop(ws_session_id, None)

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

    def _load_llm_config(self) -> dict:
        """读取 LLM 配置文件。"""
        if os.path.exists(self._llm_config_path):
            try:
                with open(self._llm_config_path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {"provider": "openai", "api_key": "", "base_url": "", "model": "gpt-4o"}

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
            logger.info(f"[Lumi-Hub] LLM Provider 已热重载: {type(self.llm).__name__}")
        except Exception as e:
            logger.error(f"[Lumi-Hub] LLM Provider 热重载失败: {e}")
            raise

    async def _handle_llm_config_get(self, message: dict, ws_session_id: str) -> None:
        """获取 LLM 配置（不返回完整 API Key，只返回掩码版本）。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        config = self._load_llm_config()

        # 掩码 API Key
        api_key = config.get("api_key", "")
        masked_key = ""
        if api_key:
            if len(api_key) > 8:
                masked_key = api_key[:4] + "*" * (len(api_key) - 8) + api_key[-4:]
            else:
                masked_key = "****"

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_CONFIG_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "success",
                "config": {
                    "provider": config.get("provider", "openai"),
                    "model": config.get("model", ""),
                    "base_url": config.get("base_url", ""),
                    "api_key_masked": masked_key,
                    "api_key_configured": bool(api_key),
                },
            },
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
        for key in ("provider", "api_key", "base_url", "model"):
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
            },
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
