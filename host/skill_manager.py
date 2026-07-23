"""
Lumi-Hub 2.0 — Skill 管理器
加载、安装、执行 Skill（可复用的 Agent 工作流模板）。
"""
import os
import json
import logging
import subprocess
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger("lumi")


@dataclass
class Skill:
    """Skill 数据模型。"""
    name: str
    version: str = "1.0.0"
    author: str = ""
    description: str = ""
    icon: str = "extension"
    requires_mcp: list = field(default_factory=list)
    requires_tools: list = field(default_factory=list)
    params_schema: list = field(default_factory=list)
    system_prompt_template: str = ""
    installed_path: str = ""


class SkillManager:
    """Skill 管理器。

    Skill 是可复用的 Agent 工作流模板，以 YAML 文件定义。
    支持从本地目录加载或从 Git 仓库安装。
    """

    def __init__(self, data_dir: str):
        self.skills_dir = os.path.join(data_dir, "skills")
        os.makedirs(self.skills_dir, exist_ok=True)
        self._skills: dict[str, Skill] = {}

    async def load_all(self):
        """扫描 skills/ 目录加载所有已安装 Skill。"""
        if not os.path.exists(self.skills_dir):
            return

        for name in os.listdir(self.skills_dir):
            skill_dir = os.path.join(self.skills_dir, name)
            yaml_path = os.path.join(skill_dir, "skill.yaml")
            if os.path.isdir(skill_dir) and os.path.exists(yaml_path):
                try:
                    skill = self._load_skill_from_yaml(yaml_path)
                    if skill:
                        self._skills[skill.name] = skill
                        logger.info(f"[SkillManager] 加载 Skill: {skill.name} v{skill.version}")
                except Exception as e:
                    logger.warning(f"[SkillManager] 加载 Skill '{name}' 失败: {e}")

        logger.info(f"[SkillManager] 共加载 {len(self._skills)} 个 Skill")

    def _load_skill_from_yaml(self, yaml_path: str) -> Optional[Skill]:
        """从 YAML 文件加载 Skill 定义。"""
        try:
            import yaml
        except ImportError:
            # 如果没有 PyYAML，用简单的 JSON 代替
            logger.warning("[SkillManager] PyYAML 未安装，尝试加载 JSON 格式")
            return self._load_skill_from_json(yaml_path.replace(".yaml", ".json"))

        try:
            with open(yaml_path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            return self._parse_skill_data(data, os.path.dirname(yaml_path))
        except Exception as e:
            logger.error(f"[SkillManager] 解析 YAML 失败: {e}")
            return None

    def _load_skill_from_json(self, json_path: str) -> Optional[Skill]:
        """从 JSON 文件加载 Skill 定义（备选格式）。"""
        if not os.path.exists(json_path):
            return None
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return self._parse_skill_data(data, os.path.dirname(json_path))
        except Exception as e:
            logger.error(f"[SkillManager] 解析 JSON 失败: {e}")
            return None

    def _parse_skill_data(self, data: dict, skill_path: str) -> Optional[Skill]:
        """解析 Skill 数据。"""
        if not data.get("name"):
            return None
        return Skill(
            name=data["name"],
            version=data.get("version", "1.0.0"),
            author=data.get("author", ""),
            description=data.get("description", ""),
            icon=data.get("icon", "extension"),
            requires_mcp=data.get("requires", {}).get("mcp_servers", []),
            requires_tools=data.get("requires", {}).get("native_tools", []),
            params_schema=data.get("params", []),
            system_prompt_template=data.get("system_prompt", ""),
            installed_path=skill_path,
        )

    async def install_from_git(self, git_url: str) -> Optional[Skill]:
        """从 Git 仓库安装 Skill。"""
        try:
            # 提取仓库名作为 Skill 名
            repo_name = git_url.rstrip("/").split("/")[-1].replace(".git", "")
            target_dir = os.path.join(self.skills_dir, repo_name)

            if os.path.exists(target_dir):
                logger.warning(f"[SkillManager] Skill '{repo_name}' 已存在")
                return self._skills.get(repo_name)

            # git clone
            process = subprocess.run(
                ["git", "clone", "--depth", "1", git_url, target_dir],
                capture_output=True,
                text=True,
                timeout=60,
            )

            if process.returncode != 0:
                logger.error(f"[SkillManager] git clone 失败: {process.stderr}")
                return None

            # 加载 Skill
            yaml_path = os.path.join(target_dir, "skill.yaml")
            if not os.path.exists(yaml_path):
                logger.error(f"[SkillManager] 仓库中未找到 skill.yaml")
                return None

            skill = self._load_skill_from_yaml(yaml_path)
            if skill:
                self._skills[skill.name] = skill
                logger.info(f"[SkillManager] 安装成功: {skill.name} v{skill.version}")
            return skill

        except Exception as e:
            logger.error(f"[SkillManager] 安装失败: {e}")
            return None

    async def uninstall(self, skill_name: str) -> bool:
        """卸载 Skill。"""
        skill = self._skills.get(skill_name)
        if not skill:
            return False

        try:
            import shutil
            shutil.rmtree(skill.installed_path)
            self._skills.pop(skill_name, None)
            logger.info(f"[SkillManager] 已卸载 Skill: {skill_name}")
            return True
        except Exception as e:
            logger.error(f"[SkillManager] 卸载失败: {e}")
            return False

    def get_skill_prompt(self, skill_name: str, params: dict) -> str:
        """渲染 Skill 的 system prompt（填入用户参数）。"""
        skill = self._skills.get(skill_name)
        if not skill:
            return ""

        prompt = skill.system_prompt_template
        for key, value in params.items():
            prompt = prompt.replace(f"{{{key}}}", str(value))
        return prompt

    def list_skills(self) -> list[dict]:
        """列出所有已安装 Skill。"""
        return [
            {
                "name": skill.name,
                "version": skill.version,
                "author": skill.author,
                "description": skill.description,
                "icon": skill.icon,
                "requires_mcp": skill.requires_mcp,
                "requires_tools": skill.requires_tools,
                "params": skill.params_schema,
            }
            for skill in self._skills.values()
        ]

    def get_skill(self, name: str) -> Optional[Skill]:
        """获取指定 Skill。"""
        return self._skills.get(name)
