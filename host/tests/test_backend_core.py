import asyncio
import os
import sys
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
)
from host.ws_server import LumiWSServer


class MockLLMProvider:
    async def chat_stream(self, messages, tools=None):
        yield {"type": "text", "content": "- 讨论了 Lumi-Hub 架构\n- 决定实现多端同步与 RAG 检索"}


class MockToolRegistry:
    async def get_all_schemas_with_mcp(self):
        return []

    async def execute(self, name, arguments, auth_callback=None):
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


if __name__ == "__main__":
    unittest.main()

