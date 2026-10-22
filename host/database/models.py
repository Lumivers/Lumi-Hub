from datetime import datetime, timezone
from sqlalchemy import Column, Integer, String, DateTime, Text, ForeignKey, create_engine, text
from sqlalchemy.orm import declarative_base, relationship, sessionmaker

Base = declarative_base()

class User(Base):
    __tablename__ = 'users'

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(50), unique=True, nullable=False, index=True)
    password_hash = Column(String(128), nullable=False)
    # 安全随机 token，用于 WebSocket 会话恢复认证
    token = Column(String(64), nullable=True, unique=True, index=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    # 关联用户的聊天记录与附件。
    messages = relationship("Message", back_populates="user", cascade="all, delete-orphan")
    attachments = relationship("Attachment", back_populates="user", cascade="all, delete-orphan")
    sessions = relationship("Session", back_populates="user", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<User(username='{self.username}')>"


class Session(Base):
    """会话表 — 关联工作区与对话历史。"""
    __tablename__ = 'sessions'

    id = Column(String(64), primary_key=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    # 工作区绝对路径（例如 /home/luser/RiderProjects/Lumi-Hub）
    workspace_path = Column(String(512), nullable=False, default="", index=True)
    title = Column(String(255), nullable=False, default="新对话")
    persona_id = Column(String(50), nullable=False, default="default", server_default="default", index=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), index=True)
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), index=True)

    user = relationship("User", back_populates="sessions")
    messages = relationship("Message", back_populates="session", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<Session(id='{self.id}', title='{self.title}', workspace='{self.workspace_path}')>"


class Message(Base):
    __tablename__ = 'messages'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    # 所属会话 ID（如果为空则为向后兼容的老消息）
    session_id = Column(String(64), ForeignKey('sessions.id'), nullable=True, index=True)
    # role 通常是 'user', 'assistant', 或 'system'
    role = Column(String(20), nullable=False)
    # 消息内容，针对不同 type 这里可以是纯文本，也可以是 JSON string
    content = Column(Text, nullable=False)
    # 消息类型，如 'chat', 'tool_result'
    type = Column(String(50), default='chat')
    timestamp = Column(DateTime, default=lambda: datetime.now(timezone.utc), index=True)
    
    # 人格隔离字段：记录这条消息是给哪个人格发的，或者是哪个人格回的
    persona_id = Column(String(50), nullable=False, default="default", server_default="default", index=True)
    
    # 防止多端同步时出现重复 id（前端 message_id 可落这里）。
    client_msg_id = Column(String(64), nullable=True, unique=True)

    user = relationship("User", back_populates="messages")
    session = relationship("Session", back_populates="messages")

    def __repr__(self):
        return f"<Message(role='{self.role}', type='{self.type}', len={len(self.content)})>"


class Attachment(Base):
    __tablename__ = 'attachments'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    file_name = Column(String(255), nullable=False)
    mime_type = Column(String(100), nullable=False, default='application/octet-stream')
    size_bytes = Column(Integer, nullable=False)
    sha256 = Column(String(64), nullable=False, index=True)
    # 相对 data 目录的路径，如 uploads/user_1/2026/03/24/xxx.png
    storage_path = Column(Text, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), index=True)

    user = relationship("User", back_populates="attachments")

    def __repr__(self):
        return f"<Attachment(name='{self.file_name}', mime='{self.mime_type}', size={self.size_bytes})>"


class Memory(Base):
    """用户记忆表 — Lumi-Hub 2.0 新增。"""
    __tablename__ = 'memories'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    persona_id = Column(String(50), nullable=False, default="default", index=True)
    # 类别: preference | fact | correction | summary
    category = Column(String(20), nullable=False, index=True)
    content = Column(Text, nullable=False)
    # 来源消息的 client_msg_id（可追溯）
    source_message_id = Column(String(64), nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    last_accessed = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    access_count = Column(Integer, default=0)

    def __repr__(self):
        return f"<Memory(category='{self.category}', content='{self.content[:30]}...')>"


# 数据库引擎初始化辅助函数
def init_db(db_path: str):
    # 首次启动会自动建表。
    engine = create_engine(f"sqlite:///{db_path}", echo=False)
    Base.metadata.create_all(engine)

    # 动态平滑迁移：检查 messages 表是否已有 session_id 字段
    try:
        with engine.connect() as conn:
            result = conn.execute(text("PRAGMA table_info(messages)"))
            columns = [row[1] for row in result]
            if "session_id" not in columns:
                conn.execute(text("ALTER TABLE messages ADD COLUMN session_id VARCHAR(64)"))
                conn.commit()
    except Exception as e:
        import logging
        logging.getLogger("lumi").warning(f"[DB Migration] 检查/迁移 session_id 字段: {e}")

    return sessionmaker(bind=engine)
