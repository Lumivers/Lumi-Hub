"""
Lumi-Hub 2.0 — 核心 Agent 运行时 (ReAct Loop)
替代 AstrBot 的 EventBus + Pipeline + LLM 调用链。
生命周期：收到用户消息 → run() → 流式返回 → 结束。不常驻，每次对话创建一个实例。
"""
import asyncio
import os
import json
import uuid
import time
import logging
from typing import Optional, Callable
from .trace_collector import TraceCollector, StepTrace

logger = logging.getLogger("lumi")

# ReAct 循环最大迭代次数，保证复杂代码任务有足够深度，同时防止死循环
MAX_ITERATIONS = 40

# 历史对话 Token 阈值，超过则触发滑动窗口摘要提炼
HISTORY_TOKEN_THRESHOLD = 3000
# 滑动窗口保留的最近完整消息数
KEEP_RECENT_MESSAGES = 6


def estimate_tokens(text: str) -> int:
    """估算文本 Token 数量（适配中英混合场景）。"""
    if not text:
        return 0
    cjk_count = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
    other_count = len(text) - cjk_count
    return int(cjk_count * 0.8 + other_count / 3.5) + 1


def estimate_messages_tokens(messages: list[dict]) -> int:
    """估算消息列表总 Token 开销。"""
    total = 0
    for m in messages:
        content = m.get("content") or ""
        total += estimate_tokens(str(content)) + 4
    return total


def get_workspace_summary(workspace_dir: str, max_depth: int = 2, max_entries: int = 60) -> dict:
    """提取工作区概览：主要语言栈与顶层目录结构骨架。"""
    if not workspace_dir or not os.path.exists(workspace_dir) or not os.path.isdir(workspace_dir):
        return {}

    # 1. 识别主要技术栈
    tech_stacks = []

    def check_indicators(check_dir: str):
        indicators = set()
        try:
            for item in os.listdir(check_dir):
                indicators.add(item)
        except Exception:
            pass
        return indicators

    root_items = check_indicators(workspace_dir)
    # 也检查常见一级子目录（例如 client/ 和 host/）
    sub_items = set()
    for d in ("client", "host", "src", "app", "frontend", "backend"):
        sub_p = os.path.join(workspace_dir, d)
        if os.path.isdir(sub_p):
            sub_items.update(check_indicators(sub_p))

    all_indicators = root_items | sub_items

    if "pubspec.yaml" in all_indicators:
        tech_stacks.append("Flutter / Dart")
    if any(k in all_indicators for k in ("requirements.txt", "pyproject.toml", "Pipfile", "setup.py")):
        tech_stacks.append("Python")
    if "package.json" in all_indicators:
        tech_stacks.append("Node.js / Web (JavaScript/TypeScript)")
    if "Cargo.toml" in all_indicators:
        tech_stacks.append("Rust")
    if "go.mod" in all_indicators:
        tech_stacks.append("Go")
    if any(k in all_indicators for k in ("CMakeLists.txt", "Makefile")):
        tech_stacks.append("C / C++")
    if any(k in all_indicators for k in ("pom.xml", "build.gradle", "build.gradle.kts")):
        tech_stacks.append("Java / Kotlin")
    if any(f.endswith((".csproj", ".sln")) for f in all_indicators):
        tech_stacks.append("C# / .NET")

    # 2. 生成过滤后的目录树骨架
    ignored = {
        ".git", ".idea", ".vscode", "build", ".dart_tool", "node_modules",
        "__pycache__", ".pytest_cache", ".venv", "venv", "env", ".Lumi_cache",
        "dist", "target", "bin", "obj", ".gradle"
    }

    tree_lines = []
    entry_count = 0

    def walk_tree(current_dir: str, depth: int, prefix: str):
        nonlocal entry_count
        if depth > max_depth or entry_count >= max_entries:
            return
        try:
            entries = sorted(os.listdir(current_dir))
        except Exception:
            return

        visible = [e for e in entries if e not in ignored and not e.startswith(".")]
        for i, entry in enumerate(visible):
            if entry_count >= max_entries:
                tree_lines.append(f"{prefix}└── ... (其余文件已折叠)")
                break
            full_path = os.path.join(current_dir, entry)
            is_last = (i == len(visible) - 1)
            connector = "└── " if is_last else "├── "
            new_prefix = prefix + ("    " if is_last else "│   ")

            if os.path.isdir(full_path):
                tree_lines.append(f"{prefix}{connector}{entry}/")
                entry_count += 1
                walk_tree(full_path, depth + 1, new_prefix)
            else:
                tree_lines.append(f"{prefix}{connector}{entry}")
                entry_count += 1

    walk_tree(workspace_dir, 1, "")

    return {
        "workspace_dir": workspace_dir,
        "tech_stacks": ", ".join(tech_stacks) if tech_stacks else "通用项目 (General)",
        "tree_skeleton": "\n".join(tree_lines) if tree_lines else "(空目录)"
    }


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
            # 1. 长对话历史 Token 压缩与滑动窗口提炼
            compacted_history = await self._compact_history_if_needed(self.history)

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

            # 构建 messages 数组（支持 Persona 切换平滑锚点）
            messages = self._build_messages(
                system_prompt, user_message, attachments, history_messages=compacted_history
            )

            # 获取工具 schema
            tool_schemas = await self.tools.get_all_schemas_with_mcp()

            # ReAct 循环
            full_text = ""
            for iteration in range(MAX_ITERATIONS):
                if self._cancelled:
                    logger.info(f"[AgentLoop] Agent 已被取消 (session={self.session_id})")
                    break

                # 准备送入 LLM 的 messages (进行过桥抽板剪枝)
                prepared_messages = self._compact_messages(messages, keep_recent_tools=2)

                # 最后一轮强制不再提供工具，促使模型输出最终综合总结，避免静默结束
                tools_for_step = tool_schemas if (tool_schemas and iteration < MAX_ITERATIONS - 1) else None
                if iteration == MAX_ITERATIONS - 1 and tool_schemas:
                    prepared_messages.append({
                        "role": "user",
                        "content": "【系统提示】已接近单次任务步数上限，请基于前面所有工具已获取的信息，输出完整、清晰的分析与最终总结，不要再调用任何工具。",
                    })

                # 调用 LLM
                full_text = ""
                tool_calls = None
                text_started = False

                async for event in self.llm.chat_stream(
                    messages=prepared_messages,
                    tools=tools_for_step,
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
                            if tool_name in ("search_workspace", "grep_code", "find_symbol"):
                                if not tool_args.get("workspace_dir") and not tool_args.get("path"):
                                    if "workspace_dir" in tool_args or tool_name == "search_workspace":
                                        tool_args["workspace_dir"] = self.workspace_dir
                                    if "path" in tool_args or tool_name in ("grep_code", "find_symbol"):
                                        tool_args["path"] = self.workspace_dir

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

                        if success and tool_name in ("write_file", "insert_content", "replace_content", "search_replace"):
                            file_p = tool_args.get("path")
                            if file_p:
                                self.trace_collector.record_file_changed(file_p)

                        # 每步工具执行完成后立即持久化 Trace 状态，避免进程中断后丢失
                        self._persist_current_state(full_text=full_text)

                        # 将工具结果回填到 messages (保持未经裁剪的完整输出，供下一轮即时消费)
                        messages.append({
                            "role": "tool",
                            "tool_call_id": tool_call_id,
                            "content": result,
                        })

                    # 继续循环，让 LLM 处理工具结果
                    continue

                else:
                    # 纯文本回复，保存到数据库及 Trace 状态
                    self._persist_current_state(full_text=full_text)

                    # 触发记忆提取（异步，不阻塞回复）
                    if self.memory_manager and full_text:
                        asyncio.create_task(
                            self._extract_memories(user_message, full_text)
                        )

                    break

            # 尝试通过 git diff 检测本次任务产生的文件变动
            if self.workspace_dir and os.path.exists(os.path.join(self.workspace_dir, ".git")):
                try:
                    import subprocess
                    proc = subprocess.run(
                        ["git", "diff", "--numstat"],
                        cwd=self.workspace_dir,
                        capture_output=True,
                        text=True,
                        timeout=3,
                    )
                    if proc.returncode == 0 and proc.stdout.strip():
                        for line in proc.stdout.strip().splitlines():
                            parts = line.split("\t")
                            if len(parts) >= 3:
                                add, dele, rel_p = parts[0], parts[1], parts[2]
                                full_p = os.path.normpath(os.path.join(self.workspace_dir, rel_p))
                                self.trace_collector.record_file_changed(
                                    full_p,
                                    additions=int(add) if add.isdigit() else 0,
                                    deletions=int(dele) if dele.isdigit() else 0,
                                )
                except Exception as e:
                    logger.debug(f"[AgentLoop] git diff 提取变动文件失败: {e}")

            # 发送 Trace 完整汇总
            await self._send_trace_summary()

            # 将包含全部变动文件的最新 Trace 状态落库
            self._persist_current_state(full_text=full_text)

            # 发送结束信号
            await self._send_chat_end()

        except Exception as e:
            logger.error(f"[AgentLoop] 运行异常: {e}", exc_info=True)
            await self._send_error(f"Agent 运行异常: {e}")
            await self._send_chat_end()
        finally:
            # 无论正常结束、用户取消还是异常中断，均确保当前 Trace 与文本落库保存
            self._persist_current_state(full_text=full_text)

    async def _send_event(self, message: dict):
        """统一向用户的所有在线端广播事件；若无 user_id 则单播至当前连接。"""
        if self.user_id and hasattr(self.ws_server, "broadcast_to_user"):
            await self.ws_server.broadcast_to_user(self.user_id, message)
        else:
            await self.ws_server.send_to_client(self.ws_session_id, message)

    async def _compact_history_if_needed(self, history: list[dict]) -> list[dict]:
        """长对话滑动窗口与上下文自动摘要压缩 (Context Compaction):
        当 self.history 估算 Token 超过设定阈值时，自动将早期历史提炼为结构化
        【上下文摘要节点 (Summary Node)】，保持'历史摘要 + 最近 k 轮细粒度消息'。
        """
        if not history or len(history) <= KEEP_RECENT_MESSAGES:
            return history

        total_tokens = estimate_messages_tokens(history)
        if total_tokens <= HISTORY_TOKEN_THRESHOLD:
            return history

        logger.info(
            f"[AgentLoop] 对话历史 Token ({total_tokens}) 超过阈值 ({HISTORY_TOKEN_THRESHOLD})，触发上下文摘要压缩"
        )

        early_msgs = history[:-KEEP_RECENT_MESSAGES]
        recent_msgs = history[-KEEP_RECENT_MESSAGES:]

        summary_text = await self._summarize_early_dialogue(early_msgs)
        if not summary_text:
            return history

        summary_node = {
            "role": "system",
            "content": (
                "### 上下文历史摘要 (Context Summary Node) ###\n"
                "以下为本会话早期对话记录的结构化摘要（包含历史讨论、关键决策与已完成操作）：\n"
                f"{summary_text}\n"
                "############################################"
            ),
        }

        return [summary_node] + recent_msgs

    async def _summarize_early_dialogue(self, messages: list[dict]) -> str:
        """调用轻量 LLM 异步提炼早期对话历史为结构化摘要，带降级机制。"""
        dialogue_lines = []
        for m in messages:
            role = m.get("role", "user")
            content = str(m.get("content", ""))
            if len(content) > 400:
                content = content[:200] + " ... " + content[-150:]
            dialogue_lines.append(f"{role}: {content}")
        dialogue_text = "\n".join(dialogue_lines)

        summary_prompt = [
            {
                "role": "system",
                "content": (
                    "你是一个对话上下文提炼专家。请将以下早期对话记录提炼为一个结构化【历史摘要】。\n"
                    "要求：\n"
                    "1. 提取讨论的核心目标、用户要求、关键决定、以及已修改或操作过的文件/代码事实。\n"
                    "2. 剔除寒暄与无意义细节，按要点列表（- 条目）呈现。\n"
                    "3. 保持简练，控制在 300 字以内。"
                ),
            },
            {"role": "user", "content": dialogue_text},
        ]

        try:
            summary_result = ""
            async def _do_chat():
                nonlocal summary_result
                async for ev in self.llm.chat_stream(messages=summary_prompt):
                    if ev.get("type") == "text":
                        summary_result += ev.get("content", "")

            await asyncio.wait_for(_do_chat(), timeout=8.0)
            cleaned_summary = summary_result.strip()
            if cleaned_summary:
                return cleaned_summary
        except Exception as e:
            logger.warning(f"[AgentLoop] LLM 生成上下文历史摘要失败或超时，降级为关键条目抽取: {e}")

        # 降级提取：抽取非空的代表性行
        extracted = []
        for m in messages:
            r = m.get("role", "user")
            c = str(m.get("content", "")).strip().splitlines()
            first = c[0][:100] if c else ""
            if first:
                extracted.append(f"- [{r}] {first}")
        return "\n".join(extracted[:10])

    def _build_system_prompt(self, relevant_memories: list[dict] = None) -> str:
        """构建 system prompt，动态感知工作区上下文。"""
        prompt = self.persona_system_prompt
        if self.agent_prompt:
            prompt += "\n\n" + self.agent_prompt
        if self.skill_prompt:
            prompt += "\n\n### ACTIVE_SKILL_WORKFLOW ###\n" + self.skill_prompt

        # 动态感知工作区概览 (Workspace Awareness)
        if self.workspace_dir and os.path.exists(self.workspace_dir):
            summary = get_workspace_summary(self.workspace_dir)
            if summary:
                ws_text = (
                    "\n\n### WORKSPACE_CONTEXT ###\n"
                    f"- 工作区根目录: {summary['workspace_dir']}\n"
                    f"- 检测技术栈: {summary['tech_stacks']}\n"
                    f"- 项目顶层骨架:\n{summary['tree_skeleton']}\n"
                    "- 检索提示: 请优先使用 `search_workspace` 定位文件，`grep_code` 全文搜索代码，`find_symbol` 定位类与函数定义。\n"
                    "###########################"
                )
                prompt += ws_text

        if relevant_memories:
            mem_text = "\n[关于该用户的长期记忆与偏好]\n" + "\n".join(
                f"- [{m['category']}] {m['content']}" for m in relevant_memories
            )
            prompt += "\n\n" + mem_text
        return prompt

    def _build_messages(
        self, system_prompt: str, user_message: str, attachments: list[dict] = None, history_messages: list[dict] = None
    ) -> list[dict]:
        """构建 messages 数组，支持 Persona 切换时平滑注入隔离锚点。"""
        messages = [{"role": "system", "content": system_prompt}]

        hist = history_messages if history_messages is not None else self.history
        current_tracked_persona = None

        # 添加历史消息，并在同一会话切换 Persona 时注入虚拟系统隔离锚点
        for msg in hist:
            msg_persona = msg.get("persona_id")
            if msg_persona and current_tracked_persona is not None and msg_persona != current_tracked_persona:
                messages.append({
                    "role": "system",
                    "content": f"[System: User switched persona to '{msg_persona}']",
                })
            if msg_persona:
                current_tracked_persona = msg_persona

            messages.append({
                "role": msg.get("role", "user"),
                "content": msg.get("content", ""),
            })

        # 若历史最后的人格与本次请求活跃人格不一致，注入当前人格切换锚点
        if current_tracked_persona and self.persona_id and current_tracked_persona != self.persona_id:
            messages.append({
                "role": "system",
                "content": f"[System: User switched persona to '{self.persona_id}']",
            })

        # 构建当前用户消息（含附件提示）
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
        """将 LLM 文本回复逐 chunk 通过 WebSocket 广播至所有在线设备。"""
        chunk_msg = {
            "message_id": self.msg_id,
            "type": "CHAT_STREAM_CHUNK",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "chunk": content,
                "finished": False,
                "session_id": self.session_id,
            },
        }
        await self._send_event(chunk_msg)

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
                "session_id": self.session_id,
            },
        }
        await self._send_event(msg)

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
                "session_id": self.session_id,
            },
        }
        await self._send_event(msg)

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
        await self._send_event(msg)

    async def _send_trace_summary(self):
        """通知客户端本次对话的完整 Trace 汇总。"""
        summary = self.trace_collector.export_summary()
        if summary.get("step_count", 0) > 0 or summary.get("files_changed"):
            msg = {
                "message_id": self.msg_id,
                "type": "TRACE_SUMMARY",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": summary,
            }
            await self._send_event(msg)

    def _persist_current_state(self, full_text: str = ""):
        """将当前生成的回复内容与收集到的工具调用轨迹 (Trace) 持久化至数据库。"""
        if not (self.db and self.user_id):
            return
        summary = self.trace_collector.export_summary()
        has_traces = summary.get("step_count", 0) > 0 or bool(summary.get("files_changed"))
        if not (full_text or has_traces):
            return
        extra_data = {
            "traces": summary.get("steps", []),
            "trace_summary": summary,
            "files_changed": summary.get("files_changed", []),
        } if has_traces else None
        try:
            self.db.save_message(
                user_id=self.user_id,
                role="assistant",
                content=full_text,
                client_msg_id=f"{self.msg_id}_ai",
                persona_id=self.persona_id,
                session_id=self.session_id,
                extra=extra_data,
            )
        except Exception as e:
            logger.warning(f"[AgentLoop] 实时持久化 Trace 异常: {e}")

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
            "payload": {"status": "success", "session_id": self.session_id},
        }
        await self._send_event(msg)

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
                "session_id": self.session_id,
            },
        }
        await self._send_event(msg)

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
