# 🌟 Lumi-Hub: 跨平台私有化 Agent 交互终端与独立运行环境

Lumi-Hub 是专为大模型 Agent 打造的私有化、跨平台桌面/移动端交互枢纽。2.0 版本已全面脱钩第三方框架，内置**完全独立的 Python Agent Runtime**，提供多任务并行、Skill 工作流、长短期记忆与虚拟角色具身交互能力。

[![GitHub](https://img.shields.io/badge/GitHub-Lumivers%2FLumi--Hub-blue?logo=github)](https://github.com/Lumivers/Lumi-Hub)

---

## 2.0 架构与核心特性

### 1. 🧠 独立 Agent Runtime (`host/`)
- **纯 Python 独立运行**：基于 asyncio + WebSocket，无需依赖任何外部机器人框架。
- **ReAct 循环引擎**：自主工具调用与智能决策循环，支持高危文件/系统操作前端实时授权审批。
- **多模型支持**：内置统一 Provider 抽象，原生支持 OpenAI (及所有兼容接口)、Anthropic Claude 以及本地 Ollama。
- **MCP 协议支持**：动态加载并调用 Model Context Protocol (MCP) Server 工具。
- **记忆系统**：支持自动对话偏好/事实提取与多轮上下文检索注入。

### 2. 💻 跨平台客户端 (`client/`)
- **现代化引导**：3 步配置向导（AI 服务商/本地 Ollama → 账号创建 → 多连接模式展示），无需看文档 2 分钟内即可上手。
- **多端互联**：电脑作为主机（Host），手机/平板通过局域网或 USB 调试无线连接控制。
- **语音对话**：支持实时语音识别 (STT) 与 TTS 语音合成流式播放。
- **系统托盘与常驻**：后台最小化到托盘，支持全局快捷键呼出。

---

## 快速开始

### 方式一：一键启动（开发推荐）

在项目根目录下执行一键启动脚本，将同时启动 Python Host 后台与 Flutter 客户端：

```bash
python start.py
```

### 方式二：分别启动

1. **启动 Host 后端**：
   ```bash
   python -m host.main
   ```
2. **启动 Flutter 客户端**：
   ```bash
   cd client
   flutter run -d windows
   ```

---

## 目录结构

```text
Lumi-Hub/
├── host/                    # Python 独立 Agent Runtime
│   ├── main.py              # Host 入口（WebSocket Server 调度中心）
│   ├── agent_loop.py        # ReAct Agent 运行时循环
│   ├── tool_registry.py     # 原生工具与 MCP 工具统一注册中心
│   ├── persona_manager.py   # 人格与 Prompt 状态管理
│   ├── memory_manager.py    # 记忆提取与检索系统
│   ├── skill_manager.py     # Skill 工作流模板管理
│   ├── backup_manager.py    # 数据备份与恢复
│   ├── llm/                 # OpenAI / Anthropic / Ollama Provider 实现
│   ├── stt/                 # 语音识别 Provider
│   └── database/            # SQLite 用户、会话、记忆持久化
│
├── client/                  # Flutter 跨平台客户端
│   ├── lib/
│   │   ├── main.dart        # 客户端入口与全局路由
│   │   ├── screens/         # 页面（引导向导、聊天主屏、设置）
│   │   ├── services/        # WebSocket、音频、设置服务
│   │   └── theme/           # 现代化 UI 主题与色彩设计
│   └── pubspec.yaml         # Flutter 依赖配置
│
├── data/                    # 运行期数据（SQLite 数据库、上传缓存、人格 JSON）
├── start.py                 # 一键启动脚本
└── lumi-hub2.0plan.md       # 2.0 完整迭代计划
```

---

## 手机端连接桌面 Host

1. **ADB USB 调试**：
   ```bash
   adb forward tcp:8765 tcp:8765
   ```
   手机端连接地址填：`ws://127.0.0.1:8765`
2. **局域网连接**：
   确保手机与电脑在同一 Wi-Fi 下，手机端连接地址填：`ws://<电脑局域网IP>:8765`