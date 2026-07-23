"""
Lumi-Hub 2.0 — 多 Agent 并行池
管理多个并发的 AgentLoop 实例，支持多会话 Tab 式并行。
"""
import asyncio
import logging
from typing import Optional

from .agent_loop import AgentLoop

logger = logging.getLogger("lumi")


class AgentPool:
    """管理多个并发的 AgentLoop 实例。

    - 每个 session_id 对应一个 AgentLoop
    - 最多 N 个并行（默认 3）
    - 同一 user 的 session 共享人格上下文
    - 工具调用互斥：同一文件不能被两个 Agent 同时修改
    """

    def __init__(self, max_parallel: int = 3):
        self._agents: dict[str, AgentLoop] = {}
        self._semaphore = asyncio.Semaphore(max_parallel)
        self._file_locks: dict[str, asyncio.Lock] = {}

    async def create_session(
        self,
        session_id: str,
        llm_provider,
        tool_registry,
        persona_system_prompt: str,
        history_messages: list[dict],
        ws_server,
        ws_session_id: str,
        user_id: int,
        persona_id: str,
        db,
        mcp_manager=None,
        memory_manager=None,
        agent_prompt: str = "",
        msg_id: str = "",
    ) -> AgentLoop:
        """创建一个新的 Agent 会话。"""
        if session_id in self._agents:
            logger.warning(f"[AgentPool] 会话 '{session_id}' 已存在，将被替换")
            self.cancel_session(session_id)

        agent = AgentLoop(
            llm_provider=llm_provider,
            tool_registry=tool_registry,
            persona_system_prompt=persona_system_prompt,
            history_messages=history_messages,
            ws_server=ws_server,
            ws_session_id=ws_session_id,
            user_id=user_id,
            persona_id=persona_id,
            db=db,
            mcp_manager=mcp_manager,
            memory_manager=memory_manager,
            agent_prompt=agent_prompt,
            msg_id=msg_id,
            session_id=session_id,
        )
        self._agents[session_id] = agent
        logger.info(f"[AgentPool] 创建会话 '{session_id}' (当前活跃: {len(self._agents)})")
        return agent

    async def run(self, session_id: str, user_message: str, attachments: list[dict] = None):
        """在信号量控制下执行 Agent。"""
        agent = self._agents.get(session_id)
        if not agent:
            logger.error(f"[AgentPool] 会话 '{session_id}' 不存在")
            return

        async with self._semaphore:
            try:
                await agent.run(user_message, attachments)
            finally:
                # 执行完毕后清理
                self._agents.pop(session_id, None)
                logger.info(f"[AgentPool] 会话 '{session_id}' 已结束 (剩余: {len(self._agents)})")

    def cancel_session(self, session_id: str):
        """取消一个正在运行的 Agent（前端关闭 Tab）。"""
        agent = self._agents.get(session_id)
        if agent:
            agent.cancel()
            self._agents.pop(session_id, None)
            logger.info(f"[AgentPool] 会话 '{session_id}' 已取消")

    def get_session(self, session_id: str) -> Optional[AgentLoop]:
        """获取会话实例。"""
        return self._agents.get(session_id)

    def list_sessions(self) -> list[dict]:
        """列出所有活跃会话。"""
        return [
            {
                "session_id": sid,
                "persona_id": agent.persona_id,
                "user_id": agent.user_id,
            }
            for sid, agent in self._agents.items()
        ]

    def get_file_lock(self, file_path: str) -> asyncio.Lock:
        """获取文件锁，确保同一文件不被并发修改。"""
        if file_path not in self._file_locks:
            self._file_locks[file_path] = asyncio.Lock()
        return self._file_locks[file_path]

    @property
    def active_count(self) -> int:
        """当前活跃会话数。"""
        return len(self._agents)
