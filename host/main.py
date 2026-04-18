"""
Lumi-Hub AstrBot 平台适配器
作为 AstrBot 的自定义消息平台，替代 QQ 对接 AstrBot。
WebSocket Client 的消息通过此适配器进入 AstrBot 的 LLM 管道。
"""
import asyncio
import time
import uuid
import json
import os
from collections.abc import Coroutine
from typing import Any, Callable

from astrbot.core import db_helper

from astrbot.core.platform import (
    AstrBotMessage,
    MessageMember,
    MessageType,
    Platform,
    PlatformMetadata,
)
from astrbot.core.platform.astr_message_event import MessageSesion
from astrbot.core.platform.register import register_platform_adapter
from astrbot.core.message.message_event_result import MessageChain
from astrbot.core.message.components import Plain, Image, Video
from astrbot.core.star import Star

from .ws_server import LumiWSServer
from .lumi_event import LumiMessageEvent
from .database.manager import DatabaseManager
from .mcp_manager import LumiMCPManager
from .handlers import (
    AuthHandlersMixin,
    McpHandlersMixin,
    UploadHandlersMixin,
    VoiceHandlersMixin,
)
from .voice_extensions import (
    DashScopeTTSProvider,
    SpeechSessionController,
    VoiceExtensionRegistry,
)

from astrbot.api import logger
from astrbot.api.event import filter, AstrMessageEvent
from astrbot.api.star import register, Context

# 全局共享状态，用于跨类传递实例
_lumi_shared_state = {}

@register("lumi_hub", "Lumi-Hub", "Lumi-Hub Native Tools Plugin", "1.0.0")
class LumiHub(Star):
    """AstrBot 插件壳与原生工具中心。
    包含轻量级的原生 Python 本地执行工具 (双轨制 - Python Native Track)
    """

    async def initialize(self) -> None:
        """插件启动时，深度优化 AI 的 Agent 意识"""
        try:
            pm = self.context.persona_manager
            persona_id = pm.default_persona
            persona = await pm.get_persona(persona_id)
            
            host_dir = os.path.dirname(os.path.realpath(__file__))
            project_root = os.path.dirname(host_dir)
            data_dir = os.path.join(project_root, "data")
            
            self.mcp_manager = LumiMCPManager(data_dir=data_dir)
            await self.mcp_manager.initialize()
            
            # Inject into global state so LumiHubAdapter can access it
            _lumi_shared_state["mcp_manager"] = self.mcp_manager
            _lumi_shared_state["persona_manager"] = pm
            
            mcp_tools = await self.mcp_manager.get_all_tools()
            mcp_prompt = ""
            if mcp_tools:
                mcp_prompt = "\n【外部 MCP 工具列表（必须严格匹配 Server 与 Tool 名称调用）】\n"
                for t in mcp_tools:
                    mcp_prompt += f"■ Server: `{t['server_name']}`, Tool: `{t['tool_name']}`\n  Desc: {t.get('description', '')}\n  Schema: {json.dumps(t.get('inputSchema', {}), ensure_ascii=False)}\n"
            
            agent_trigger = "### LUMI_IDE_AGENT_v2 ###"
            # 采用 IDE 风格的强力指令集
            agent_prompt = (
                f"\n\n{agent_trigger}\n"
                "【核心指令集：IDE 模式】\n"
                "你现在是一个具备完整权限的高级软件工程师 Agent。你的工作效率取决于你的“少说多做”。\n"
                "1. **ReAct 循环**：当你收到代码修改请求，请务必遵循：[思考 -> 读 -> 思考 -> 改/增/删 -> 验证]。\n"
                "2. **严禁中断**：一旦 `read_file` 成功返回，你必须立即分析并调用 `search_replace` 或 `insert_content`。严禁在读取成功后向用户汇报“我已经读到了，这是内容”，除非你的最终修改已完成。\n"
                "3. **精准编辑**：优先使用 `search_replace`。提供待修改的一段唯一的原始代码块（SEARCH）和替换后的代码块（REPLACE）。注意缩进必须严格匹配。\n"
                "4. **主动性**：如果你不确定文件路径，先用 `list_dir`。发现错误时，先 `read_file` 报错行号。一切以解决问题为导向，而非复读代码内容。\n"
                "5. **MCP 工具调用**：外部工具列表见下方。若需调用，请明确使用 `call_mcp_tool`。`server_name` 和 `tool_name` 必须**完全复制**下方列表中的值，严禁自行编造（例如不能把 notion 写成 mcp-notion，不能把 notion-search 简写为 search）！`arguments_json` 必须严格遵循对应工具的 Schema。\n"
                "########################"
                f"{mcp_prompt}"
            )

            
            cleaned_prompt = persona.system_prompt
            # 清理历史旧版指令标签（如果有）以及当前版本的标签，确保每次启动都重新注入最新的 MCP 工具列表
            for old_tag in ["### LUMI_AGENT_RULES ###", "### LUMI_IDE_AGENT_v1 ###", agent_trigger]:
                if old_tag in cleaned_prompt:
                    idx = cleaned_prompt.find(old_tag)
                    cleaned_prompt = cleaned_prompt[:idx].strip()
            
            new_prompt = cleaned_prompt + agent_prompt
            await pm.update_persona(persona_id, system_prompt=new_prompt)
            logger.info(f"[Lumi-Hub] 已成功为 '{persona_id}' 注入最新的 IDE-Style 及 MCP Agent 指令。")
        except Exception as e:
            logger.error(f"[Lumi-Hub] 增强人格失败: {e}")

    async def terminate(self) -> None:
        """插件卸载或退出时执行清理。"""
        # MCP shutdown moved to adapter
        pass

    @filter.command("test_lumi")
    async def test_lumi(self, event: AstrMessageEvent):
        '''测试 Lumi-Hub 插件是否加载成功'''
        yield event.plain_result("Lumi-Hub 原生工具插件已就绪！")

    @filter.llm_tool(name="call_mcp_tool")
    async def call_mcp_tool(self, event: AstrMessageEvent, server_name: str, tool_name: str, arguments_json: str):
        '''调用外部 MCP Server 提供的工具。
        Args:
            server_name(string): 目标 MCP Server 的名称
            tool_name(string): 要调用的工具名称
            arguments_json(string): 传递给工具的参数，必须是合法的 JSON 字符串
        '''
        try:
            arguments = json.loads(arguments_json)
        except json.JSONDecodeError:
            return "Error: arguments_json is not a valid JSON string."
            
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="MCP_TOOL_CALL",
                target_path=f"[{server_name}] {tool_name}",
                description=f"调用外部 MCP 工具: {tool_name}",
                tool_name="call_mcp_tool",
                diff_preview=json.dumps(arguments, indent=2, ensure_ascii=False)
            )
            if not approved:
                return "Error: User rejected the MCP tool call."
                
        if not hasattr(self, "mcp_manager"):
            return "Error: MCP Manager not initialized."
            
        result = await self.mcp_manager.execute_tool(server_name, tool_name, arguments)
        if result.get("error"):
            return f"Error executing tool: {result.get('error')}"
        if result.get("isError"):
            return f"Error executing tool: {json.dumps(result.get('content', []), ensure_ascii=False)}"
        
        return json.dumps(result.get("content", []), ensure_ascii=False)

    @filter.llm_tool(name="read_file")
    async def read_file(self, event: AstrMessageEvent, path: str, start_line: int = 1, end_line: int = None):
        '''读取本地指定路径文件的内容。支持分页读取。
        注意：输出中的 Lx: 前缀是行号参考，不是文件内容，修改时请忽略。
        Args:
            path(string): 文件的结构完整路径
            start_line(number): 起始行号，默认为 1
            end_line(number): 结束行号（包左不包右），不填则读取到末尾
        '''
        logger.info(f"LLM 正在调用 read_file: {path} ({start_line}-{end_line})")
        from .native_tools import read_file
        return read_file(path, start_line, end_line)

    @filter.llm_tool(name="search_replace")
    async def search_replace(self, event: AstrMessageEvent, path: str, search_block: str, replace_block: str):
        '''【最推荐】IDE 风格的搜索替换。
        Args:
            path(string): 文件完整路径
            search_block(string): 必须提供待替换的原始代码片段（必须是在文件中唯一存在的，包含正确的缩进）。
            replace_block(string): 替换后的新代码片段。
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_MODIFY",
                target_path=path,
                description=f"修改文件并应用 SEARCH/REPLACE 块。",
                tool_name="search_replace",
                diff_preview=f"SEARCH:\n{search_block}\n\nREPLACE:\n{replace_block}"
            )
            if not approved:
                return "Error: User rejected the file modification."

        from .native_tools import search_replace
        return search_replace(path, search_block, replace_block)

    @filter.llm_tool(name="insert_content")
    async def insert_content(self, event: AstrMessageEvent, path: str, line_number: int, content: str):
        '''【推荐】在文件的指定行号位置插入新内容。
        Args:
            path(string): 文件的结构完整路径
            line_number(number): 要插入的目标行号（1-indexed）
            content(string): 要插入的文本内容（会自动换行）
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_MODIFY",
                target_path=path,
                description=f"在第 {line_number} 行插入内容。",
                tool_name="insert_content",
                diff_preview=content
            )
            if not approved:
                return "Error: User rejected the file modification."

        from .native_tools import insert_content
        return insert_content(path, line_number, content)


    @filter.llm_tool(name="list_dir")
    async def list_dir(self, event: AstrMessageEvent, path: str):
        '''列出本地指定目录下的文件和文件夹。
        Args:
            path(string): 文件夹的结构完整路径
        '''
        from .native_tools import list_dir
        return list_dir(path)
        
    @filter.llm_tool(name="write_file")
    async def write_file(self, event: AstrMessageEvent, path: str, content: str):
        '''【高危操作】将内容写入到本地文件中。操作前会自动备份原文件。如果文件不存在则新建。
        Args:
            path(string): 文件的结构完整路径
            content(string): 要写入的完整内容
        '''
        if hasattr(event, "wait_for_auth"):
            import os
            approved = await event.wait_for_auth(
                action_type="FILE_CREATE" if not os.path.exists(path) else "FILE_MODIFY",
                target_path=path,
                description=f"全量写入文件内容。",
                tool_name="write_file",
                diff_preview=content[:500] + ("..." if len(content) > 500 else "")
            )
            if not approved:
                return "Error: User rejected the file operation."

        from .native_tools import write_file
        return write_file(path, content)

    @filter.llm_tool(name="delete_file")
    async def delete_file(self, event: AstrMessageEvent, path: str):
        '''【高危操作】删除本地指定路径的文件。操作前会自动备份原文件到 .Lumi_cache。
        Args:
            path(string): 文件的结构完整路径
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_DELETE",
                target_path=path,
                description=f"物理删除文件（已自动备份）。",
                tool_name="delete_file"
            )
            if not approved:
                return "Error: User rejected the file deletion."

        from .native_tools import delete_file
        return delete_file(path)

    @filter.llm_tool(name="replace_content")
    async def replace_content(self, event: AstrMessageEvent, path: str, old_content: str, new_content: str):
        '''【推荐】精确修改文件内容。仅当您只需修改文件的一小部分时使用。必须提供唯一的 old_content。
        Args:
            path(string): 文件的结构完整路径
            old_content(string): 要被替换的原始代码片段（必须唯一）
            new_content(string): 替换后的新代码片段
        '''
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="FILE_MODIFY",
                target_path=path,
                description=f"精确替换文件内容。",
                tool_name="replace_content",
                diff_preview=f"OLD:\n{old_content}\n\nNEW:\n{new_content}"
            )
            if not approved:
                return "Error: User rejected the file modification."

        from .native_tools import replace_content
        return replace_content(path, old_content, new_content)



    @filter.llm_tool(name="get_file_size")
    async def get_file_size(self, event: AstrMessageEvent, path: str):
        '''获取文件的字节数大小
        Args:
            path(string): 文件的结构完整路径
        '''
        from .native_tools import get_file_size
        return get_file_size(path)
@register_platform_adapter(
    adapter_name="lumi_hub",
    desc="Lumi-Hub 自建消息前端平台适配器",
    adapter_display_name="Lumi-Hub",
    default_config_tmpl={
        "type": "lumi_hub",
        "enable": True,
        "id": "lumi_hub",
        "ws_host": "0.0.0.0",
        "ws_port": 8765,
    },
    support_streaming_message=True,
)
class LumiHubAdapter(
    VoiceHandlersMixin,
    UploadHandlersMixin,
    AuthHandlersMixin,
    McpHandlersMixin,
    Platform,
):
    """Lumi-Hub 平台适配器。

    功能：
    1. 启动 WebSocket Server，接收 Flutter Client 连接
    2. 将 Client 消息转为 AstrBotMessage，注入 AstrBot 事件队列
    3. AstrBot 处理后通过 LumiMessageEvent.send() 回复给 Client
    """

    def __init__(
        self,
        platform_config: dict,
        platform_settings: dict,
        event_queue: asyncio.Queue,
    ) -> None:
        super().__init__(platform_config, event_queue)

        self.settings = platform_settings
        ws_host = platform_config.get("ws_host", "0.0.0.0")
        ws_port = platform_config.get("ws_port", 8765)

        self.ws_server = LumiWSServer(host=ws_host, port=ws_port)
        self.ws_server.on_message(self._handle_client_message)
        self.ws_server.on_disconnect(self._handle_ws_disconnect)

        # 初始化数据库管理器，数据存放在项目根目录下的 data 文件夹
        import os
        host_dir = os.path.dirname(os.path.realpath(__file__))
        project_root = os.path.dirname(host_dir)
        data_dir = os.path.join(project_root, "data")
        self.data_dir = data_dir
        self.db = DatabaseManager(data_dir=data_dir)
        self.voice_config_path = os.path.join(data_dir, "voice_config.json")
        self._voice_config_cache = self._load_voice_config()
        self._dashscope_provider: DashScopeTTSProvider | None = None

        # 上传缓存目录与会话状态
        self.upload_root_dir = os.path.join(data_dir, "uploads")
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
        self.allowed_mime_prefixes = (
            "image/",
            "audio/",
        )
        
        # 记录已验证的 websocket session -> user_id
        self.active_sessions: dict[str, int] = {}
        self.voice_registry = VoiceExtensionRegistry()
        self.speech_sessions = SpeechSessionController()
        self._voice_turn_tasks: dict[tuple[str, str], asyncio.Task] = {}
        self._shared_state = _lumi_shared_state
        self._setup_voice_extensions()
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
        }

        self.metadata = PlatformMetadata(
            name="lumi_hub",
            description="Lumi-Hub 自建消息前端",
            id=platform_config.get("id", "lumi_hub"),
            adapter_display_name="Lumi-Hub",
            support_streaming_message=True,
            support_proactive_message=True,
        )

        self._shutdown_event = asyncio.Event()

    def _setup_voice_extensions(self) -> None:
        provider_name = str(os.environ.get("LUMI_VOICE_PROVIDER", "dashscope")).strip().lower()
        if provider_name != "dashscope":
            logger.warning("[Lumi-Hub] Voice provider '%s' is not supported yet", provider_name)
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
            if isinstance(data, dict):
                return data
            return {}
        except Exception as e:
            logger.warning(f"[Lumi-Hub] Failed to load voice config: {e}")
            return {}

    def _save_voice_config(self) -> None:
        try:
            with open(self.voice_config_path, "w", encoding="utf-8") as f:
                json.dump(self._voice_config_cache, f, ensure_ascii=False, indent=2)
        except Exception as e:
            logger.error(f"[Lumi-Hub] Failed to save voice config: {e}")

    def run(self) -> Coroutine[Any, Any, None]:
        """返回平台运行协程，AstrBot 会将其作为 asyncio.Task 启动。"""
        return self._run()

    async def _run(self) -> None:
        """启动 WebSocket Server 并等待关闭信号。"""
        try:
            await self.ws_server.start()
            self.status = __import__(
                "astrbot.core.platform.platform", fromlist=["PlatformStatus"]
            ).PlatformStatus.RUNNING
            logger.info("[Lumi-Hub] 平台适配器已启动")
            await self._shutdown_event.wait()
        except Exception as e:
            logger.error(f"[Lumi-Hub] 平台适配器启动失败: {e}")
            raise

    async def terminate(self) -> None:
        """关闭平台适配器。"""
        logger.info("[Lumi-Hub] 平台适配器关闭中...")

        for task in list(self._voice_turn_tasks.values()):
            if not task.done():
                task.cancel()
        self._voice_turn_tasks.clear()

        self._shutdown_event.set()
        await self.ws_server.stop()
        
        mcp_manager = _lumi_shared_state.get("mcp_manager")
        if mcp_manager:
            logger.info("[Lumi-Hub] 正在关闭 MCP Manager...")
            await mcp_manager.shutdown()

    def meta(self) -> PlatformMetadata:
        """返回平台元数据。"""
        return self.metadata

    async def send_by_session(
        self,
        session: MessageSesion,
        message_chain: MessageChain,
    ) -> None:
        """通过会话发送主动消息（插件主动推送）。"""
        # 从 session_id 中提取 user_id 和 context_id
        # 格式: lumi_hub!{user_id}!{context_id}!{persona_id}
        parts = session.session_id.split("!")
        user_id = None
        persona_id = "default"
        if len(parts) >= 3:
            try:
                user_id = int(parts[1])
            except ValueError:
                pass
        if len(parts) >= 4:
            persona_id = parts[3]

        text_parts = []
        for comp in message_chain.chain:
            if isinstance(comp, Plain):
                text_parts.append(comp.text)
                
        content_str = "".join(text_parts)

        if content_str and user_id is not None:
            # 存入数据库 (无论用户是否在线、连接是否存在都可以保存)
            self.db.save_message(user_id=user_id, role="assistant", content=content_str, persona_id=persona_id)
            
            # 查找所有关联到该 user_id 的 ws_session_id 并分发
            target_ws_ids = [ws_id for ws_id, uid in self.active_sessions.items() if uid == user_id]
            for ws_id in target_ws_ids:
                msg = {
                    "message_id": str(uuid.uuid4())[:8],
                    "type": "CHAT_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "content": content_str,
                        "status": "success",
                        "persona": persona_id,
                    },
                }
                await self.ws_server.send_to_client(ws_id, msg)

        await super().send_by_session(session, message_chain)

    # ---------- WebSocket 消息处理 ----------

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
        active_turn = await self.speech_sessions.clear_session(ws_session_id)
        if active_turn:
            await self.voice_registry.cancel_all(ws_session_id, active_turn)

        stale_voice_keys = [
            key for key in self._voice_turn_tasks.keys() if key[0] == ws_session_id
        ]
        for key in stale_voice_keys:
            task = self._voice_turn_tasks.pop(key, None)
            if task and not task.done():
                task.cancel()

        stale_upload_ids = [
            upload_id
            for upload_id, session in self.upload_sessions.items()
            if session.get("ws_session_id") == ws_session_id
        ]
        for upload_id in stale_upload_ids:
            self._discard_upload_session(upload_id)

    async def _handle_history_request(self, message: dict, ws_session_id: str) -> None:
        user_id = self.active_sessions.get(ws_session_id)
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        if not user_id:
            logger.warning(f"[Lumi-Hub] 拒绝未登录用户的历史记录请求")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "ERROR_ALERT", "source": "host", "target": "client",
                "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"}
            })
            return
            
        payload = message.get("payload", {})
        limit = payload.get("limit", 50)
        offset = payload.get("offset", 0)
        persona_id = payload.get("persona_id", "default")
        
        messages = self.db.get_messages(user_id=user_id, persona_id=persona_id, limit=limit, offset=offset)
        
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "HISTORY_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "messages": messages,
                "has_more": len(messages) == limit
            }
        })

    @filter.llm_tool(name="call_mcp_tool")
    async def call_mcp_tool(self, event: AstrMessageEvent, server_name: str, tool_name: str, arguments_json: str):
        '''调用外部 MCP Server 提供的工具。
        Args:
            server_name(string): 目标 MCP Server 的名称
            tool_name(string): 要调用的工具名称
            arguments_json(string): 传递给工具的参数，必须是合法的 JSON 字符串
        '''
        try:
            arguments = json.loads(arguments_json)
        except json.JSONDecodeError:
            return "Error: arguments_json is not a valid JSON string."
            
        if hasattr(event, "wait_for_auth"):
            approved = await event.wait_for_auth(
                action_type="MCP_TOOL_CALL",
                target_path=f"[{server_name}] {tool_name}",
                description=f"调用外部 MCP 工具: {tool_name}",
                tool_name="call_mcp_tool",
                diff_preview=json.dumps(arguments, indent=2, ensure_ascii=False)
            )
            if not approved:
                return "Error: User rejected the MCP tool call."
                
        if not hasattr(self, "mcp_manager"):
            return "Error: MCP Manager not initialized."
            
        try:
            res = await self.mcp_manager.call_tool(server_name, tool_name, arguments)
        except Exception as e:
            return f"Error calling MCP tool: {e}"
            
        try:
            return json.dumps(res, ensure_ascii=False)
        except Exception as e:
            return f"Error executing tool: {e}"

    async def _handle_chat_request(self, message: dict, ws_session_id: str) -> None:
        """
        处理 CHAT_REQUEST：
        1. 构造 AstrBotMessage
        2. 包装为 LumiMessageEvent
        3. commit_event() 注入 AstrBot 事件队列
        4. AstrBot 自动调 LLM → 调用 event.send() → WebSocket 回传
        """
        payload = message.get("payload", {})
        user_content = payload.get("content", "")
        original_user_content = str(user_content or "").strip()
        attachments = payload.get("attachments", []) or []
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        context_id = payload.get("context_id", ws_session_id)
        persona_id = payload.get("persona_id", "default")

        attachment_lines: list[str] = []
        attachment_hints: list[str] = []
        image_components: list[Image] = []
        video_components: list[Video] = []
        if isinstance(attachments, list):
            for att in attachments:
                if not isinstance(att, dict):
                    continue
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "application/octet-stream"))
                size_bytes = int(att.get("size_bytes", 0) or 0)
                storage_path = str(att.get("storage_path", "") or "")

                attachment_lines.append(
                    f"- {file_name} ({mime_type}, {size_bytes} bytes)"
                )

                if mime_type.startswith("image/") and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    if os.path.exists(abs_path):
                        try:
                            image_components.append(Image.fromFileSystem(abs_path))
                        except Exception as e:
                            logger.warning(f"[Lumi-Hub] 附加图片组件失败({file_name}): {e}")

                if mime_type.startswith("video/") and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    if os.path.exists(abs_path):
                        try:
                            video_components.append(Video.fromFileSystem(abs_path))
                        except Exception as e:
                            logger.warning(f"[Lumi-Hub] 附加视频组件失败({file_name}): {e}")

                if mime_type == "application/pdf" and storage_path:
                    abs_path = os.path.join(self.data_dir, storage_path)
                    preview = self._extract_pdf_preview(abs_path)
                    if preview:
                        attachment_hints.append(
                            f"\n[PDF节选: {file_name}]\n{preview}\n"
                        )
                    else:
                        attachment_hints.append(
                            f"\n[PDF提示: {file_name}] 当前未能提取 PDF 文本，请先基于文件名和上下文回答，并提示用户可粘贴关键段落。\n"
                        )

        if attachment_lines:
            base = (user_content or "").strip()
            if not base:
                base = "我上传了附件，请先确认接收并根据附件内容回答。"
            user_content = (
                f"{base}\n\n"
                f"[附件列表]\n" + "\n".join(attachment_lines)
            )
            if image_components or video_components:
                user_content += (
                    "\n\n[提示] 多媒体附件已作为原始文件随消息提供，请直接识别内容，"
                    "不要调用 fetch_url 访问 file:// 本地路径。"
                )
            if attachment_hints:
                user_content += "\n\n" + "\n".join(attachment_hints)

        logger.info(f"[Lumi-Hub] 收到消息 (session={ws_session_id}, persona={persona_id}): {user_content}")

        # 鉴权校验
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            logger.warning(f"[Lumi-Hub] 未登录用户尝试发送消息，已拒绝")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "ERROR_ALERT", "source": "host", "target": "client",
                "timestamp": int(time.time() * 1000), "payload": {"error_code": "UNAUTHORIZED", "detail": "请先登录"}
            })
            return

        # 把附件作为独立消息存入数据库，与前端拆分展示逻辑对齐
        if isinstance(attachments, list) and attachments:
            for att in attachments:
                att = att or {}
                file_name = str(att.get("file_name", "未命名文件"))
                mime_type = str(att.get("mime_type", "")).lower()
                local_path = str(att.get("local_path", "") or att.get("storage_path", ""))
                
                is_img = mime_type.startswith("image/") or file_name.endswith(('.png', '.jpg', '.jpeg', '.webp'))
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
        
        # 确保 AstrBot 当前的默认人格是用户正在对话的人格
        pm = _lumi_shared_state.get("persona_manager")
        if pm:
            try:
                pm.default_persona = persona_id
            except Exception as e:
                logger.error(f"[Lumi-Hub] 同步人格状态失败: {e}")

        # 1. 构造 AstrBotMessage（和 WebChatAdapter 做法一致）
        abm = AstrBotMessage()
        abm.self_id = "lumi_hub"
        # 使用绑定的真实账号 user_id 而不是动态 session_id 作为识别，让大模型持久记忆用户
        abm.sender = MessageMember(user_id=str(user_id), nickname=f"User_{user_id}")
        abm.type = MessageType.FRIEND_MESSAGE
        # SessionID 格式: lumi_hub!user_id!context_id!persona_id
        abm.session_id = f"lumi_hub!{user_id}!{context_id}!{persona_id}"
        abm.message_id = msg_id
        abm_message_chain = [Plain(user_content)]
        if image_components:
            abm_message_chain.extend(image_components)
        if video_components:
            abm_message_chain.extend(video_components)

        abm.message = abm_message_chain
        abm.message_str = user_content
        abm.raw_message = message
        abm.timestamp = int(time.time())

        # 2. 包装为 LumiMessageEvent
        event = LumiMessageEvent(
            message_str=user_content,
            message_obj=abm,
            platform_meta=self.metadata,
            session_id=abm.session_id,
            ws_server=self.ws_server,
            ws_session_id=ws_session_id,
            db=self.db,
            user_id=user_id,
            persona_id=persona_id,
        )

        # 3. 注入 AstrBot 事件队列（EventBus 会自动 handle、调 LLM、调 event.send()）
        self.commit_event(event)
        logger.info(f"[Lumi-Hub] 事件已提交到 AstrBot 队列 (msg_id={msg_id})")

        # 4. 后台轮询跟踪该事件的生命周期，待其跑完整个 Pipeline 后发送 CHAT_RESPONSE_END 给客户端解锁UI
        async def wait_for_event_completion():
            # 阶段 A: 等待 EventBus 从 _event_queue 中读取并转移到 active_event_registry
            while True:
                if event not in self._event_queue._queue:
                    break
                await asyncio.sleep(0.1)
                
            # 给 Scheduler 注册事件留出一点点时间
            await asyncio.sleep(0.2)
            
            # 阶段 B: 等待 PipelineScheduler 彻底释放该活跃事件
            try:
                from astrbot.core.utils.active_event_registry import active_event_registry
                umo = event.unified_msg_origin
                while True:
                    active_events = active_event_registry._events.get(umo, set())
                    if event not in active_events:
                        break
                    await asyncio.sleep(0.5)
            except Exception as e:
                logger.warning(f"[Lumi-Hub] 跟踪事件生命周期时出错: {e}，将立即解锁。")

            # 阶段 C: 事件生命周期完全结束，发送解锁信号
            logger.debug(f"[Lumi-Hub] 消息 (msg_id={msg_id}) 管道执行已彻底结束，发送 CHAT_RESPONSE_END")
            try:
                await self.ws_server.send_to_client(ws_session_id, {
                    "message_id": msg_id,
                    "type": "CHAT_RESPONSE_END",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {"status": "success"},
                })
            except Exception as e:
                logger.error(f"[Lumi-Hub] 发送 CHAT_RESPONSE_END 失败: {e}")

        asyncio.create_task(wait_for_event_completion())

    async def _handle_persona_switch(self, message: dict, ws_session_id: str) -> None:
        """处理人格切换请求：真实切换 AstrBot 的默认人格。"""
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        pm = _lumi_shared_state.get("persona_manager")
        if pm:
            try:
                pm.default_persona = persona_id
                logger.info(f"[Lumi-Hub] 人格已切换至: {persona_id}")
                status = "switched"
            except Exception as e:
                logger.error(f"[Lumi-Hub] 切换人格失败: {e}")
                status = "error"
        else:
            logger.warning("[Lumi-Hub] persona_manager 未初始化，无法切换人格")
            status = "error"

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "PERSONA_SWITCH",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"persona_id": persona_id, "status": status},
        })

    async def _handle_persona_clear_history(self, message: dict, ws_session_id: str) -> None:
        """清空当前登录用户的所有聊天记录。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        
        if not user_id:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "PERSONA_CLEAR_HISTORY_RESPONSE",
                "source": "host", "target": "client",
                "payload": {"status": "error", "message": "未登录"}
            })
            return
        try:
            count = self.db.clear_messages(user_id, persona_id)
            logger.info(f"[Lumi-Hub] 用户 {user_id} 对人格 {persona_id} 的聊天记录已清空，共 {count} 条")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "PERSONA_CLEAR_HISTORY_RESPONSE",
                "source": "host", "target": "client",
                "payload": {"status": "success", "deleted_count": count}
            })
        except Exception as e:
            logger.error(f"[Lumi-Hub] 清空聊天记录失败: {e}")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "PERSONA_CLEAR_HISTORY_RESPONSE",
                "source": "host", "target": "client",
                "payload": {"status": "error", "message": str(e)}
            })

    async def _handle_message_delete(self, message: dict, ws_session_id: str) -> None:
        """删除当前登录用户在指定人格下的指定消息。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "default")
        message_ids = payload.get("message_ids", [])

        if not user_id:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "MESSAGE_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "payload": {"status": "error", "message": "未登录"}
            })
            return

        if not isinstance(message_ids, list) or not message_ids:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "MESSAGE_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "payload": {"status": "error", "message": "message_ids 不能为空"}
            })
            return

        try:
            deleted_count = self.db.delete_messages(user_id=user_id, message_ids=message_ids, persona_id=persona_id)
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "MESSAGE_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "payload": {"status": "success", "deleted_count": deleted_count}
            })
        except Exception as e:
            logger.error(f"[Lumi-Hub] 删除消息失败: {e}")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "MESSAGE_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "payload": {"status": "error", "message": str(e)}
            })

    async def _handle_persona_delete(self, message: dict, ws_session_id: str) -> None:
        """从 AstrBot 中删除指定人格。"""
        payload = message.get("payload", {})
        persona_id = payload.get("persona_id", "")
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])

        pm = _lumi_shared_state.get("persona_manager")
        if pm and persona_id:
            try:
                await pm.delete_persona(persona_id)
                logger.info(f"[Lumi-Hub] 人格 '{persona_id}' 已删除")
                await self.ws_server.send_to_client(ws_session_id, {
                    "message_id": msg_id, "type": "PERSONA_DELETE_RESPONSE",
                    "source": "host", "target": "client",
                    "payload": {"status": "success", "persona_id": persona_id}
                })
            except Exception as e:
                logger.error(f"[Lumi-Hub] 删除人格 '{persona_id}' 失败: {e}")
                await self.ws_server.send_to_client(ws_session_id, {
                    "message_id": msg_id, "type": "PERSONA_DELETE_RESPONSE",
                    "source": "host", "target": "client",
                    "payload": {"status": "error", "message": str(e)}
                })
        else:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id, "type": "PERSONA_DELETE_RESPONSE",
                "source": "host", "target": "client",
                "payload": {"status": "error", "message": "persona_manager 未初始化或 persona_id 为空"}
            })

    async def _handle_persona_list(self, message: dict, ws_session_id: str) -> None:
        """返回 AstrBot 中已有的人格列表。"""
        try:
            personas = await db_helper.get_personas()
            persona_list = []
            for p in personas:
                persona_list.append({
                    "id": p.persona_id,
                    "name": p.persona_id,  # AstrBot 的 persona_id 就是名称
                    "system_prompt_preview": (p.system_prompt[:200] + "...") if len(p.system_prompt) > 200 else p.system_prompt,
                    "has_begin_dialogs": bool(p.begin_dialogs),
                    "tools": p.tools,
                    "skills": p.skills,
                })
            logger.info(f"[Lumi-Hub] 返回 {len(persona_list)} 个人格")
        except Exception as e:
            logger.error(f"[Lumi-Hub] 读取人格列表失败: {e}")
            persona_list = []

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": message.get("message_id", str(uuid.uuid4())[:8]),
            "type": "PERSONA_LIST",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "personas": persona_list,
            },
        })
