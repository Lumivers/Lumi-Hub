"""
Lumi-Hub 2.0 — 记忆管理器
自动从对话中提取关键信息，供后续对话检索使用。
"""
import json
import logging
import re
from typing import Optional

logger = logging.getLogger("lumi")

# 记忆类别
MEMORY_CATEGORIES = ("preference", "fact", "correction", "summary")


class MemoryManager:
    """记忆管理器。

    功能：
    1. 对话结束后异步提取关键信息（偏好、事实、纠错）
    2. 根据当前消息检索相关记忆
    3. 注入到 Agent system prompt
    """

    def __init__(self, db, llm_provider):
        self.db = db
        self.llm = llm_provider

    async def extract_memories(
        self, user_id: int, persona_id: str, conversation: list[dict]
    ):
        """对话结束后，异步提取关键信息。

        用一个轻量 LLM 调用做信息提取。
        """
        if not conversation:
            return

        # 构建提取 prompt
        conv_text = "\n".join(
            f"[{msg['role']}]: {msg['content']}" for msg in conversation
        )

        extract_prompt = [
            {
                "role": "system",
                "content": (
                    "你是一个信息提取助手。从以下对话中提取用户的偏好、重要事实、纠错信息。\n"
                    "输出 JSON 数组，每个元素格式：\n"
                    '{"category": "preference|fact|correction", "content": "记忆内容"}\n'
                    "只提取有价值的信息，不要提取普通对话内容。\n"
                    "如果没有值得记忆的信息，返回空数组 []。"
                ),
            },
            {"role": "user", "content": conv_text},
        ]

        try:
            result_text = ""
            async for event in self.llm.chat_stream(
                messages=extract_prompt,
                tools=None,
                max_tokens=512,
            ):
                if event["type"] == "text":
                    result_text += event["content"]

            # 解析 JSON 结果
            memories = self._parse_memories(result_text)
            for mem in memories:
                if mem.get("category") in MEMORY_CATEGORIES and mem.get("content"):
                    self._save_memory(user_id, persona_id, mem["category"], mem["content"])

            if memories:
                logger.info(f"[MemoryManager] 为用户 {user_id} 提取了 {len(memories)} 条记忆")

        except Exception as e:
            logger.warning(f"[MemoryManager] 记忆提取失败: {e}")

    def _parse_memories(self, text: str) -> list[dict]:
        """从 LLM 输出中解析记忆 JSON。"""
        # 尝试提取 JSON 数组
        try:
            # 找到 JSON 数组
            match = re.search(r'\[.*\]', text, re.DOTALL)
            if match:
                return json.loads(match.group())
        except json.JSONDecodeError:
            pass
        return []

    def _save_memory(self, user_id: int, persona_id: str, category: str, content: str):
        """保存记忆到数据库。"""
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory

                # 检查是否已存在相同记忆
                existing = session.query(Memory).filter(
                    Memory.user_id == user_id,
                    Memory.persona_id == persona_id,
                    Memory.content == content,
                ).first()

                if existing:
                    # 更新访问时间
                    import datetime
                    existing.last_accessed = datetime.datetime.now(datetime.timezone.utc)
                    existing.access_count += 1
                    session.commit()
                else:
                    mem = Memory(
                        user_id=user_id,
                        persona_id=persona_id,
                        category=category,
                        content=content,
                    )
                    session.add(mem)
                    session.commit()
        except Exception as e:
            logger.warning(f"[MemoryManager] 保存记忆失败: {e}")

    async def retrieve_relevant(
        self, user_id: int, persona_id: str, query: str, top_k: int = 5
    ) -> list[dict]:
        """根据当前用户消息检索相关记忆。

        简单策略：关键词匹配 + 最近使用优先。
        """
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory

                # 查询该用户的所有记忆
                memories = session.query(Memory).filter(
                    Memory.user_id == user_id,
                    Memory.persona_id == persona_id,
                ).order_by(
                    Memory.last_accessed.desc()
                ).limit(50).all()

                if not memories:
                    return []

                # 简单关键词匹配
                scored = []
                query_lower = query.lower()
                for mem in memories:
                    score = 0
                    content_lower = mem.content.lower()
                    # 简单的关键词重叠评分
                    query_words = set(query_lower.split())
                    content_words = set(content_lower.split())
                    overlap = query_words & content_words
                    if overlap:
                        score = len(overlap) / max(len(query_words), 1)

                    # 最近使用的加分
                    if score > 0:
                        scored.append((score, mem))

                # 按分数排序，取 top_k
                scored.sort(key=lambda x: x[0], reverse=True)
                return [
                    {
                        "category": mem.category,
                        "content": mem.content,
                    }
                    for _, mem in scored[:top_k]
                ]
        except Exception as e:
            logger.warning(f"[MemoryManager] 检索记忆失败: {e}")
            return []

    def add_memory(self, user_id: int, persona_id: str, category: str, content: str):
        """手动添加记忆。"""
        self._save_memory(user_id, persona_id, category, content)

    def forget_memory(self, memory_id: int, user_id: int):
        """删除记忆。"""
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory
                mem = session.query(Memory).filter(
                    Memory.id == memory_id,
                    Memory.user_id == user_id,
                ).first()
                if mem:
                    session.delete(mem)
                    session.commit()
                    logger.info(f"[MemoryManager] 已删除记忆 {memory_id}")
        except Exception as e:
            logger.warning(f"[MemoryManager] 删除记忆失败: {e}")

    def list_memories(self, user_id: int, persona_id: str, category: Optional[str] = None) -> list[dict]:
        """列出指定用户与人格的所有记忆。"""
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory
                query = session.query(Memory).filter(
                    Memory.user_id == user_id,
                    Memory.persona_id == persona_id,
                )
                if category:
                    query = query.filter(Memory.category == category)

                memories = query.order_by(Memory.created_at.desc()).all()
                return [
                    {
                        "id": m.id,
                        "category": m.category,
                        "content": m.content,
                        "created_at": m.created_at.isoformat() if m.created_at else "",
                        "last_accessed": m.last_accessed.isoformat() if m.last_accessed else "",
                        "access_count": m.access_count or 0,
                    }
                    for m in memories
                ]
        except Exception as e:
            logger.warning(f"[MemoryManager] 查询记忆列表失败: {e}")
            return []

    def clear_memories(self, user_id: int, persona_id: str) -> int:
        """清空指定用户与人格的所有记忆。"""
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory
                query = session.query(Memory).filter(
                    Memory.user_id == user_id,
                    Memory.persona_id == persona_id,
                )
                count = query.count()
                query.delete()
                session.commit()
                logger.info(f"[MemoryManager] 已清空用户 {user_id} 在人格 {persona_id} 下的 {count} 条记忆")
                return count
        except Exception as e:
            logger.warning(f"[MemoryManager] 清空记忆失败: {e}")
            return 0

