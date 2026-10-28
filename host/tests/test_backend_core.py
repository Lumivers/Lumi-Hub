import asyncio
import os
import sys
import json
import unittest

# 确保项目根目录在 sys.path 中
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if ROOT_DIR not in sys.path:
    sys.path.insert(0, ROOT_DIR)

from host.native_tools import search_workspace, grep_code, find_symbol
from host.agent_loop import (
    AgentLoop,
    get_workspace_summary,
    estimate_tokens,
    estimate_messages_tokens,
    HISTORY_TOKEN_THRESHOLD,
    KEEP_RECENT_MESSAGES,
    RepeatToolWatchdog,
    GENTLE_REMINDER,
    detailed_reminder,
    canonicalize,
)
from host.ws_server import LumiWSServer


class MockLLMProvider:
    async def chat_stream(self, messages, tools=None):
        yield {"type": "text", "content": "- 讨论了 Lumi-Hub 架构\n- 决定实现多端同步与 RAG 检索"}


class MockToolRegistry:
    async def get_all_schemas_with_mcp(self):
        return []

    async def execute(self, name, arguments, auth_callback=None, user_question_callback=None):
        if name == "ask_user_question" and user_question_callback:
            return await user_question_callback(arguments.get("questions", []))
        return f"Executed {name}"


class TestWorkspaceAwarenessAndCodeRAG(unittest.TestCase):
    def test_workspace_summary_detection(self):
        summary = get_workspace_summary(ROOT_DIR)
        self.assertIn("Flutter / Dart", summary.get("tech_stacks", ""))
        self.assertIn("Python", summary.get("tech_stacks", ""))
        self.assertIn("client/", summary.get("tree_skeleton", ""))
        self.assertIn("host/", summary.get("tree_skeleton", ""))

    def test_search_workspace(self):
        res = search_workspace("agent_loop.py", workspace_dir=ROOT_DIR)
        self.assertIn("host/agent_loop.py", res)
        self.assertIn("[FILE]", res)

    def test_grep_code(self):
        res = grep_code("class AgentLoop", path=ROOT_DIR, max_results=10)
        self.assertIn("host/agent_loop.py", res)
        self.assertIn("class AgentLoop:", res)

    def test_find_symbol(self):
        res = find_symbol("AgentLoop", path=ROOT_DIR, max_results=10)
        self.assertIn("host/agent_loop.py", res)
        self.assertIn("class AgentLoop:", res)

    def test_system_prompt_workspace_injection(self):
        loop = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="You are Lumi, a helpful assistant.",
            history_messages=[],
            ws_server=None,
            ws_session_id="ws-1",
            user_id=1,
            persona_id="default",
            db=None,
            workspace_dir=ROOT_DIR,
        )
        prompt = loop._build_system_prompt()
        self.assertIn("### WORKSPACE_CONTEXT ###", prompt)
        self.assertIn(ROOT_DIR, prompt)
        self.assertIn("Flutter / Dart, Python", prompt)
        self.assertIn("search_workspace", prompt)


class TestContextCompactionAndPersonaSwitch(unittest.IsolatedAsyncioTestCase):
    def test_token_estimation(self):
        text_en = "Hello world! This is a test."
        text_zh = "你好，世界！这是一段用于测试分词与Token估算的中文。"
        self.assertGreater(estimate_tokens(text_en), 0)
        self.assertGreater(estimate_tokens(text_zh), 0)

        msgs = [
            {"role": "user", "content": "你好"},
            {"role": "assistant", "content": "你好！有什么我可以帮你的？"},
        ]
        tokens = estimate_messages_tokens(msgs)
        self.assertGreater(tokens, 10)

    async def test_compact_history_sliding_window(self):
        # 构造超过 HISTORY_TOKEN_THRESHOLD 的超长历史
        long_content = "这里是一段很长很长的历史讨论内容，包含项目架构、数据库设计、WebSocket协议设计等各种关键细节。" * 40
        history = [
            {"role": "user", "content": f"第 {i} 轮问题: {long_content}", "persona_id": "default"}
            if i % 2 == 1
            else {"role": "assistant", "content": f"第 {i} 轮回答: {long_content}", "persona_id": "default"}
            for i in range(1, 15)
        ]

        total_tokens = estimate_messages_tokens(history)
        self.assertGreater(total_tokens, HISTORY_TOKEN_THRESHOLD)

        loop = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="Lumi assistant",
            history_messages=history,
            ws_server=None,
            ws_session_id="ws-1",
            user_id=1,
            persona_id="default",
            db=None,
        )

        compacted = await loop._compact_history_if_needed(history)
        # 应包含 1 个 Summary Node + 最近 KEEP_RECENT_MESSAGES 条细粒度消息
        self.assertEqual(len(compacted), KEEP_RECENT_MESSAGES + 1)
        self.assertEqual(compacted[0]["role"], "system")
        self.assertIn("Context Summary Node", compacted[0]["content"])

    def test_persona_switching_anchors(self):
        history = [
            {"role": "user", "content": "你好", "persona_id": "firefly"},
            {"role": "assistant", "content": "开拓者，你在找我吗？", "persona_id": "firefly"},
            {"role": "user", "content": "请扮演技术专家帮我写代码", "persona_id": "senior_engineer"},
            {"role": "assistant", "content": "好的，请出示代码需求。", "persona_id": "senior_engineer"},
        ]

        loop = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="Senior Engineer System",
            history_messages=history,
            ws_server=None,
            ws_session_id="ws-1",
            user_id=1,
            persona_id="senior_engineer",
            db=None,
        )

        messages = loop._build_messages("System Prompt", "当前问题", history_messages=history)

        # 检查是否注入了 [System: User switched persona to 'senior_engineer']
        anchor_found = any(
            m["role"] == "system" and "User switched persona to 'senior_engineer'" in m["content"]
            for m in messages
        )
        self.assertTrue(anchor_found, "应该在历史中 Persona 切换处注入虚拟系统隔离锚点")


class MockClientWS:
    def __init__(self, sid):
        self.sid = sid
        self.received = []

    async def send(self, data):
        self.received.append(data)


class TestMultiDeviceBroadcast(unittest.IsolatedAsyncioTestCase):
    async def test_user_sessions_registration_and_broadcast(self):
        server = LumiWSServer()
        client1 = MockClientWS("ws-mobile")
        client2 = MockClientWS("ws-desktop")

        server.clients["ws-mobile"] = client1
        server.clients["ws-desktop"] = client2

        user_id = 1001

        # 两个终端绑定到同一个 user_id
        server.register_user("ws-mobile", user_id)
        server.register_user("ws-desktop", user_id)

        self.assertEqual(len(server._user_sessions[user_id]), 2)

        # 1. 向所有终端广播 (例如 AI 回复打字流)
        test_msg = {"type": "CHAT_STREAM_CHUNK", "payload": {"chunk": "Hello"}}
        await server.broadcast_to_user(user_id, test_msg)

        self.assertEqual(len(client1.received), 1)
        self.assertEqual(len(client2.received), 1)

        # 2. 排除发送端广播 (例如用户发消息，仅同步给其它设备以回声抑制)
        user_sync_msg = {"type": "CHAT_MESSAGE_SYNC", "payload": {"content": "User sent this"}}
        await server.broadcast_to_user(user_id, user_sync_msg, exclude_session_id="ws-mobile")

        # client1 (mobile) 应该被排除，未收到回声
        self.assertEqual(len(client1.received), 1)
        # client2 (desktop) 应该收到同步
        self.assertEqual(len(client2.received), 2)

        # 3. 解绑测试
        server.unregister_user("ws-mobile")
        self.assertEqual(len(server._user_sessions[user_id]), 1)
        server.unregister_user("ws-desktop")
        self.assertNotIn(user_id, server._user_sessions)


class TestLLMProviderAndPresets(unittest.IsolatedAsyncioTestCase):
    def test_provider_creation_compatibility(self):
        from host.llm import create_provider
        from host.llm.openai_provider import OpenAIProvider
        from host.llm.anthropic_provider import AnthropicProvider
        from host.llm.ollama_provider import OllamaProvider

        # 1. 任意国内或 OpenAI 兼容预设供应商（如 deepseek, zhipu, custom）统一由 OpenAIProvider 接管
        p_ds = create_provider(provider_type="deepseek", api_key="sk-test", base_url="https://api.deepseek.com", model="deepseek-chat")
        self.assertIsInstance(p_ds, OpenAIProvider)
        self.assertEqual(p_ds.get_default_model(), "deepseek-chat")

        p_custom = create_provider(provider_type="custom", api_key="sk-proxy", base_url="https://my-proxy.com/v1", model="gpt-4o")
        self.assertIsInstance(p_custom, OpenAIProvider)

        # 2. Anthropic
        p_ant = create_provider(provider_type="anthropic", api_key="sk-ant-test", model="claude-3-7-sonnet-20250219")
        self.assertIsInstance(p_ant, AnthropicProvider)

        # 3. Ollama
        p_ollama = create_provider(provider_type="ollama", base_url="http://localhost:11434/v1", model="qwen2.5:latest")
        self.assertIsInstance(p_ollama, OllamaProvider)

    def test_revert_file_git(self):
        from host.native_tools import write_file, revert_file
        import tempfile
        import subprocess
        with tempfile.TemporaryDirectory() as tmpdir:
            subprocess.run(["git", "init"], cwd=tmpdir, capture_output=True, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=tmpdir, capture_output=True, check=True)
            subprocess.run(["git", "config", "user.email", "test@test.com"], cwd=tmpdir, capture_output=True, check=True)
            test_file = os.path.join(tmpdir, "test.txt")
            with open(test_file, "w") as f:
                f.write("original content")
            subprocess.run(["git", "add", "test.txt"], cwd=tmpdir, capture_output=True, check=True)
            subprocess.run(["git", "commit", "-m", "init"], cwd=tmpdir, capture_output=True, check=True)

            write_file(test_file, "modified content")
            with open(test_file, "r") as f:
                self.assertEqual(f.read(), "modified content")

            ok, msg = revert_file(test_file, workspace_dir=tmpdir)
            self.assertTrue(ok)
            with open(test_file, "r") as f:
                self.assertEqual(f.read(), "original content")

    def test_message_extra_and_trace_persistence(self):
        import tempfile
        from host.database.manager import DatabaseManager
        with tempfile.TemporaryDirectory() as tmpdir:
            db = DatabaseManager(tmpdir)
            user = db.create_user("testuser", "testpass")
            user_id = user["id"]
            trace_data = {
                "traces": [
                    {
                        "step_id": 1,
                        "tool_name": "run_command",
                        "tool_args": {"CommandLine": "git status"},
                        "duration_ms": 120,
                        "status": "success",
                        "output_summary": "On branch main",
                    }
                ],
                "trace_summary": {"step_count": 1, "total_tool_duration_ms": 120},
                "files_changed": [{"path": "/workspace/main.dart", "additions": 5, "deletions": 2}],
            }
            # 保存带有 trace 的消息
            saved = db.save_message(
                user_id=user_id,
                role="assistant",
                content="这是分析结果",
                client_msg_id="turn1_ai",
                extra=trace_data,
            )
            self.assertIsNotNone(saved.get("extra"))
            self.assertEqual(len(saved["extra"]["traces"]), 1)
            self.assertEqual(saved["extra"]["traces"][0]["tool_name"], "run_command")

            # 读取历史消息，验证 extra 完整还原
            history = db.get_messages(user_id=user_id)
            self.assertEqual(len(history), 1)
            msg = history[0]
            self.assertIsNotNone(msg.get("extra"))
            self.assertEqual(msg["extra"]["traces"][0]["tool_name"], "run_command")
            self.assertEqual(msg["extra"]["files_changed"][0]["path"], "/workspace/main.dart")


class TestRepeatToolWatchdog(unittest.IsolatedAsyncioTestCase):
    """验证工具重复调用看门狗 (Repeat Tool Reminder) 各项契约。"""

    def test_threshold_escalation(self):
        dog = RepeatToolWatchdog()
        args = {"path": "test.txt", "mode": "r"}

        # 1-2 次调用：无报警
        self.assertIsNone(dog.record_call("read_file", args))
        self.assertEqual(dog.repeat_count, 1)
        self.assertIsNone(dog.record_call("read_file", args))
        self.assertEqual(dog.repeat_count, 2)

        # 第 3 次调用：触发第 1 档温和提示 (GENTLE_REMINDER)
        r3 = dog.record_call("read_file", args)
        self.assertEqual(dog.repeat_count, 3)
        self.assertEqual(r3, GENTLE_REMINDER)
        self.assertIn("repeating the exact same tool call", r3)

        # 第 4 次调用：非阈值点，静默
        self.assertIsNone(dog.record_call("read_file", args))
        self.assertEqual(dog.repeat_count, 4)

        # 第 5 次调用：触发第 2 档严厉告警
        r5 = dog.record_call("read_file", args)
        self.assertEqual(dog.repeat_count, 5)
        self.assertIn("Repeated tool call detected:", r5)
        self.assertIn("- tool: read_file", r5)
        self.assertIn("- consecutive_calls: 5", r5)
        self.assertIn('{"mode":"r","path":"test.txt"}', r5)

        # 第 6-7 次调用：非阈值点
        self.assertIsNone(dog.record_call("read_file", args))
        self.assertIsNone(dog.record_call("read_file", args))

        # 第 8 次调用：触发第 3 档告警
        r8 = dog.record_call("read_file", args)
        self.assertEqual(dog.repeat_count, 8)
        self.assertIn("- consecutive_calls: 8", r8)

    def test_canonicalization_deep(self):
        """测试无论嵌套字典键顺序如何变化，均能识别为同一调用。"""
        dog = RepeatToolWatchdog()
        d1 = {"b": 2, "a": 1, "nested": {"y": [1, 2], "x": "ok"}}
        d2 = {"nested": {"x": "ok", "y": [1, 2]}, "a": 1, "b": 2}
        d3 = {"a": 1, "nested": {"y": [1, 2], "x": "ok"}, "b": 2}

        self.assertIsNone(dog.record_call("probe", d1))
        self.assertIsNone(dog.record_call("probe", d2))
        r3 = dog.record_call("probe", d3)
        self.assertEqual(dog.repeat_count, 3)
        self.assertEqual(r3, GENTLE_REMINDER)

    def test_resets_on_arg_change_and_tool_change(self):
        dog = RepeatToolWatchdog()
        self.assertIsNone(dog.record_call("read_file", {"path": "a.txt"}))
        self.assertIsNone(dog.record_call("read_file", {"path": "a.txt"}))
        self.assertEqual(dog.repeat_count, 2)

        # 参数变更，重置计数链
        self.assertIsNone(dog.record_call("read_file", {"path": "b.txt"}))
        self.assertEqual(dog.repeat_count, 1)

        self.assertIsNone(dog.record_call("read_file", {"path": "b.txt"}))
        r3 = dog.record_call("read_file", {"path": "b.txt"})
        self.assertEqual(dog.repeat_count, 3)
        self.assertEqual(r3, GENTLE_REMINDER)

        # 更换不同工具，重置计数链
        self.assertIsNone(dog.record_call("grep_code", {"pattern": "abc"}))
        self.assertEqual(dog.repeat_count, 1)

    def test_reset_method(self):
        dog = RepeatToolWatchdog()
        dog.record_call("probe", {})
        dog.record_call("probe", {})
        self.assertEqual(dog.repeat_count, 2)

        dog.reset()
        self.assertEqual(dog.repeat_count, 0)
        dog.record_call("probe", {})
        self.assertEqual(dog.repeat_count, 1)

    def test_arguments_preview_truncation(self):
        dog = RepeatToolWatchdog(thresholds=[2, 3], arguments_preview_chars=20)
        long_arg = {"content": "X" * 150}

        dog.record_call("write", long_arg)
        r2 = dog.record_call("write", long_arg)
        self.assertEqual(r2, GENTLE_REMINDER)

        r3 = dog.record_call("write", long_arg)
        self.assertIn("consecutive_calls: 3", r3)
        self.assertIn("… (+", r3)
        self.assertNotIn("X" * 150, r3)

    def test_exclude_and_include(self):
        # 排除工具对连续链保持透明：既不计入，也不打断已有链条
        dog = RepeatToolWatchdog(exclude=["ping*"])
        self.assertIsNone(dog.record_call("probe", {"id": 1}))
        self.assertIsNone(dog.record_call("ping_server", {"host": "127.0.0.1"}))  # 透明
        self.assertIsNone(dog.record_call("probe", {"id": 1}))
        self.assertIsNone(dog.record_call("ping_server", {}))  # 透明
        r3 = dog.record_call("probe", {"id": 1})
        self.assertEqual(dog.repeat_count, 3)
        self.assertEqual(r3, GENTLE_REMINDER)

        # include 白名单测试
        dog_inc = RepeatToolWatchdog(include=["pro*"])
        for _ in range(5):
            self.assertIsNone(dog_inc.record_call("other", {}))
        self.assertEqual(dog_inc.repeat_count, 0)

    def test_validation_errors(self):
        with self.assertRaises(ValueError):
            RepeatToolWatchdog(thresholds=[])
        with self.assertRaises(ValueError):
            RepeatToolWatchdog(thresholds=[1, 3])
        with self.assertRaises(ValueError):
            RepeatToolWatchdog(thresholds=[3, 3])
        with self.assertRaises(ValueError):
            RepeatToolWatchdog(arguments_preview_chars=0)

    async def test_agent_loop_watchdog_integration(self):
        """端到端验证：AgentLoop 在遭遇模型连续 3 次调用同一工具时，自动注入看门狗警告。"""
        class RepeatToolMockLLM:
            def __init__(self):
                self.turn = 0
                self.last_messages = []

            async def chat_stream(self, messages, tools=None):
                self.turn += 1
                self.last_messages = list(messages)
                if self.turn <= 3:
                    yield {
                        "type": "tool_calls",
                        "calls": [
                            {
                                "id": f"tc_{self.turn}",
                                "name": "dummy_tool",
                                "arguments": {"cmd": "check_status"},
                            }
                        ],
                    }
                else:
                    yield {"type": "text", "content": "任务已终止"}

        class RepeatMockTools:
            async def get_all_schemas_with_mcp(self):
                return [{"type": "function", "function": {"name": "dummy_tool", "parameters": {}}}]

            async def execute(self, name, arguments, **kwargs):
                return "status: pending"

        mock_llm = RepeatToolMockLLM()
        mock_tools = RepeatMockTools()

        loop = AgentLoop(
            llm_provider=mock_llm,
            tool_registry=mock_tools,
            persona_system_prompt="You are Lumi.",
            history_messages=[],
            ws_server=None,
            ws_session_id="ws-1",
            user_id=1,
            persona_id="default",
            db=None,
        )

        # Mock 发送事件，避免 None ws_server 报错
        async def dummy_send_event(msg):
            pass
        loop._send_event = dummy_send_event

        await loop.run("请执行监控")

        self.assertEqual(mock_llm.turn, 4)
        self.assertEqual(loop.watchdog.repeat_count, 3)

        # 检查第 4 轮请求中传入的工具消息：前 2 轮正常，第 3 轮带看门狗提醒
        tool_results = [m for m in mock_llm.last_messages if m.get("role") == "tool"]
        self.assertEqual(len(tool_results), 3)
        self.assertNotIn("[Repeat Tool Call Reminder]", tool_results[0]["content"])
        self.assertNotIn("[Repeat Tool Call Reminder]", tool_results[1]["content"])
        self.assertIn("[Repeat Tool Call Reminder]", tool_results[2]["content"])
        self.assertIn("repeating the exact same tool call", tool_results[2]["content"])


class TestUserQuestionTool(unittest.IsolatedAsyncioTestCase):
    """测试交互式问答卡片 (ask_user_question) 挂起与应答流程。"""

    async def test_tool_registry_ask_user_question_callback(self):
        from host.tool_registry import ToolRegistry
        registry = ToolRegistry()

        questions = [
            {
                "id": "q1",
                "question": "网络拓扑？",
                "options": ["(Recommended) 局域网", "公网"],
                "is_multi_select": False,
            }
        ]

        async def mock_callback(qs):
            return json.dumps({"answers": [{"id": qs[0]["id"], "selected": ["(Recommended) 局域网"]}]})

        res = await registry.execute(
            name="ask_user_question",
            arguments={"questions": questions},
            user_question_callback=mock_callback,
        )
        data = json.loads(res)
        self.assertIn("answers", data)
        self.assertEqual(data["answers"][0]["selected"], ["(Recommended) 局域网"])

    async def test_agent_loop_wait_for_user_question_success(self):
        class MockWSServer:
            def __init__(self):
                self.sent_messages = []

            async def wait_for_response(self, session_id, message_id, timeout=180):
                return {
                    "message_id": message_id,
                    "payload": {
                        "answers": [{"id": "q1", "selected": ["局域网直连"]}],
                    },
                }

        ws_mock = MockWSServer()
        loop = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="You are Lumi.",
            history_messages=[],
            ws_server=ws_mock,
            ws_session_id="ws-test",
            user_id=1,
            persona_id="default",
            db=None,
        )
        sent = []
        async def dummy_send_event(msg):
            sent.append(msg)
        loop._send_event = dummy_send_event

        res = await loop.wait_for_user_question(
            questions=[{"id": "q1", "question": "请选择网络", "options": ["局域网直连"]}]
        )
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["type"], "ASK_USER_QUESTION")
        data = json.loads(res)
        self.assertEqual(data["answers"][0]["selected"], ["局域网直连"])

    async def test_agent_loop_wait_for_user_question_timeout(self):
        class MockWSServerTimeout:
            async def wait_for_response(self, session_id, message_id, timeout=180):
                return None

        loop = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="You are Lumi.",
            history_messages=[],
            ws_server=MockWSServerTimeout(),
            ws_session_id="ws-test",
            user_id=1,
            persona_id="default",
            db=None,
        )
        loop._send_event = lambda msg: asyncio.sleep(0)

        res = await loop.wait_for_user_question(
            questions=[{"id": "q1", "question": "请选择网络", "options": ["局域网直连"]}],
            timeout=1,
        )
        data = json.loads(res)
        self.assertEqual(data.get("status"), "timeout")


class TestUserApprovalAndRiskTiering(unittest.IsolatedAsyncioTestCase):
    """测试人机审批 (User-Approval) 与风险分级机制。"""

    async def test_approval_policy_yolo_and_never(self):
        # 1. yolo / auto 策略：自动放行
        loop_yolo = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="You are Lumi.",
            history_messages=[],
            ws_server=None,
            ws_session_id="ws-1",
            user_id=1,
            persona_id="default",
            db=None,
            approval_policy="yolo",
        )
        approved = await loop_yolo.wait_for_auth("COMMAND_RUN", "rm -rf /test", "删除测试")
        self.assertTrue(approved)

        # 2. never 策略：自动拒绝
        loop_never = AgentLoop(
            llm_provider=MockLLMProvider(),
            tool_registry=MockToolRegistry(),
            persona_system_prompt="You are Lumi.",
            history_messages=[],
            ws_server=None,
            ws_session_id="ws-1",
            user_id=1,
            persona_id="default",
            db=None,
            approval_policy="never",
        )
        approved = await loop_never.wait_for_auth("COMMAND_RUN", "rm -rf /test", "删除测试")
        self.assertFalse(approved)

    async def test_tool_registry_rejection_feedback(self):
        from host.tool_registry import ToolRegistry
        registry = ToolRegistry()

        @registry.register(
            name="dangerous_command",
            description="高危测试命令",
            parameters={"cmd": {"type": "string"}},
            requires_auth=True,
            auth_action_type="COMMAND_RUN",
        )
        def dangerous_command(cmd: str):
            return "executed"

        async def reject_auth(**kwargs):
            return False

        res = await registry.execute(
            name="dangerous_command",
            arguments={"cmd": "rm -rf /"},
            auth_callback=reject_auth,
        )
        self.assertIn("Error: User rejected the execution of dangerous_command", res)
        self.assertIn("rm -rf /", res)
        self.assertIn("The operation was blocked", res)


if __name__ == "__main__":
    unittest.main()

