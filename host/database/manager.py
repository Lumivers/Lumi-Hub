import os
import secrets
import hashlib
import datetime
from datetime import timezone
from sqlalchemy import or_
from sqlalchemy.orm import sessionmaker

import logging
logger = logging.getLogger("lumi")
from .models import init_db, User, Message, Attachment, Session

class DatabaseManager:
    """管理 Lumi-Hub 的本地 SQLite 数据库操作"""
    
    def __init__(self, data_dir: str):
        self.db_path = os.path.join(data_dir, "lumi_hub.db")
        os.makedirs(data_dir, exist_ok=True)
        self.SessionLocal = init_db(self.db_path)
        logger.info(f"[Lumi-Hub DB] 数据库初始化完成: {self.db_path}")

    # ===== 用户相关 =====

    def verify_password(self, plain_password, hashed_password):
        # 当前使用 sha256 单向散列校验。
        return self.get_password_hash(plain_password) == hashed_password

    def get_password_hash(self, password):
        # 简单好用的内置 sha256 即可，无需引入容易出依赖问题的 passlib/bcrypt
        return hashlib.sha256(password.encode('utf-8')).hexdigest()

    def get_or_create_default_user(self, default_username: str = "开拓者") -> dict:
        """获取或创建默认本地用户（支持单机免密启动）。"""
        with self.SessionLocal() as session:
            user = session.query(User).order_by(User.id.asc()).first()
            if not user:
                new_token = secrets.token_hex(32)
                hashed_pwd = self.get_password_hash("")
                user = User(username=default_username, password_hash=hashed_pwd, token=new_token)
                session.add(user)
                session.commit()
                session.refresh(user)
            elif not user.token:
                user.token = secrets.token_hex(32)
                session.commit()
                session.refresh(user)
            return {
                "id": user.id,
                "username": user.username,
                "token": user.token,
                "created_at": user.created_at.isoformat()
            }

    def create_user(self, username: str, password: str = "") -> dict:
        """注册或更新本地用户昵称/密码（免密/平滑兼容）。"""
        username = (username or "").strip() or "开拓者"
        with self.SessionLocal() as session:
            # 检查是否已存在同名用户
            existing = session.query(User).filter(User.username == username).first()
            if existing:
                if password:
                    existing.password_hash = self.get_password_hash(password)
                if not existing.token:
                    existing.token = secrets.token_hex(32)
                session.commit()
                session.refresh(existing)
                return {
                    "id": existing.id,
                    "username": existing.username,
                    "token": existing.token,
                    "created_at": existing.created_at.isoformat()
                }

            # 如果库里有第一个默认用户，直接平滑更新其昵称，避免多用户碎片
            first_user = session.query(User).order_by(User.id.asc()).first()
            if first_user and first_user.username in ("开拓者", "Admin", "default", "User"):
                first_user.username = username
                if password:
                    first_user.password_hash = self.get_password_hash(password)
                if not first_user.token:
                    first_user.token = secrets.token_hex(32)
                session.commit()
                session.refresh(first_user)
                return {
                    "id": first_user.id,
                    "username": first_user.username,
                    "token": first_user.token,
                    "created_at": first_user.created_at.isoformat()
                }

            # 否则创建新用户
            hashed_pwd = self.get_password_hash(password or "")
            new_token = secrets.token_hex(32)
            new_user = User(username=username, password_hash=hashed_pwd, token=new_token)
            session.add(new_user)
            session.commit()
            session.refresh(new_user)

            return {
                "id": new_user.id,
                "username": new_user.username,
                "token": new_user.token,
                "created_at": new_user.created_at.isoformat()
            }

    def verify_user(self, username: str, password: str = "") -> dict:
        """验证用户登录。成功返回用户信息（含新 token），失败返回 error。"""
        with self.SessionLocal() as session:
            user = session.query(User).filter(User.username == username).first()
            if not user:
                # 容错：若未设置密码或指定用户不存在，平滑降级到首个用户或创建默认用户
                if not password:
                    return self.get_or_create_default_user(username)
                return {"error": "Invalid username or password"}

            # 若明确传了密码且数据库有密码哈希，则校验密码
            if password and user.password_hash:
                if not self.verify_password(password, user.password_hash):
                    return {"error": "Invalid username or password"}

            # 每次登录刷新 token
            user.token = secrets.token_hex(32)
            session.commit()
            session.refresh(user)

            return {
                "id": user.id,
                "username": user.username,
                "token": user.token,
                "created_at": user.created_at.isoformat()
            }

    def get_user_by_token(self, token: str):
        """通过 token 查找用户（用于 AUTH_RESTORE）。"""
        with self.SessionLocal() as session:
            user = session.query(User).filter(User.token == token).first()
            if user:
                return {"id": user.id, "username": user.username, "token": user.token}
            return None

    # ===== 会话 (Session) 相关 =====

    def create_session(
        self,
        user_id: int,
        workspace_path: str = "",
        title: str = "新对话",
        persona_id: str = "default",
        session_id: str = None,
    ) -> dict:
        """创建一个新会话并关联工作区路径"""
        sid = session_id or f"sess_{secrets.token_hex(8)}"
        with self.SessionLocal() as session:
            sess = Session(
                id=sid,
                user_id=user_id,
                workspace_path=workspace_path or "",
                title=title or "新对话",
                persona_id=persona_id or "default",
            )
            session.add(sess)
            session.commit()
            session.refresh(sess)
            return {
                "id": sess.id,
                "workspace_path": sess.workspace_path,
                "title": sess.title,
                "persona_id": sess.persona_id,
                "created_at": int(sess.created_at.replace(tzinfo=timezone.utc).timestamp() * 1000),
                "updated_at": int(sess.updated_at.replace(tzinfo=timezone.utc).timestamp() * 1000),
            }

    def get_or_create_session(
        self,
        user_id: int,
        session_id: str = None,
        workspace_path: str = "",
        title: str = "新对话",
        persona_id: str = "default",
    ) -> dict:
        """获取或创建会话"""
        with self.SessionLocal() as session:
            if session_id:
                sess = session.query(Session).filter(Session.id == session_id, Session.user_id == user_id).first()
                if sess:
                    return {
                        "id": sess.id,
                        "workspace_path": sess.workspace_path,
                        "title": sess.title,
                        "persona_id": sess.persona_id,
                        "created_at": int(sess.created_at.replace(tzinfo=timezone.utc).timestamp() * 1000),
                        "updated_at": int(sess.updated_at.replace(tzinfo=timezone.utc).timestamp() * 1000),
                    }
        return self.create_session(user_id, workspace_path, title, persona_id, session_id)

    def list_sessions(self, user_id: int, workspace_path: str = None) -> list[dict]:
        """列出用户的会话列表，按更新时间倒序排序"""
        with self.SessionLocal() as session:
            query = session.query(Session).filter(Session.user_id == user_id)
            if workspace_path is not None and workspace_path != "":
                query = query.filter(Session.workspace_path == workspace_path)
            sessions = query.order_by(Session.updated_at.desc()).all()
            return [
                {
                    "id": s.id,
                    "workspace_path": s.workspace_path,
                    "title": s.title,
                    "persona_id": s.persona_id,
                    "created_at": int(s.created_at.replace(tzinfo=timezone.utc).timestamp() * 1000),
                    "updated_at": int(s.updated_at.replace(tzinfo=timezone.utc).timestamp() * 1000),
                }
                for s in sessions
            ]

    def update_session(
        self,
        session_id: str,
        title: str = None,
        persona_id: str = None,
        workspace_path: str = None,
    ) -> bool:
        """更新会话元数据"""
        with self.SessionLocal() as session:
            sess = session.query(Session).filter(Session.id == session_id).first()
            if not sess:
                return False
            if title is not None:
                sess.title = title
            if persona_id is not None:
                sess.persona_id = persona_id
            if workspace_path is not None:
                sess.workspace_path = workspace_path
            sess.updated_at = datetime.datetime.now(timezone.utc)
            session.commit()
            return True

    def delete_session(self, user_id: int, session_id: str) -> bool:
        """删除会话及其关联的所有消息"""
        with self.SessionLocal() as session:
            sess = session.query(Session).filter(Session.id == session_id, Session.user_id == user_id).first()
            if not sess:
                return False
            session.query(Message).filter(Message.session_id == session_id).delete(synchronize_session=False)
            session.delete(sess)
            session.commit()
            logger.info(f"[Lumi-Hub DB] 用户 {user_id} 删除了会话 {session_id}")
            return True

    # ===== 消息相关 =====

    def _merge_text_with_overlap(self, existing: str, incoming: str) -> str:
        """合并分段文本，避免重叠部分重复拼接。"""
        existing = existing or ""
        incoming = incoming or ""
        if not incoming:
            return existing
        if not existing:
            return incoming
        if existing.endswith(incoming):
            return existing

        max_overlap = min(len(existing), len(incoming))
        for overlap in range(max_overlap, 0, -1):
            if existing.endswith(incoming[:overlap]):
                return existing + incoming[overlap:]
        return existing + incoming

    def save_message(
        self,
        user_id: int,
        role: str,
        content: str,
        msg_type: str = 'chat',
        client_msg_id: str = None,
        persona_id: str = 'default',
        session_id: str = None,
    ) -> dict:
        """保存单条消息记录，并同步更新所属会话的时间与自动标题"""
        with self.SessionLocal() as session:
            if client_msg_id:
                # 幂等写入：相同 client_msg_id 走更新路径。
                existing = session.query(Message).filter(Message.client_msg_id == client_msg_id).first()
                if existing:
                    existing.user_id = user_id
                    existing.persona_id = persona_id
                    if session_id:
                        existing.session_id = session_id
                    existing.role = role
                    # assistant 分段回复使用同一个 client_msg_id，需累积而非覆盖。
                    if role == 'assistant' and existing.role == 'assistant':
                        existing.content = self._merge_text_with_overlap(existing.content, content)
                    else:
                        existing.content = content
                    existing.type = msg_type
                    existing.timestamp = datetime.datetime.now(timezone.utc)
                    session.commit()
                    session.refresh(existing)
                    return {
                        "id": existing.id,
                        "role": existing.role,
                        "content": existing.content,
                        "type": existing.type,
                        "session_id": existing.session_id,
                        "persona_id": existing.persona_id,
                        "timestamp": int(existing.timestamp.replace(tzinfo=timezone.utc).timestamp() * 1000)
                    }

            msg = Message(
                user_id=user_id,
                persona_id=persona_id,
                session_id=session_id,
                role=role,
                content=content,
                type=msg_type,
                client_msg_id=client_msg_id
            )
            session.add(msg)

            # 更新关联会话的 updated_at 及自动生成首轮标题
            if session_id:
                sess = session.query(Session).filter(Session.id == session_id).first()
                if sess:
                    sess.updated_at = datetime.datetime.now(timezone.utc)
                    if role == "user" and (sess.title == "新对话" or not sess.title):
                        # 提炼首句作为会话名（去除换行，截取前 24 字符）
                        clean_title = content.replace("\n", " ").strip()
                        if clean_title:
                            sess.title = clean_title[:24]

            session.commit()
            session.refresh(msg)
            
            return {
                "id": msg.id,
                "role": msg.role,
                "content": msg.content,
                "type": msg.type,
                "session_id": msg.session_id,
                "persona_id": msg.persona_id,
                "timestamp": int(msg.timestamp.replace(tzinfo=timezone.utc).timestamp() * 1000)
            }

    def clear_messages(self, user_id: int, persona_id: str = "default", session_id: str = None) -> int:
        """删除指定用户指定会话（或人格）的聊天记录，返回被删除条数。"""
        with self.SessionLocal() as session:
            query = session.query(Message).filter(Message.user_id == user_id)
            if session_id:
                query = query.filter(Message.session_id == session_id)
            else:
                query = query.filter(Message.persona_id == persona_id)
            count = query.count()
            query.delete(synchronize_session=False)
            session.commit()
            logger.info(f"[Lumi-Hub DB] 已清空用户 {user_id} (session={session_id}, persona={persona_id}) 的 {count} 条聊天记录")
            return count

    def delete_messages(self, user_id: int, message_ids: list[str], persona_id: str = "default", session_id: str = None) -> int:
        """按 message_id/client_msg_id 删除指定消息，返回删除条数。"""
        normalized_ids = {str(mid).strip() for mid in (message_ids or []) if str(mid).strip()}
        if not normalized_ids:
            return 0

        # 兼容前端以 *_ai 形式传 assistant 消息 id。
        ai_base_ids = [mid[:-3] for mid in normalized_ids if mid.endswith("_ai") and len(mid) > 3]

        numeric_ids: list[int] = []
        for mid in normalized_ids:
            if mid.isdigit():
                try:
                    numeric_ids.append(int(mid))
                except ValueError:
                    pass

        with self.SessionLocal() as session:
            base_query = session.query(Message).filter(Message.user_id == user_id)
            if session_id:
                base_query = base_query.filter(Message.session_id == session_id)
            else:
                base_query = base_query.filter(Message.persona_id == persona_id)

            filters = [Message.client_msg_id.in_(list(normalized_ids))]
            if numeric_ids:
                filters.append(Message.id.in_(numeric_ids))
            if ai_base_ids:
                filters.append(
                    (Message.role == "assistant") & (Message.client_msg_id.in_(ai_base_ids))
                )

            query = base_query.filter(or_(*filters))
            count = query.count()
            query.delete(synchronize_session=False)
            session.commit()
            logger.info(f"[Lumi-Hub DB] 已删除用户 {user_id} 下的 {count} 条消息")
            return count

    def get_messages(
        self,
        user_id: int,
        persona_id: str = "default",
        session_id: str = None,
        limit: int = 50,
        offset: int = 0,
    ) -> list:
        """倒序获取历史消息（优先按 session_id，回退按 persona_id），返回时间正序列表"""
        with self.SessionLocal() as session:
            query = session.query(Message).filter(Message.user_id == user_id)
            if session_id:
                query = query.filter(Message.session_id == session_id)
            else:
                query = query.filter(Message.persona_id == persona_id)

            messages = query.order_by(Message.timestamp.desc())\
                            .offset(offset).limit(limit).all()
            
            # 前端展示要求按时间正序
            messages.reverse()
            
            result = []
            for msg in messages:
                result.append({
                    "message_id": msg.client_msg_id or str(msg.id),
                    "role": msg.role,
                    "content": msg.content,
                    "type": msg.type,
                    "session_id": msg.session_id,
                    "persona_id": msg.persona_id,
                    "timestamp": int(msg.timestamp.replace(tzinfo=timezone.utc).timestamp() * 1000)
                })
            return result

    # ===== 附件相关 =====

    def create_attachment(
        self,
        user_id: int,
        file_name: str,
        storage_path: str,
        mime_type: str,
        size_bytes: int,
        sha256: str,
    ) -> dict:
        """创建附件元数据记录。"""
        with self.SessionLocal() as session:
            att = Attachment(
                user_id=user_id,
                file_name=file_name,
                storage_path=storage_path,
                mime_type=mime_type,
                size_bytes=size_bytes,
                sha256=sha256,
            )
            session.add(att)
            session.commit()
            session.refresh(att)

            return {
                "id": att.id,
                "user_id": att.user_id,
                "file_name": att.file_name,
                "storage_path": att.storage_path,
                "mime_type": att.mime_type,
                "size_bytes": att.size_bytes,
                "sha256": att.sha256,
                "created_at": att.created_at.isoformat(),
            }
