"""
Lumi-Hub 2.0 — 自建人格管理器
替代 AstrBot 的 persona_manager，管理人格的 system prompt 和元数据。
兼容 AstrBot 的 persona JSON 格式。
"""
import json
import os
import logging
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger("lumi")


@dataclass
class Persona:
    """人格数据模型。"""
    persona_id: str
    system_prompt: str = ""
    begin_dialogs: list = field(default_factory=list)
    tools: list = field(default_factory=list)
    skills: list = field(default_factory=list)


class PersonaManager:
    """人格管理器。

    管理人格的 CRUD 操作。人格以 JSON 文件形式存储在 data/personas/ 目录下。
    兼容 AstrBot 的 persona JSON 格式。
    """

    def __init__(self, data_dir: str):
        self.personas_dir = os.path.join(data_dir, "personas")
        os.makedirs(self.personas_dir, exist_ok=True)
        self._default_persona_id = "default"
        self._cache: dict[str, Persona] = {}

    @property
    def default_persona(self) -> str:
        return self._default_persona_id

    @default_persona.setter
    def default_persona(self, value: str):
        self._default_persona_id = value

    async def get_persona(self, persona_id: str) -> Optional[Persona]:
        """获取人格。优先从缓存读取，缓存未命中则从文件加载。"""
        if persona_id in self._cache:
            return self._cache[persona_id]

        file_path = os.path.join(self.personas_dir, f"{persona_id}.json")
        if not os.path.exists(file_path):
            # 如果请求的是 default 但文件不存在，创建一个默认人格
            if persona_id == self._default_persona_id:
                persona = self._create_default_persona()
                await self.save_persona(persona)
                return persona
            return None

        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            persona = Persona(
                persona_id=data.get("persona_id", persona_id),
                system_prompt=data.get("system_prompt", ""),
                begin_dialogs=data.get("begin_dialogs", []),
                tools=data.get("tools", []),
                skills=data.get("skills", []),
            )
            self._cache[persona_id] = persona
            return persona
        except Exception as e:
            logger.error(f"[PersonaManager] 加载人格 '{persona_id}' 失败: {e}")
            return None

    async def list_personas(self) -> list[dict]:
        """列出所有人格。"""
        personas = []
        # 扫描 personas 目录下的所有 .json 文件
        if os.path.exists(self.personas_dir):
            for filename in os.listdir(self.personas_dir):
                if filename.endswith(".json"):
                    persona_id = filename[:-5]  # 去掉 .json 后缀
                    persona = await self.get_persona(persona_id)
                    if persona:
                        preview = persona.system_prompt
                        if len(preview) > 200:
                            preview = preview[:200] + "..."
                        personas.append({
                            "id": persona.persona_id,
                            "name": persona.persona_id,
                            "system_prompt_preview": preview,
                            "has_begin_dialogs": bool(persona.begin_dialogs),
                            "tools": persona.tools,
                            "skills": persona.skills,
                        })
        return personas

    async def save_persona(self, persona: Persona) -> None:
        """保存人格到文件并更新缓存。"""
        file_path = os.path.join(self.personas_dir, f"{persona.persona_id}.json")
        data = {
            "persona_id": persona.persona_id,
            "system_prompt": persona.system_prompt,
            "begin_dialogs": persona.begin_dialogs,
            "tools": persona.tools,
            "skills": persona.skills,
        }
        try:
            with open(file_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            self._cache[persona.persona_id] = persona
            logger.info(f"[PersonaManager] 人格 '{persona.persona_id}' 已保存")
        except Exception as e:
            logger.error(f"[PersonaManager] 保存人格 '{persona.persona_id}' 失败: {e}")
            raise

    async def update_persona(self, persona_id: str, system_prompt: str) -> None:
        """更新人格的 system prompt。"""
        persona = await self.get_persona(persona_id)
        if persona:
            persona.system_prompt = system_prompt
            await self.save_persona(persona)
        else:
            # 人格不存在，创建新的
            persona = Persona(persona_id=persona_id, system_prompt=system_prompt)
            await self.save_persona(persona)

    async def create_persona(self, persona_id: str, system_prompt: str = "") -> Persona:
        """创建新人格。"""
        existing = await self.get_persona(persona_id)
        if existing:
            raise ValueError(f"人格 '{persona_id}' 已存在")
        persona = Persona(persona_id=persona_id, system_prompt=system_prompt)
        await self.save_persona(persona)
        return persona

    async def delete_persona(self, persona_id: str) -> None:
        """删除人格。"""
        if persona_id == self._default_persona_id:
            raise ValueError("不能删除默认人格")

        file_path = os.path.join(self.personas_dir, f"{persona_id}.json")
        if os.path.exists(file_path):
            os.remove(file_path)
            self._cache.pop(persona_id, None)
            logger.info(f"[PersonaManager] 人格 '{persona_id}' 已删除")
        else:
            raise FileNotFoundError(f"人格 '{persona_id}' 不存在")

    def _create_default_persona(self) -> Persona:
        """创建默认人格。"""
        return Persona(
            persona_id=self._default_persona_id,
            system_prompt=(
                "你是 Lumi，一个友好、聪明的 AI 助手。"
                "你善于用自然、温暖的语气与用户交流，"
                "同时在需要时展现出专业的技术能力。"
            ),
        )

    def clear_cache(self):
        """清空缓存。"""
        self._cache.clear()
