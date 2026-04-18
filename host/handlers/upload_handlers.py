from __future__ import annotations

import base64
import hashlib
import mimetypes
import os
import time
import uuid

from astrbot.api import logger


class UploadHandlersMixin:
    def _normalize_mime(self, file_name: str, mime_type: str) -> str:
        guessed = mimetypes.guess_type(file_name)[0]
        final_mime = (mime_type or guessed or "application/octet-stream").lower()
        return final_mime

    def _is_allowed_mime(self, mime_type: str) -> bool:
        if mime_type in self.allowed_mime_exact:
            return True
        return any(mime_type.startswith(prefix) for prefix in self.allowed_mime_prefixes)

    def _safe_file_name(self, file_name: str) -> str:
        base_name = os.path.basename(file_name or "file.bin")
        # 避免目录穿越，替换常见危险字符
        return "".join(c if c not in '<>:"/\\|?*' else '_' for c in base_name)

    def _extract_pdf_preview(self, abs_path: str, max_chars: int = 6000, max_pages: int = 5) -> str:
        """提取 PDF 的前几页文本用于提示词增强。若依赖缺失或解析失败则返回空字符串。"""
        if not abs_path or not os.path.exists(abs_path):
            return ""
        try:
            from pypdf import PdfReader  # type: ignore
        except Exception:
            return ""

        try:
            reader = PdfReader(abs_path)
            parts: list[str] = []
            for idx, page in enumerate(reader.pages):
                if idx >= max_pages:
                    break
                text = page.extract_text() or ""
                if text.strip():
                    parts.append(text.strip())
                if sum(len(p) for p in parts) >= max_chars:
                    break
            merged = "\n\n".join(parts).strip()
            if len(merged) > max_chars:
                merged = merged[:max_chars]
            return merged
        except Exception as e:
            logger.warning(f"[Lumi-Hub] PDF 解析失败: {e}")
            return ""

    async def _send_upload_error(
        self,
        ws_session_id: str,
        msg_id: str,
        detail: str,
        upload_id: str = "",
    ) -> None:
        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "FILE_UPLOAD_ERROR",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "upload_id": upload_id,
                    "detail": detail,
                },
            },
        )

    def _discard_upload_session(self, upload_id: str) -> None:
        session = self.upload_sessions.pop(upload_id, None)
        if not session:
            return
        tmp_path = session.get("tmp_path", "")
        try:
            if tmp_path and os.path.exists(tmp_path):
                os.remove(tmp_path)
        except Exception as e:
            logger.warning(f"[Lumi-Hub] 清理临时上传文件失败: {e}")

    async def _handle_file_upload_init(self, message: dict, ws_session_id: str) -> None:
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self._send_upload_error(ws_session_id, msg_id, "请先登录")
            return

        payload = message.get("payload", {})
        file_name = self._safe_file_name(payload.get("file_name", "file.bin"))
        mime_type = self._normalize_mime(file_name, payload.get("mime_type", ""))
        size_bytes = int(payload.get("size_bytes", 0) or 0)
        sha256_expected = str(payload.get("sha256", "") or "").lower()

        if size_bytes <= 0:
            await self._send_upload_error(ws_session_id, msg_id, "无效文件大小")
            return
        if size_bytes > self.max_upload_size_bytes:
            await self._send_upload_error(ws_session_id, msg_id, f"文件过大，最大支持 {self.max_upload_size_bytes} 字节")
            return
        if not self._is_allowed_mime(mime_type):
            await self._send_upload_error(ws_session_id, msg_id, f"不支持的文件类型: {mime_type}")
            return

        upload_id = str(uuid.uuid4())
        tmp_path = os.path.join(self.upload_staging_dir, f"{upload_id}.part")
        # 先创建空文件，便于后续追加
        with open(tmp_path, "wb"):
            pass

        self.upload_sessions[upload_id] = {
            "user_id": user_id,
            "ws_session_id": ws_session_id,
            "file_name": file_name,
            "mime_type": mime_type,
            "size_bytes": size_bytes,
            "sha256_expected": sha256_expected,
            "tmp_path": tmp_path,
            "received_bytes": 0,
            "hasher": hashlib.sha256(),
            "started_at": int(time.time()),
        }

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "FILE_UPLOAD_ACK",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "phase": "init",
                    "upload_id": upload_id,
                    "chunk_size_hint": 262144,
                    "status": "ready",
                },
            },
        )

    async def _handle_file_upload_chunk(self, message: dict, ws_session_id: str) -> None:
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        upload_id = str(payload.get("upload_id", "") or "")
        chunk_b64 = payload.get("chunk_base64") or payload.get("chunk") or ""
        chunk_index = int(payload.get("chunk_index", 0) or 0)

        session = self.upload_sessions.get(upload_id)
        if not session:
            await self._send_upload_error(ws_session_id, msg_id, "上传会话不存在", upload_id)
            return
        if session.get("ws_session_id") != ws_session_id:
            await self._send_upload_error(ws_session_id, msg_id, "上传会话不匹配", upload_id)
            return

        try:
            chunk_bytes = base64.b64decode(chunk_b64, validate=True)
        except Exception:
            self._discard_upload_session(upload_id)
            await self._send_upload_error(ws_session_id, msg_id, "分片不是合法 base64", upload_id)
            return

        if not chunk_bytes:
            await self._send_upload_error(ws_session_id, msg_id, "空分片无效", upload_id)
            return

        session["received_bytes"] += len(chunk_bytes)
        if session["received_bytes"] > session["size_bytes"]:
            self._discard_upload_session(upload_id)
            await self._send_upload_error(ws_session_id, msg_id, "接收字节超过声明大小", upload_id)
            return

        try:
            with open(session["tmp_path"], "ab") as f:
                f.write(chunk_bytes)
            session["hasher"].update(chunk_bytes)
        except Exception as e:
            self._discard_upload_session(upload_id)
            await self._send_upload_error(ws_session_id, msg_id, f"写入分片失败: {e}", upload_id)
            return

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "FILE_UPLOAD_ACK",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "phase": "chunk",
                    "upload_id": upload_id,
                    "chunk_index": chunk_index,
                    "received_bytes": session["received_bytes"],
                },
            },
        )

    async def _handle_file_upload_complete(self, message: dict, ws_session_id: str) -> None:
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        upload_id = str(payload.get("upload_id", "") or "")
        session = self.upload_sessions.get(upload_id)

        if not session:
            await self._send_upload_error(ws_session_id, msg_id, "上传会话不存在", upload_id)
            return
        if session.get("ws_session_id") != ws_session_id:
            await self._send_upload_error(ws_session_id, msg_id, "上传会话不匹配", upload_id)
            return

        if session["received_bytes"] != session["size_bytes"]:
            self._discard_upload_session(upload_id)
            await self._send_upload_error(
                ws_session_id,
                msg_id,
                f"文件大小不匹配: expected={session['size_bytes']} received={session['received_bytes']}",
                upload_id,
            )
            return

        actual_sha256 = session["hasher"].hexdigest().lower()
        expected_sha256 = session.get("sha256_expected", "")
        if expected_sha256 and expected_sha256 != actual_sha256:
            self._discard_upload_session(upload_id)
            await self._send_upload_error(ws_session_id, msg_id, "文件哈希校验失败", upload_id)
            return

        now = time.localtime()
        final_dir = os.path.join(
            self.upload_root_dir,
            f"user_{session['user_id']}",
            f"{now.tm_year:04d}",
            f"{now.tm_mon:02d}",
            f"{now.tm_mday:02d}",
        )
        os.makedirs(final_dir, exist_ok=True)

        final_name = f"{upload_id}_{session['file_name']}"
        final_abs_path = os.path.join(final_dir, final_name)
        final_rel_path = os.path.relpath(final_abs_path, self.data_dir).replace("\\", "/")

        try:
            os.replace(session["tmp_path"], final_abs_path)
            attachment = self.db.create_attachment(
                user_id=session["user_id"],
                file_name=session["file_name"],
                storage_path=final_rel_path,
                mime_type=session["mime_type"],
                size_bytes=session["size_bytes"],
                sha256=actual_sha256,
            )
        except Exception as e:
            self._discard_upload_session(upload_id)
            await self._send_upload_error(ws_session_id, msg_id, f"完成上传失败: {e}", upload_id)
            return

        self.upload_sessions.pop(upload_id, None)

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "FILE_UPLOAD_ACK",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "phase": "complete",
                    "upload_id": upload_id,
                    "status": "success",
                    "attachment": attachment,
                },
            },
        )
