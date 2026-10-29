from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, Callable, Coroutine

# 配置日志输出格式
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("lumi")

from .agent_loop import AgentLoop
from .database import DatabaseManager
from .handlers import (
    AuthHandlersMixin,
    ChatHandlersMixin,
    HistoryHandlersMixin,
    LlmHandlersMixin,
    McpHandlersMixin,
    MemorySkillHandlersMixin,
    PersonaHandlersMixin,
    SessionHandlersMixin,
    ToolHandlersMixin,
    UploadHandlersMixin,
    VoiceHandlersMixin,
)
from .llm import create_provider
from .mcp_manager import LumiMCPManager
from .memory_manager import MemoryManager
from .persona_manager import PersonaManager
from .skill_manager import SkillManager
from .tool_registry import ToolRegistry
from .voice_extensions import (
    DashScopeTTSProvider,
    SpeechSessionController,
    VoiceExtensionRegistry,
)
from .ws_server import LumiWSServer


class LumiHubApp(
    AuthHandlersMixin,
    ChatHandlersMixin,
    HistoryHandlersMixin,
    LlmHandlersMixin,
    McpHandlersMixin,
    MemorySkillHandlersMixin,
    PersonaHandlersMixin,
    SessionHandlersMixin,
    ToolHandlersMixin,
    UploadHandlersMixin,
    VoiceHandlersMixin,
):
    """Lumi-Hub 2.0 主应用。

    采用 Mixin 架构解耦业务领域（Auth, Chat, LLM, MCP, Session, Tool, Upload, Voice, Memory/Skill）。
    自身仅承载生命周期管理与 WebSocket 核心路由器。
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
        self._active_workspace: str = ""

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

        # 推理思考强度 (Reasoning Effort: low / medium / high, 默认 high)
        _initial_cfg = self._load_llm_config()
        self._reasoning_effort = _initial_cfg.get("reasoning_effort", "high")

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
            "LLM_SET_THINKING_LEVEL": self._handle_llm_set_thinking_level,
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
