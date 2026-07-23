"""
Lumi-Hub 2.0 — 备份管理器
支持聊天记录、记忆、人格配置的导出和导入。
"""
import json
import os
import zipfile
import logging
from datetime import datetime

logger = logging.getLogger("lumi")


class BackupManager:
    """备份管理器。

    导出内容：
    - chat_history.json — 所有聊天记录
    - memories.json — 记忆数据
    - personas/ — 人格配置
    - settings.json — 应用设置
    - mcp_config.json — MCP 服务器配置
    - manifest.json — 导出元数据
    """

    def __init__(self, db, data_dir: str):
        self.db = db
        self.data_dir = data_dir

    async def export_all(self, output_path: str) -> dict:
        """导出全部数据到 zip 文件。"""
        manifest = {
            "version": "2.0",
            "exported_at": datetime.now().isoformat(),
            "entries": {},
        }

        try:
            with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
                # 1. 导出聊天记录
                chat_history = self._export_chat_history()
                zf.writestr("chat_history.json", json.dumps(chat_history, ensure_ascii=False, indent=2))
                manifest["entries"]["chat_history"] = len(chat_history)

                # 2. 导出记忆
                memories = self._export_memories()
                zf.writestr("memories.json", json.dumps(memories, ensure_ascii=False, indent=2))
                manifest["entries"]["memories"] = len(memories)

                # 3. 导出人格配置
                personas_dir = os.path.join(self.data_dir, "personas")
                if os.path.exists(personas_dir):
                    persona_count = 0
                    for filename in os.listdir(personas_dir):
                        if filename.endswith(".json"):
                            filepath = os.path.join(personas_dir, filename)
                            zf.write(filepath, f"personas/{filename}")
                            persona_count += 1
                    manifest["entries"]["personas"] = persona_count

                # 4. 导出 MCP 配置
                mcp_config_path = os.path.join(self.data_dir, "mcp_config.json")
                if os.path.exists(mcp_config_path):
                    zf.write(mcp_config_path, "mcp_config.json")
                    manifest["entries"]["mcp_config"] = True

                # 5. 导出语音配置
                voice_config_path = os.path.join(self.data_dir, "voice_config.json")
                if os.path.exists(voice_config_path):
                    zf.write(voice_config_path, "voice_config.json")
                    manifest["entries"]["voice_config"] = True

                # 6. 写入 manifest
                zf.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))

            logger.info(f"[BackupManager] 导出完成: {output_path}")
            return {"success": True, "path": output_path, "manifest": manifest}

        except Exception as e:
            logger.error(f"[BackupManager] 导出失败: {e}")
            return {"success": False, "error": str(e)}

    async def import_all(self, zip_path: str, merge: bool = True) -> dict:
        """从 zip 文件导入数据。

        Args:
            zip_path: zip 文件路径
            merge: True=合并（不覆盖），False=全量替换
        """
        try:
            with zipfile.ZipFile(zip_path, "r") as zf:
                # 读取 manifest
                manifest = {}
                if "manifest.json" in zf.namelist():
                    manifest = json.loads(zf.read("manifest.json"))

                imported = {}

                # 1. 导入聊天记录
                if "chat_history.json" in zf.namelist():
                    history = json.loads(zf.read("chat_history.json"))
                    count = self._import_chat_history(history, merge)
                    imported["chat_history"] = count

                # 2. 导入记忆
                if "memories.json" in zf.namelist():
                    memories = json.loads(zf.read("memories.json"))
                    count = self._import_memories(memories, merge)
                    imported["memories"] = count

                # 3. 导入人格配置
                personas_dir = os.path.join(self.data_dir, "personas")
                os.makedirs(personas_dir, exist_ok=True)
                persona_count = 0
                for name in zf.namelist():
                    if name.startswith("personas/") and name.endswith(".json"):
                        content = zf.read(name)
                        filename = os.path.basename(name)
                        target = os.path.join(personas_dir, filename)
                        if merge and os.path.exists(target):
                            continue  # 合并模式不覆盖
                        with open(target, "wb") as f:
                            f.write(content)
                        persona_count += 1
                imported["personas"] = persona_count

                # 4. 导入 MCP 配置
                if "mcp_config.json" in zf.namelist():
                    content = zf.read("mcp_config.json")
                    target = os.path.join(self.data_dir, "mcp_config.json")
                    if not merge or not os.path.exists(target):
                        with open(target, "wb") as f:
                            f.write(content)
                        imported["mcp_config"] = True

                # 5. 导入语音配置
                if "voice_config.json" in zf.namelist():
                    content = zf.read("voice_config.json")
                    target = os.path.join(self.data_dir, "voice_config.json")
                    if not merge or not os.path.exists(target):
                        with open(target, "wb") as f:
                            f.write(content)
                        imported["voice_config"] = True

            logger.info(f"[BackupManager] 导入完成: {imported}")
            return {"success": True, "imported": imported, "manifest": manifest}

        except Exception as e:
            logger.error(f"[BackupManager] 导入失败: {e}")
            return {"success": False, "error": str(e)}

    def _export_chat_history(self) -> list:
        """导出所有聊天记录。"""
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Message
                messages = session.query(Message).order_by(Message.timestamp.asc()).all()
                return [
                    {
                        "user_id": msg.user_id,
                        "persona_id": msg.persona_id,
                        "role": msg.role,
                        "content": msg.content,
                        "type": msg.type,
                        "client_msg_id": msg.client_msg_id,
                        "timestamp": msg.timestamp.isoformat() if msg.timestamp else None,
                    }
                    for msg in messages
                ]
        except Exception as e:
            logger.warning(f"[BackupManager] 导出聊天记录失败: {e}")
            return []

    def _import_chat_history(self, history: list, merge: bool) -> int:
        """导入聊天记录。"""
        count = 0
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Message
                import datetime

                if not merge:
                    session.query(Message).delete()
                    session.commit()

                for item in history:
                    # 检查是否已存在
                    if merge and item.get("client_msg_id"):
                        existing = session.query(Message).filter(
                            Message.client_msg_id == item["client_msg_id"]
                        ).first()
                        if existing:
                            continue

                    msg = Message(
                        user_id=item.get("user_id", 0),
                        persona_id=item.get("persona_id", "default"),
                        role=item.get("role", "user"),
                        content=item.get("content", ""),
                        type=item.get("type", "chat"),
                        client_msg_id=item.get("client_msg_id"),
                    )
                    session.add(msg)
                    count += 1

                session.commit()
        except Exception as e:
            logger.warning(f"[BackupManager] 导入聊天记录失败: {e}")
        return count

    def _export_memories(self) -> list:
        """导出所有记忆。"""
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory
                memories = session.query(Memory).all()
                return [
                    {
                        "user_id": mem.user_id,
                        "persona_id": mem.persona_id,
                        "category": mem.category,
                        "content": mem.content,
                        "created_at": mem.created_at.isoformat() if mem.created_at else None,
                    }
                    for mem in memories
                ]
        except Exception as e:
            logger.warning(f"[BackupManager] 导出记忆失败: {e}")
            return []

    def _import_memories(self, memories: list, merge: bool) -> int:
        """导入记忆。"""
        count = 0
        try:
            with self.db.SessionLocal() as session:
                from .database.models import Memory

                if not merge:
                    session.query(Memory).delete()
                    session.commit()

                for item in memories:
                    if merge:
                        existing = session.query(Memory).filter(
                            Memory.user_id == item.get("user_id"),
                            Memory.persona_id == item.get("persona_id", "default"),
                            Memory.content == item.get("content"),
                        ).first()
                        if existing:
                            continue

                    mem = Memory(
                        user_id=item.get("user_id", 0),
                        persona_id=item.get("persona_id", "default"),
                        category=item.get("category", "fact"),
                        content=item.get("content", ""),
                    )
                    session.add(mem)
                    count += 1

                session.commit()
        except Exception as e:
            logger.warning(f"[BackupManager] 导入记忆失败: {e}")
        return count
