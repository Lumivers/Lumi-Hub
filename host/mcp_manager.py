import os
import json
import logging
import asyncio
from typing import Dict, Any, List

from mcp.client.stdio import stdio_client, StdioServerParameters
from mcp.client.session import ClientSession

logger = logging.getLogger("lumi_hub.mcp")

class LumiMCPManager:
    def __init__(self, data_dir: str):
        self.config_path = os.path.join(data_dir, "mcp_config.json")
        self.servers: Dict[str, dict] = {}
        # Stores active ClientSession objects keyed by server name
        self.sessions: Dict[str, ClientSession] = {}
        self._server_tasks: Dict[str, asyncio.Task] = {}
        self._shutdown_events: Dict[str, asyncio.Event] = {}
    
    async def initialize(self) -> None:
        """Load configuration and initialize connections to all MCP servers."""
        if not os.path.exists(self.config_path):
            logger.info(f"[Lumi MCP] 配置不存在，跳过 MCP 初始化: {self.config_path}")
            return
        
        try:
            with open(self.config_path, "r", encoding="utf-8") as f:
                config = json.load(f)
            self.servers = config.get("mcpServers", {})
        except Exception as e:
            logger.error(f"[Lumi MCP] 读取配置文件失败: {e}")
            return
            
        logger.info(f"[Lumi MCP] 加载到 {len(self.servers)} 个 MCP Servers，正在建立连接...")
        
        for name, srv_conf in self.servers.items():
            await self._connect_server(name, srv_conf)

    def get_config(self) -> dict:
        """Returns the current configuration dict."""
        return {"mcpServers": self.servers}

    async def update_config(self, new_config: dict) -> None:
        """Saves new configuration to disk and hot-reloads the servers."""
        # 1. Update memory
        self.servers = new_config.get("mcpServers", {})
        
        # 2. Write to disk
        try:
            with open(self.config_path, "w", encoding="utf-8") as f:
                json.dump(new_config, f, indent=2, ensure_ascii=False)
            logger.info(f"[Lumi MCP] 配置文件已更新: {self.config_path}")
        except Exception as e:
            logger.error(f"[Lumi MCP] 保存配置文件失败: {e}")
            
        # 3. Shutdown existing servers
        await self.shutdown()
        
        # 4. Re-initialize
        logger.info(f"[Lumi MCP] 正在热重载 {len(self.servers)} 个 MCP Servers...")
        for name, srv_conf in self.servers.items():
            await self._connect_server(name, srv_conf)
            
    async def _server_loop(self, name: str, params: StdioServerParameters):
        shutdown_event = asyncio.Event()
        self._shutdown_events[name] = shutdown_event
        try:
            async with stdio_client(params) as (read_stream, write_stream):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    self.sessions[name] = session
                    logger.info(f"[Lumi MCP] 成功连接至 Server: {name}")
                    
                    # 挂起当前协程，维持 MCP 进程活跃，直到收到退出信号
                    await shutdown_event.wait()
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"[Lumi MCP] 维持 Server '{name}' 时出错或意外退出: {e}")
        finally:
            self._cleanup_server(name)

    async def _connect_server(self, name: str, config: dict):
        command = config.get("command")
        args = config.get("args", [])
        env = config.get("env", {})
        
        # Merge parent environment
        server_env = os.environ.copy()
        for k, v in env.items():
            server_env[k] = v
            
        params = StdioServerParameters(
            command=command,
            args=args,
            env=server_env
        )
        
        # 启动后台守护任务跑 async with 作用域
        task = asyncio.create_task(self._server_loop(name, params))
        self._server_tasks[name] = task
        
        # 等待该 server 成功挂载 session (设置一个合理的连接超时)
        for _ in range(100):  # 10s wait
            if name in self.sessions:
                break
            await asyncio.sleep(0.1)
        else:
            logger.error(f"[Lumi MCP] Server '{name}' 连接或初始化超时。")

    def _cleanup_server(self, name: str):
        self.sessions.pop(name, None)
        self._shutdown_events.pop(name, None)
        self._server_tasks.pop(name, None)
            
    async def shutdown(self):
        """Close all connections and terminate MCP servers."""
        logger.info("[Lumi MCP] 正在关闭全部服务器...")
        # 1. 发送关闭信号
        for name, event in self._shutdown_events.items():
            event.set()
            
        # 2. 等待后台任务平滑退出
        for name, task in list(self._server_tasks.items()):
            if not task.done():
                try:
                    await asyncio.wait_for(task, timeout=3.0)
                except asyncio.TimeoutError:
                    task.cancel()
            self._cleanup_server(name)

    async def get_all_tools(self) -> List[dict]:
        """Get all tools from all currently connected MCP servers."""
        all_tools = []
        for server_name, session in self.sessions.items():
            try:
                tools_response = await session.list_tools()
                for tool in tools_response.tools:
                    # Enrich tool info with server_name to route calls later
                    all_tools.append({
                        "server_name": server_name,
                        "tool_name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema
                    })
            except Exception as e:
                logger.error(f"[Lumi MCP] 获取 Server '{server_name}' 的工具列表失败: {e}")
        return all_tools

    async def execute_tool(self, server_name: str, tool_name: str, arguments: dict) -> Dict[str, Any]:
        """Execute a tool on a specific MCP server."""
        if server_name not in self.sessions:
            return {"error": f"Server '{server_name}' is not connected or does not exist."}
            
        session = self.sessions[server_name]
        try:
            result = await session.call_tool(tool_name, arguments=arguments)
            return {
                "content": [c.model_dump() for c in result.content],
                "isError": result.isError,
            }
        except Exception as e:
            logger.error(f"[Lumi MCP] 执行 Server '{server_name}' 的工具 '{tool_name}' 失败: {e}")
            return {"error": str(e)}
