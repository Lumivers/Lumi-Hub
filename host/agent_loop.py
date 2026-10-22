"""
Lumi-Hub 2.0 — 核心 Agent 运行时 (ReAct Loop)
替代 AstrBot 的 EventBus + Pipeline + LLM 调用链。
生命周期：收到用户消息 → run() → 流式返回 → 结束。不常驻，每次对话创建一个实例。
"""
import asyncio
import json
import uuid
import time
import logging
from typing import Optional, Callable
from .trace_collector import TraceCollector, StepTrace

logger = logging.getLogger("lumi")

# ReAct 循环最大迭代次数，防止死循环
MAX_ITERATIONS = 20


class AgentLoop:
    """独立 ReAct Agent 运行时。

    替代 AstrBot 的 EventBus + Pipeline + LLM 调用链。
    每次用户消息创建一个 AgentLoop 实例，执行完毕即销毁。
    """

    def __init__(
        self,
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
        skill_prompt: str = "",
        msg_id: str = "",
        session_id: str = "default",
        workspace_dir: str = "",
    ):
        self.llm = llm_provider
        self.tools = tool_registry
        self.persona_system_prompt = persona_system_prompt
        self.history = history_messages
        self.ws_server = ws_server
        self.ws_session_id = ws_session_id
        self.user_id = user_id
        self.persona_id = persona_id
        self.db = db
        self.mcp_manager = mcp_manager
        self.memory_manager = memory_manager
        self.agent_prompt = agent_prompt
        self.skill_prompt = skill_prompt
        self.msg_id = msg_id or str(uuid.uuid4())[:8]
        self.session_id = session_id
        self.workspace_dir = workspace_dir

        # 任务 Trace 收集器
        self.trace_collector = TraceCollector(session_id=self.session_id, msg_id=self.msg_id)

        # 是否被取消
        self._cancelled = False

    def cancel(self):
        """取消正在运行的 Agent。"""
        self._cancelled = True

    async def run(self, user_message: str, attachments: list[dict] = None):
        """执行一次完整的 ReAct 循环。

        1. 构建 messages: system + history + user (+ attachment hints)
        2. 调用 LLM (streaming)
        3. 如果 LLM 返回 tool_calls:
           a. 发送 TOOL_CALL_START 给客户端
           b. 检查是否需要审批
           c. 执行工具
           d. 发送 TOOL_CALL_RESULT 给客户端
           e. 结果回填 messages，回到步骤 2
        4. 如果是文本回复: stream 到客户端，结束
        5. 发送 CHAT_RESPONSE_END 解锁前端
        """
        try:
            # 检索与当前消息相关的记忆
            relevant_memories = []
            if self.memory_manager and self.user_id:
                try:
                    relevant_memories = await self.memory_manager.retrieve_relevant(
                        self.user_id, self.persona_id, user_message, top_k=5
                    )
                except Exception as e:
                    logger.warning(f"[AgentLoop] 检索记忆失败: {e}")

            # 构建 system prompt
            system_prompt = self._build_system_prompt(relevant_memories)

            # 构建 messages 数组
            messages = self._build_messages(system_prompt, user_message, attachments)

            # 获取工具 schema
            tool_schemas = await self.tools.get_all_schemas_with_mcp()

            # ReAct 循环
            for iteration in range(MAX_ITERATIONS):
                if self._cancelled:
                    logger.info(f"[AgentLoop] Agent 已被取消 (session={self.session_id})")
                    break

                # 准备送入 LLM 的 messages (进行过桥抽板剪枝)
                prepared_messages = self._compact_messages(messages, keep_recent_tools=2)

                # 调用 LLM
                full_text = ""
                tool_calls = None
                text_started = False

                async for event in self.llm.chat_stream(
                    messages=prepared_messages,
                    tools=tool_schemas if tool_schemas else None,
                ):
                    if self._cancelled:
                        break

                    if event["type"] == "text":
                        if not text_started:
                            text_started = True
                        full_text += event["content"]
                        await self._stream_text(event["content"])

                    elif event["type"] == "text_end":
                        pass  # 文本结束，后面统一处理

                    elif event["type"] == "tool_calls":
                        tool_calls = event["calls"]

                    elif event["type"] == "error":
                        error_msg = event["message"]
                        logger.error(f"[AgentLoop] LLM 调用失败: {error_msg}")
                        await self._send_error(error_msg)
                        await self._send_chat_end()
                        return

                if self._cancelled:
                    break

                # 如果有工具调用，执行工具并继续循环
                if tool_calls:
                    # 将 assistant 的 tool_calls 回填到 messages
                    assistant_msg = {"role": "assistant", "content": full_text or None, "tool_calls": []}
                    for tc in tool_calls:
                        assistant_msg["tool_calls"].append({
                            "id": tc["id"],
                            "type": "function",
                            "function": {
                                "name": tc["name"],
                                "arguments": json.dumps(tc["arguments"], ensure_ascii=False),
                            },
                        })
                    messages.append(assistant_msg)

                    # 逐个执行工具
                    for tc in tool_calls:
                        if self._cancelled:
                            break

                        tool_name = tc["name"]
                        tool_args = dict(tc["arguments"])
                        tool_call_id = tc["id"]

                        # 工作区目录 (CWD) 与相对路径安全注入
                        if self.workspace_dir:
                            if "path" in tool_args and isinstance(tool_args["path"], str):
                                p = tool_args["path"].strip()
                                if p and not os.path.isabs(p):
                                    tool_args["path"] = os.path.normpath(os.path.join(self.workspace_dir, p))
                            if tool_name == "run_command" and not tool_args.get("cwd"):
                                tool_args["cwd"] = self.workspace_dir

                        # 1. 记录并通知 Step 启动
                        step = self.trace_collector.start_step(tool_name, tool_args)
                        await self._send_trace_step_update(step)
                        await self._send_tool_call_start(tool_name, tool_args)

                        # 2. 执行工具
                        result = await self.tools.execute(
                            name=tool_name,
                            arguments=tool_args,
                            auth_callback=self.wait_for_auth,
                        )

                        # 3. 捕获 exit code (针对 run_command 等工具)
                        exit_code = None
                        if "[Exit Code]" in result:
                            try:
                                for line in result.splitlines():
                                    if line.startswith("[Exit Code]"):
                                        exit_code = int(line.split("]")[1].strip())
                                        break
                            except Exception:
                                pass

                        success = not result.startswith("Error:") and (exit_code is None or exit_code == 0)

                        # 4. 记录并通知 Step 完成
                        step.finish(
                            success=success,
                            output=result,
                            exit_code=exit_code,
                            error=None if success else (result[:200] if result else "Execution failed"),
                        )
                        await self._send_trace_step_update(step)
                        await self._send_tool_call_result(tool_name, success, step.output_summary)

                        # 将工具结果回填到 messages (保持未经裁剪的完整输出，供下一轮即时消费)
                        messages.append({
                            "role": "tool",
                            "tool_call_id": tool_call_id,
                            "content": result,
                        })

                    # 继续循环，让 LLM 处理工具结果
                    continue

                else:
                    # 纯文本回复，保存到数据库
                    if full_text and self.db and self.user_id:
                        self.db.save_message(
                            user_id=self.user_id,
                            role="assistant",
                            content=full_text,
                            client_msg_id=f"{self.msg_id}_ai",
                            persona_id=self.persona_id,
                            session_id=self.session_id,
                        )

                    # 触发记忆提取（异步，不阻塞回复）
                    if self.memory_manager and full_text:
                        asyncio.create_task(
                            self._extract_memories(user_message, full_text)
                        )

                    break

            # 发送 Trace 完整汇总
            await self._send_trace_summary()

            # 发送结束信号
            await self._send_chat_end()

        except Exception as e:
            logger.error(f"[AgentLoop] 运行异常: {e}", exc_info=True)
            await self._send_error(f"Agent 运行异常: {e}")
            await self._send_chat_end()

    def _build_system_prompt(self, relevant_memories: list[dict] = None) -> str:
        """构建 system prompt。"""
        prompt = self.persona_system_prompt
        if self.agent_prompt:
            prompt += "\n\n" + self.agent_prompt
        if self.skill_prompt:
            prompt += "\n\n### ACTIVE_SKILL_WORKFLOW ###\n" + self.skill_prompt
        if relevant_memories:
            mem_text = "\n[关于该用户的长期记忆与偏好]\n" + "\n".join(
                f"- [{m['category']}] {m['content']}" for m in relevant_memories
            )
            prompt += "\n\n" + mem_text
        return prompt

    def _build_messages(
        self, system_prompt: str, user_message: str, attachments: list[dict] = None
    ) -> list[dict]:
        """构建 messages 数组。"""
        messages = [{"role": "system", "content": system_prompt}]

        # 添加历史消息
        for msg in self.history:
            messages.append({
                "role": msg.get("role", "user"),
                "content": msg.get("content", ""),
            })

        # 构建用户消息（含附件提示）
        content = user_message
        if attachments:
            attachment_lines = []
            for att in attachments:
                if not isinstance(att, dict):
                    continue
                file_name = att.get("file_name", "未命名文件")
                mime_type = att.get("mime_type", "application/octet-stream")
                size_bytes = att.get("size_bytes", 0)
                attachment_lines.append(f"- {file_name} ({mime_type}, {size_bytes} bytes)")

            if attachment_lines:
                content += "\n\n[附件列表]\n" + "\n".join(attachment_lines)

        messages.append({"role": "user", "content": content})
        return messages

    async def _stream_text(self, content: str):
        """将 LLM 文本回复逐 chunk 通过 WebSocket 发送。"""
        chunk_msg = {
            "message_id": self.msg_id,
            "type": "CHAT_STREAM_CHUNK",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "chunk": content,
                "finished": False,
            },
        }
        await self.ws_server.send_to_client(self.ws_session_id, chunk_msg)

    async def _send_tool_call_start(self, tool_name: str, arguments: dict):
        """通知客户端工具调用开始。"""
        msg = {
            "message_id": self.msg_id,
            "type": "TOOL_CALL_START",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "tool_name": tool_name,
                "arguments": arguments,
            },
        }
        await self.ws_server.send_to_client(self.ws_session_id, msg)

    async def _send_tool_call_result(self, tool_name: str, success: bool, summary: str):
        """通知客户端工具调用结果。"""
        msg = {
            "message_id": self.msg_id,
            "type": "TOOL_CALL_RESULT",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "tool_name": tool_name,
                "success": success,
                "summary": summary,
            },
        }
        await self.ws_server.send_to_client(self.ws_session_id, msg)

    async def _send_trace_step_update(self, step: StepTrace):
        """通知客户端 Step Trace 状态更新。"""
        msg = {
            "message_id": self.msg_id,
            "type": "TRACE_STEP_UPDATE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": step.to_dict(),
        }
        await self.ws_server.send_to_client(self.ws_session_id, msg)

    async def _send_trace_summary(self):
        """通知客户端本次对话的完整 Trace 汇总。"""
        summary = self.trace_collector.export_summary()
        if summary.get("step_count", 0) > 0:
            msg = {
                "message_id": self.msg_id,
                "type": "TRACE_SUMMARY",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": summary,
            }
            await self.ws_server.send_to_client(self.ws_session_id, msg)

    def _compact_messages(self, messages: list[dict], keep_recent_tools: int = 2) -> list[dict]:
        """Observation Compaction (过桥抽板):
        对历史消息中过早的 tool observation 进行剪枝压缩，避免上下文与 Token 膨胀。
        仅保留最近 keep_recent_tools 次工具调用的完整输出，更早的输出若超过 300 字符则折叠成摘要。
        """
        compacted = []
        tool_indices = [i for i, m in enumerate(messages) if m.get("role") == "tool"]
        uncompressed_indices = set(tool_indices[-keep_recent_tools:]) if tool_indices else set()

        for idx, msg in enumerate(messages):
            if msg.get("role") == "tool" and idx not in uncompressed_indices:
                content = msg.get("content", "")
                if len(content) > 300:
                    lines = content.strip().splitlines()
                    summary_head = lines[0] if lines else ""
                    summary_tail = lines[-1] if len(lines) > 1 else ""
                    pruned_content = (
                        f"[Observation Pruned (Context Compaction)]\n"
                        f"Original output was {len(content)} chars ({len(lines)} lines).\n"
                        f"Summary Head: {summary_head[:120]}\n"
                        f"Summary Tail: {summary_tail[:120]}"
                    )
                    compacted.append({**msg, "content": pruned_content})
                    continue
            compacted.append(msg)
        return compacted

    async def _send_chat_end(self):
        """发送 CHAT_RESPONSE_END 解锁前端。"""
        msg = {
            "message_id": self.msg_id,
            "type": "CHAT_RESPONSE_END",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success"},
        }
        await self.ws_server.send_to_client(self.ws_session_id, msg)

    async def _send_error(self, error_detail: str):
        """发送错误消息给客户端。"""
        msg = {
            "message_id": self.msg_id,
            "type": "CHAT_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "content": f"⚠️ {error_detail}",
                "status": "error",
                "persona": self.persona_id,
            },
        }
        await self.ws_server.send_to_client(self.ws_session_id, msg)

    async def wait_for_auth(
        self,
        action_type: str,
        target_path: str,
        description: str,
        tool_name: str = "",
        diff_preview: str = "",
    ) -> bool:
        """向客户端发送 AUTH_REQUIRED 并等待 AUTH_RESPONSE。

        原 lumi_event.py 中的审批逻辑，已迁移至此。
        返回 True 表示已获批准，False 表示拒绝或超时。
        """
        auth_msg_id = f"auth-{str(uuid.uuid4())[:8]}"

        auth_req = {
            "message_id": auth_msg_id,
            "type": "AUTH_REQUIRED",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "task_id": auth_msg_id,
                "action_type": action_type,
                "risk_level": "HIGH",
                "target_path": target_path,
                "description": description,
                "tool_name": tool_name,
                "diff_preview": diff_preview,
                "timeout_seconds": 60,
            },
        }

        logger.info(f"[AgentLoop] 已发送审批请求 ({action_type}): {target_path}")
        await self.ws_server.send_to_client(self.ws_session_id, auth_req)

        # 异步等待审批响应
        resp = await self.ws_server.wait_for_response(
            self.ws_session_id, auth_msg_id, timeout=60
        )

        if not resp:
            logger.warning(f"[AgentLoop] 审批超时或无响应: {action_type}")
            return False

        payload = resp.get("payload", {})
        decision = payload.get("decision", "REJECTED")

        if decision == "APPROVED":
            logger.info(f"[AgentLoop] 用户已批准操作: {action_type}")
            return True
        else:
            logger.warning(f"[AgentLoop] 用户拒绝了操作: {action_type}")
            return False

    async def _extract_memories(self, user_message: str, assistant_response: str):
        """异步提取对话记忆。不阻塞主流程。"""
        try:
            if self.memory_manager:
                conversation = [
                    {"role": "user", "content": user_message},
                    {"role": "assistant", "content": assistant_response},
                ]
                await self.memory_manager.extract_memories(
                    self.user_id, self.persona_id, conversation
                )
        except Exception as e:
            logger.warning(f"[AgentLoop] 记忆提取失败（不影响主流程）: {e}")
