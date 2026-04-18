from __future__ import annotations

import asyncio
import base64
import time
import uuid

from astrbot.api import logger

from ..voice_extensions import (
    TTSRequest,
    VoiceProviderError,
    build_style_plan,
    compile_ssml,
    plan_style_for_text,
)


class VoiceHandlersMixin:
    async def _dispatch_voice_tts_request(self, message: dict, ws_session_id: str) -> None:
        # TTS 合成放到后台任务，避免阻塞主消息分发协程。
        self._spawn_voice_tts_task(message, ws_session_id)

    async def _handle_voice_config_get(self, message: dict, ws_session_id: str) -> None:
        # 返回当前 provider 配置快照（含 key 是否配置但不返回明文）。
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "VOICE_CONFIG_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "status": "error",
                        "message": "请先登录",
                    },
                },
            )
            return

        provider = self._dashscope_provider
        if provider is None:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "VOICE_CONFIG_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "status": "error",
                        "message": "Voice provider is not initialized",
                    },
                },
            )
            return

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "VOICE_CONFIG_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "config": {
                        "provider": "dashscope",
                        "voice_id": provider.default_voice,
                        "api_key_configured": provider.has_api_key(),
                        "api_key_source": provider.get_api_key_source(),
                        "api_key_masked": provider.get_masked_api_key(),
                    },
                },
            },
        )

    async def _handle_voice_config_set(self, message: dict, ws_session_id: str) -> None:
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "VOICE_CONFIG_SET_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "status": "error",
                        "message": "请先登录",
                    },
                },
            )
            return

        provider = self._dashscope_provider
        if provider is None:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "VOICE_CONFIG_SET_RESPONSE",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "status": "error",
                        "message": "Voice provider is not initialized",
                    },
                },
            )
            return

        payload = message.get("payload", {})
        config = payload.get("config", {}) if isinstance(payload, dict) else {}
        if not isinstance(config, dict):
            config = {}

        voice_id = str(config.get("voice_id", "") or "").strip()
        api_key = str(config.get("api_key", "") or "").strip()
        clear_api_key = bool(config.get("clear_api_key", False))

        # 支持部分更新：voice_id / api_key 可独立变更。
        if voice_id:
            provider.default_voice = voice_id
            self._voice_config_cache["dashscope_voice_id"] = voice_id

        if clear_api_key:
            provider.set_api_key("")
            self._voice_config_cache.pop("dashscope_api_key", None)
        elif api_key:
            provider.set_api_key(api_key)
            self._voice_config_cache["dashscope_api_key"] = api_key

        self._save_voice_config()

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "VOICE_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "config": {
                        "provider": "dashscope",
                        "voice_id": provider.default_voice,
                        "api_key_configured": provider.has_api_key(),
                        "api_key_source": provider.get_api_key_source(),
                        "api_key_masked": provider.get_masked_api_key(),
                    },
                },
            },
        )

    def _spawn_voice_tts_task(self, message: dict, ws_session_id: str) -> None:
        task = asyncio.create_task(self._handle_voice_tts_request(message, ws_session_id))
        task.add_done_callback(self._track_voice_tts_task)

    def _track_voice_tts_task(self, task: asyncio.Task) -> None:
        try:
            exc = task.exception()
        except asyncio.CancelledError:
            return
        if exc:
            logger.error(f"[Lumi-Hub] VOICE_TTS_REQUEST task failed: {exc}")

    async def _handle_voice_interrupt(self, message: dict, ws_session_id: str) -> None:
        payload = message.get("payload", {})
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        turn_id = str(payload.get("turn_id", "") or "").strip()

        # 指定 turn_id 则定向中断，否则中断当前活跃轮次。
        if turn_id:
            await self.speech_sessions.cancel_turn(ws_session_id, turn_id)
        else:
            turn_id = await self.speech_sessions.cancel_active_turn(ws_session_id) or ""

        if turn_id:
            await self.voice_registry.cancel_all(ws_session_id, turn_id)
            running_task = self._voice_turn_tasks.pop((ws_session_id, turn_id), None)
            if running_task and not running_task.done():
                running_task.cancel()
            status = "cancelled"
        else:
            status = "no_active_turn"

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "VOICE_INTERRUPT_ACK",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "turn_id": turn_id,
                    "status": status,
                },
            },
        )

    async def _handle_voice_tts_request(self, message: dict, ws_session_id: str) -> None:
        # 处理 VOICE_TTS_REQUEST 全流程：校验 -> 启动 -> 分片推流 -> 结束回包。
        payload = message.get("payload", {})
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        user_id = self.active_sessions.get(ws_session_id)
        if not user_id:
            await self.ws_server.send_to_client(
                ws_session_id,
                {
                    "message_id": msg_id,
                    "type": "ERROR_ALERT",
                    "source": "host",
                    "target": "client",
                    "timestamp": int(time.time() * 1000),
                    "payload": {
                        "error_code": "UNAUTHORIZED",
                        "detail": "Please login first",
                    },
                },
            )
            return

        text = str(payload.get("text", "") or "")
        turn_id = str(payload.get("turn_id", "") or str(uuid.uuid4())[:8])
        provider_name = str(payload.get("provider", "") or "").strip() or None
        voice_id = str(payload.get("voice_id", "") or "").strip()
        raw_use_ssml = payload.get("use_ssml", True)
        if isinstance(raw_use_ssml, str):
            use_ssml = raw_use_ssml.strip().lower() in ("1", "true", "yes", "on")
        else:
            use_ssml = bool(raw_use_ssml)
        try:
            chunk_bytes = int(payload.get("chunk_bytes", 32768) or 32768)
        except (TypeError, ValueError):
            chunk_bytes = 32768
        raw_style_plan = payload.get("style_plan")
        raw_auto_style = payload.get("auto_style", True)
        if isinstance(raw_auto_style, str):
            auto_style = raw_auto_style.strip().lower() in ("1", "true", "yes", "on")
        else:
            auto_style = bool(raw_auto_style)
        if isinstance(raw_style_plan, dict):
            style_plan = build_style_plan(raw_style_plan)
        elif auto_style:
            style_plan = plan_style_for_text(text)
        else:
            style_plan = build_style_plan(None)
        custom_ssml = str(payload.get("ssml", "") or "").strip()
        if custom_ssml:
            use_ssml = True

        provider = self.voice_registry.get_tts(provider_name)
        if not provider:
            await self._send_tts_stream_end(
                ws_session_id,
                msg_id,
                turn_id,
                status="error",
                detail="No TTS provider registered",
            )
            return

        if not text.strip() and not custom_ssml:
            await self._send_tts_stream_end(
                ws_session_id,
                msg_id,
                turn_id,
                status="error",
                detail="Text is empty",
            )
            return

        if use_ssml and not provider.supports_ssml:
            await self._send_tts_stream_end(
                ws_session_id,
                msg_id,
                turn_id,
                status="error",
                detail=f"Provider '{provider.provider_name}' does not support SSML",
            )
            return

        # 单会话单活跃轮次：新请求会替换并打断旧轮次。
        replaced_turn = await self.speech_sessions.activate_turn(ws_session_id, turn_id)
        if replaced_turn:
            await self.voice_registry.cancel_all(ws_session_id, replaced_turn)
            old_task = self._voice_turn_tasks.pop((ws_session_id, replaced_turn), None)
            if old_task and old_task is not asyncio.current_task() and not old_task.done():
                old_task.cancel()

        current_task = asyncio.current_task()
        if current_task:
            self._voice_turn_tasks[(ws_session_id, turn_id)] = current_task

        ssml_text = custom_ssml
        if use_ssml and not ssml_text:
            ssml_text = compile_ssml(text=text, style_plan=style_plan, voice_id=voice_id)

        request = TTSRequest(
            ws_session_id=ws_session_id,
            turn_id=turn_id,
            request_id=msg_id,
            text=text,
            voice_id=voice_id,
            use_ssml=use_ssml,
            ssml=ssml_text,
            style_plan=style_plan,
            chunk_bytes=chunk_bytes,
        )

        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": msg_id,
                "type": "TTS_STREAM_START",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "turn_id": turn_id,
                    "provider": provider.provider_name,
                    "format": provider.output_format,
                    "sample_rate": provider.sample_rate,
                    "status": "started",
                },
            },
        )

        seq_count = 0
        status = "success"
        detail = ""
        try:
            async for chunk in provider.synthesize_stream(request):
                if not await self.speech_sessions.is_active(ws_session_id, turn_id):
                    status = "interrupted"
                    detail = "Turn interrupted"
                    break

                encoded = base64.b64encode(chunk.data).decode("ascii")
                await self.ws_server.send_to_client(
                    ws_session_id,
                    {
                        "message_id": msg_id,
                        "type": "TTS_STREAM_CHUNK",
                        "source": "host",
                        "target": "client",
                        "timestamp": int(time.time() * 1000),
                        "payload": {
                            "turn_id": turn_id,
                            "seq": chunk.seq,
                            "audio_base64": encoded,
                            "format": provider.output_format,
                            "sample_rate": provider.sample_rate,
                        },
                    },
                )
                seq_count = chunk.seq + 1

            if status == "success" and not await self.speech_sessions.is_active(ws_session_id, turn_id):
                status = "interrupted"
                detail = "Turn interrupted"
        except VoiceProviderError as exc:
            status = "error"
            detail = str(exc)
        except asyncio.CancelledError:
            status = "interrupted"
            detail = "Voice task cancelled"
        except Exception as exc:
            status = "error"
            detail = str(exc)
            logger.error(f"[Lumi-Hub] Voice synthesis failed: {exc}")
        finally:
            await self._send_tts_stream_end(
                ws_session_id,
                msg_id,
                turn_id,
                status=status,
                detail=detail,
                seq_count=seq_count,
            )
            await self.speech_sessions.finish_turn(ws_session_id, turn_id)
            self._voice_turn_tasks.pop((ws_session_id, turn_id), None)

    async def _send_tts_stream_end(
        self,
        ws_session_id: str,
        message_id: str,
        turn_id: str,
        status: str,
        detail: str,
        seq_count: int = 0,
    ) -> None:
        await self.ws_server.send_to_client(
            ws_session_id,
            {
                "message_id": message_id,
                "type": "TTS_STREAM_END",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "turn_id": turn_id,
                    "status": status,
                    "detail": detail,
                    "seq_count": seq_count,
                },
            },
        )
