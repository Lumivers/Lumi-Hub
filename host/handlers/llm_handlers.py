from __future__ import annotations

import json
import logging
import os
import time
import uuid
from typing import Any

logger = logging.getLogger("lumi")


class LlmHandlersMixin:
    """负责 LLM 配置管理、模型切换、思考强度调节与连通性测试。"""

    @property
    def _llm_config_path(self) -> str:
        return os.path.join(self.data_dir, "llm_config.json")

    def _mask_key(self, api_key: str) -> str:
        if not api_key:
            return ""
        if len(api_key) > 8:
            return api_key[:4] + "*" * (len(api_key) - 8) + api_key[-4:]
        return "****"

    def _normalize_llm_config(self, data: dict) -> dict:
        """保证配置包含 active_model_id、models 列表以及顶层激活项。"""
        models = data.get("models")
        if not isinstance(models, list) or not models:
            # 兼容旧版本单模型配置
            default_id = "default"
            provider = data.get("provider", "openai")
            model = data.get("model", "deepseek-chat")
            base_url = data.get("base_url", "https://api.deepseek.com")
            api_key = data.get("api_key", "")
            preset = data.get("provider_preset", "deepseek")
            models = [{
                "id": default_id,
                "name": model or "默认模型",
                "provider": provider,
                "provider_preset": preset,
                "model": model,
                "base_url": base_url,
                "api_key": api_key,
            }]
            data["models"] = models
            data["active_model_id"] = default_id

        active_id = data.get("active_model_id")
        active_model = next((m for m in models if m.get("id") == active_id), models[0])
        data["active_model_id"] = active_model.get("id")
        # 同步顶层字段保持完全向后兼容
        data["provider"] = active_model.get("provider", "openai")
        data["provider_preset"] = active_model.get("provider_preset", data["provider"])
        data["model"] = active_model.get("model", "")
        data["base_url"] = active_model.get("base_url", "")
        data["api_key"] = active_model.get("api_key", "")
        data["reasoning_effort"] = data.get("reasoning_effort", "high")
        return data

    def _load_llm_config(self) -> dict:
        """读取 LLM 配置文件。"""
        if os.path.exists(self._llm_config_path):
            try:
                with open(self._llm_config_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        return self._normalize_llm_config(data)
            except Exception:
                pass
        return self._normalize_llm_config({
            "provider": "openai",
            "provider_preset": "deepseek",
            "api_key": "",
            "base_url": "https://api.deepseek.com",
            "model": "deepseek-chat",
        })

    def _save_llm_config(self, config: dict) -> None:
        """保存 LLM 配置文件。"""
        with open(self._llm_config_path, "w", encoding="utf-8") as f:
            json.dump(config, f, ensure_ascii=False, indent=2)

    async def _reload_llm_provider(self, config: dict):
        """热重载 LLM Provider。"""
        try:
            from ..llm import create_provider
            self.llm = create_provider(
                data_dir=self.data_dir,
                provider_type=config.get("provider"),
                api_key=config.get("api_key", ""),
                base_url=config.get("base_url") or None,
                default_model=config.get("model"),
            )
            self.memory_manager.llm = self.llm
            logger.info(f"[Lumi-Hub] LLM Provider 已热重载: {type(self.llm).__name__} (model={config.get('model')})")
        except Exception as e:
            logger.error(f"[Lumi-Hub] LLM Provider 热重载失败: {e}")
            raise

    async def _handle_llm_config_get(self, message: dict, ws_session_id: str) -> None:
        """获取 LLM 配置与用户已添加的所有模型列表。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        config = self._load_llm_config()

        models_safe = []
        for m in config.get("models", []):
            k = m.get("api_key", "")
            models_safe.append({
                "id": m.get("id", ""),
                "name": m.get("name", m.get("model", "")),
                "provider": m.get("provider", "openai"),
                "provider_preset": m.get("provider_preset", m.get("provider", "openai")),
                "model": m.get("model", ""),
                "base_url": m.get("base_url", ""),
                "api_key_configured": bool(k),
                "api_key_masked": self._mask_key(k),
            })

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_CONFIG_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "success",
                "active_model_id": config.get("active_model_id", "default"),
                "reasoning_effort": self._reasoning_effort,
                "models": models_safe,
                "config": {
                    "provider": config.get("provider", "openai"),
                    "provider_preset": config.get("provider_preset", config.get("provider", "openai")),
                    "model": config.get("model", ""),
                    "base_url": config.get("base_url", ""),
                    "api_key_masked": self._mask_key(config.get("api_key", "")),
                    "api_key_configured": bool(config.get("api_key", "")),
                },
            },
        })

    async def _handle_llm_switch_model(self, message: dict, ws_session_id: str) -> None:
        """快速切换当前激活的模型 Profile。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        model_id = payload.get("model_id", "").strip()

        current = self._load_llm_config()
        models = current.get("models", [])
        target = next((m for m in models if m.get("id") == model_id), None)
        if not target:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_SWITCH_MODEL_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": f"未找到模型: {model_id}"},
            })
            return

        current["active_model_id"] = model_id
        current = self._normalize_llm_config(current)
        self._save_llm_config(current)

        # 热重载
        await self._reload_llm_provider(current)

        # 回复发送端
        sync_payload = {
            "status": "success",
            "active_model_id": model_id,
            "name": target.get("name", target.get("model", "")),
            "model": target.get("model", ""),
            "provider": target.get("provider", "openai"),
            "reasoning_effort": self._reasoning_effort,
        }
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_SWITCH_MODEL_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": sync_payload,
        })

    async def _handle_llm_set_thinking_level(self, message: dict, ws_session_id: str) -> None:
        """设置思考/推理等级 (low / medium / high)。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        level = str(payload.get("level", "high")).strip().lower()
        if level not in ("low", "medium", "high"):
            level = "high"

        self._reasoning_effort = level
        current = self._load_llm_config()
        current["reasoning_effort"] = level
        self._save_llm_config(current)

        logger.info(f"[Lumi-Hub] 思考等级切换为: {level}")
        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_SET_THINKING_LEVEL_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {
                "status": "success",
                "reasoning_effort": level,
            },
        })

    async def _handle_llm_model_save(self, message: dict, ws_session_id: str) -> None:
        """添加或更新一个模型 Profile。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        model_data = payload.get("model", {})
        set_active = payload.get("set_active", False)

        if not isinstance(model_data, dict):
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_MODEL_SAVE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Invalid model data"},
            })
            return

        current = self._load_llm_config()
        models = current.get("models", [])

        model_id = (model_data.get("id") or str(uuid.uuid4())[:8]).strip()
        name = (model_data.get("name") or model_data.get("model") or "未命名模型").strip()
        provider = (model_data.get("provider") or "openai").strip()
        preset = (model_data.get("provider_preset") or provider).strip()
        model_name = (model_data.get("model") or "").strip()
        base_url = (model_data.get("base_url") or "").strip()
        new_key = str(model_data.get("api_key", "")).strip()

        existing = next((m for m in models if m.get("id") == model_id), None)
        if existing:
            existing["name"] = name
            existing["provider"] = provider
            existing["provider_preset"] = preset
            existing["model"] = model_name
            existing["base_url"] = base_url
            if new_key:
                existing["api_key"] = new_key
        else:
            item = {
                "id": model_id,
                "name": name,
                "provider": provider,
                "provider_preset": preset,
                "model": model_name,
                "base_url": base_url,
                "api_key": new_key,
            }
            models.append(item)

        if set_active or len(models) == 1:
            current["active_model_id"] = model_id

        current["models"] = models
        current = self._normalize_llm_config(current)
        self._save_llm_config(current)

        if current.get("active_model_id") == model_id:
            await self._reload_llm_provider(current)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_MODEL_SAVE_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "model_id": model_id},
        })

    async def _handle_llm_model_delete(self, message: dict, ws_session_id: str) -> None:
        """删除一个模型 Profile。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        model_id = payload.get("model_id", "").strip()

        current = self._load_llm_config()
        models = current.get("models", [])
        if len(models) <= 1:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_MODEL_DELETE_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "至少需要保留一个模型配置"},
            })
            return

        new_models = [m for m in models if m.get("id") != model_id]
        current["models"] = new_models
        if current.get("active_model_id") == model_id:
            current["active_model_id"] = new_models[0].get("id")

        current = self._normalize_llm_config(current)
        self._save_llm_config(current)
        await self._reload_llm_provider(current)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_MODEL_DELETE_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "active_model_id": current.get("active_model_id")},
        })

    async def _handle_llm_config_set(self, message: dict, ws_session_id: str) -> None:
        """更新 LLM 配置并热重载。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {})
        new_config = payload.get("config", {})

        if not isinstance(new_config, dict):
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": "Invalid config format"},
            })
            return

        # 合并配置（保留未传入的字段）
        current = self._load_llm_config()
        for key in ("provider", "provider_preset", "api_key", "base_url", "model"):
            if key in new_config:
                current[key] = new_config[key]

        # 保存
        try:
            self._save_llm_config(current)
        except Exception as e:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": f"Save failed: {e}"},
            })
            return

        # 热重载
        try:
            await self._reload_llm_provider(current)
        except Exception as e:
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_CONFIG_SET_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {"status": "error", "message": f"Reload failed: {e}"},
            })
            return

        # 需要登录才能操作
        user_id = self.active_sessions.get(ws_session_id)
        if user_id:
            # 更新人格中的 agent prompt
            await self._build_agent_prompt()
            default_persona = await self.persona_manager.get_persona("default")
            if default_persona:
                cleaned = default_persona.system_prompt
                for old_tag in ["### LUMI_AGENT_RULES ###", "### LUMI_IDE_AGENT_v1 ###", "### LUMI_IDE_AGENT_v2 ###"]:
                    if old_tag in cleaned:
                        idx = cleaned.find(old_tag)
                        cleaned = cleaned[:idx].strip()
                default_persona.system_prompt = cleaned + self._agent_prompt
                await self.persona_manager.save_persona(default_persona)

        await self.ws_server.send_to_client(ws_session_id, {
            "message_id": msg_id,
            "type": "LLM_CONFIG_SET_RESPONSE",
            "source": "host",
            "target": "client",
            "timestamp": int(time.time() * 1000),
            "payload": {"status": "success", "message": "LLM config updated and reloaded"},
        })

    async def _handle_llm_test_connection(self, message: dict, ws_session_id: str) -> None:
        """测试指定或当前 LLM 配置的连通性与网络延迟。"""
        msg_id = message.get("message_id", str(uuid.uuid4())[:8])
        payload = message.get("payload", {}) or {}
        config = payload.get("config", {}) or {}

        saved_config = self._load_llm_config()
        api_key = str(config.get("api_key", "")).strip()
        if not api_key:
            api_key = saved_config.get("api_key", "")

        provider_type = config.get("provider") or saved_config.get("provider", "openai")
        base_url = config.get("base_url") if "base_url" in config else saved_config.get("base_url")
        model = config.get("model") or saved_config.get("model", "gpt-4o")

        if not api_key and provider_type not in ("ollama",):
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_TEST_CONNECTION_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "error",
                    "latency_ms": 0,
                    "message": "请先填写 API Key",
                },
            })
            return

        start_time = time.time()
        try:
            from ..llm import create_provider
            test_provider = create_provider(
                data_dir=self.data_dir,
                provider_type=provider_type,
                api_key=api_key,
                base_url=base_url or None,
                default_model=model,
            )

            # 发送轻量请求以测试握手连通性
            response_text = ""
            async for chunk in test_provider.chat_stream(
                messages=[{"role": "user", "content": "Hi"}],
                max_tokens=10,
            ):
                if chunk.get("type") == "text":
                    response_text += chunk.get("content", "")
                    if len(response_text) >= 1:
                        break

            latency_ms = int((time.time() - start_time) * 1000)
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_TEST_CONNECTION_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "success",
                    "latency_ms": latency_ms,
                    "message": f"连接正常，延迟 {latency_ms}ms",
                    "reply_preview": response_text.strip()[:30],
                },
            })
        except Exception as e:
            latency_ms = int((time.time() - start_time) * 1000)
            logger.warning(f"[Lumi-Hub] LLM 连通性测试失败: {e}")
            await self.ws_server.send_to_client(ws_session_id, {
                "message_id": msg_id,
                "type": "LLM_TEST_CONNECTION_RESPONSE",
                "source": "host",
                "target": "client",
                "timestamp": int(time.time() * 1000),
                "payload": {
                    "status": "error",
                    "latency_ms": latency_ms,
                    "message": f"连接失败: {str(e)}",
                },
            })
