# 🌟 Lumi-Hub: 跨平台私有化 Agent 交互终端与独立运行环境

Lumi-Hub 是专为大模型 Agent 打造的私有化、跨平台桌面/移动端交互枢纽。2.0 版本已全面脱钩第三方框架，内置**完全独立的 Python Agent Runtime**，并提供多任务并行、Skill 工作流、长短期记忆、**离线 Live2D 拟人化双形态展台与桌面桌宠挂件**能力。

[![GitHub](https://img.shields.io/badge/GitHub-Lumivers%2FLumi--Hub-blue?logo=github)](https://github.com/Lumivers/Lumi-Hub)
[![Flutter](https://img.shields.io/badge/Flutter-v3.29+-02569B?logo=flutter)](https://flutter.dev)
[![Python](https://img.shields.io/badge/Python-3.11+-3776AB?logo=python)](https://python.org)
[![Live2D](https://img.shields.io/badge/Live2D-Cubism%203%2F4-FF6F61)](https://www.live2d.com)

---

## 🚀 2.0 核心架构与重磅特性

### 1. 🎭 离线 Live2D 拟人化双形态交互 (Desktop Pet Companion)
- **主工作台内嵌展台**：一键在主界面右侧展开 320px 角色展台，支持精准鼠标视线追踪、TTS 语音张合同步（LipSync）。
- **独立桌面桌宠挂件（Firefly 风格）**：
  - **真·无边框桌面形态**：一键切换为 320x500 的纯净透明桌面立绘，无任何 Windows 边框遮挡，全域可直接拖拽移动。
  - **斜侧灵动问候语**：内置日常打招呼语库（多句随机轮播），点击小人身体弹出并在 **5 秒后优雅自动淡出**。
  - **右上角独立弹出式深色卡片**：点击小人身体呼出深色毛玻璃对话卡片，随叫随到，再次点击小人或 `✕` 键即可一秒收起。
  - **滚轮顺畅浏览与自动滚屏**：对话列表支持鼠标滚轮上下自由滑动查看完整 Markdown 与代码块，打字机流式输出时自动平滑向下跟随。
- **全离线化自托管**：PixiJS v6 与 Cubism 3/4 引擎及角色资产完全本地托管，无外部 CDN 依赖。

### 2. 🧠 独立 Agent Runtime (`host/`)
- **纯 Python 独立运行**：基于 asyncio + WebSocket，无需依赖外部机器人或第三方桥接框架。
- **ReAct 决策与工具循环**：自主推理与工具调用，支持高危文件/系统操作前端实时授权审批。
- **多 Provider 大模型接入**：统一 Provider 抽象，原生支持 OpenAI（及兼容接口）、Anthropic Claude、DeepSeek 以及本地 Ollama。
- **MCP (Model Context Protocol) 标准协议**：无缝连接外部 Stdio MCP Server（如 Notion、Filesystem、GitHub 等）。
- **智能长短期记忆系统**：支持自动对话偏好/事实提取与多轮上下文检索注入。
- **Skill 技能工作流**：支持加载结构化提示词工作流模板（如代码审查、日常总结等）。

### 3. 💻 现代化客户端与极简 UI (`client/`)
- **全新精简侧边栏**：顶部收纳 **`[🧠 记忆档案]`** 与 **`[⚡ 技能中心]`** 双胶囊入口，告别臃肿堆叠。
- **四合一统一设置中心**：左下角一键呼出集成化设置弹窗，涵盖 **常规设置**、**LLM 模型**、**MCP 服务** 与 **资源包管理**。
- **3 步引导向导**：AI 服务商配置 → 账号创建 → 多端连接模式，无需看文档 2 分钟上手。
- **多端互联**：电脑作为主机（Host），手机/平板通过无线局域网或 USB ADB 调试连接控制。
- **系统托盘与常驻**：支持最小化至系统托盘，全局快捷键随叫随到。

---

## 📦 快速开始

### 方式一：一键启动（推荐）

在项目根目录下执行一键启动脚本，将同时拉起 Python Host 后端与 Flutter 客户端：

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

## 🧪 功能测试与验收

详细的端到端测试用例、Live2D 交互手册与排查指南，请参阅：
👉 **[Lumi-Hub 2.0 测试与功能手册](docs/LUMI_HUB_TESTING_AND_COMPANION_MANUAL.md)**

快速静态代码校验命令：
```powershell
# 客户端代码校验
cd client && flutter analyze

# 后端语法校验
python -m py_compile host/ws_server.py host/agent_loop.py host/main.py
```

---

## 📂 项目结构

```text
Lumi-Hub/
├── host/                    # Python 独立 Agent Runtime
│   ├── main.py              # Host 入口（WebSocket / HTTP 静态资源双协议调度）
│   ├── ws_server.py         # WebSocket 协议服务端 & Live2D 静态 HTTP 分流
│   ├── agent_loop.py        # ReAct Agent 运行时循环
│   ├── tool_registry.py     # 原生工具与 MCP 工具统一注册中心
│   ├── persona_manager.py   # 人格与 Prompt 状态管理
│   ├── memory_manager.py    # 记忆提取与检索系统
│   ├── skill_manager.py     # Skill 工作流模板管理
│   ├── llm/                 # OpenAI / Anthropic / Ollama Provider 实现
│   └── database/            # SQLite 用户、会话、记忆持久化
│
├── client/                  # Flutter 跨平台客户端
│   ├── assets/live2d/       # 离线 PixiJS + Cubism 核心库与模型资产包
│   ├── lib/
│   │   ├── main.dart        # 客户端入口 (无边框透明窗口初始化)
│   │   ├── widgets/         # Live2dView 等通用渲染组件
│   │   ├── screens/         # 页面 (桌宠伴侣、聊天主屏、设置中心、记忆与技能弹窗)
│   │   ├── services/        # WebSocket、音频、设置服务
│   │   └── theme/           # 现代化 UI 主题与色彩设计
│   └── pubspec.yaml         # Flutter 依赖配置
│
├── data/                    # 运行期数据 (SQLite 数据库、上传缓存、人格 JSON)
├── docs/                    # 开发与测试文档库
├── start.py                 # 一键启动脚本
└── readme.md                # 项目主说明文档
```

---

## 📱 手机端连接桌面 Host

1. **ADB USB 调试**：
   ```bash
   adb forward tcp:8765 tcp:8765
   ```
   手机端连接地址填：`ws://127.0.0.1:8765`
2. **局域网无线连接**：
   确保手机与电脑在同一 Wi-Fi 下，手机端连接地址填：`ws://<电脑局域网IP>:8765`