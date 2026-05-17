# PROJECT_CONTEXT

## 这个项目是干什么的
这是 PulseType 的重构项目副本，目标是基于 OpenCLI 的技术思想与能力体系，重构现有语音输入法产品，让它具备更强的可扩展执行层（工具调用、浏览器/本地能力编排、可维护命令接口）。

该项目已建立独立 GitHub 仓库：
- https://github.com/niushuanan/pulsetype-opencli-rebuild

## 代码结构是什么
- `Sources/App/`：应用入口与运行时装配。
- `Sources/Core/`：核心能力层（语音、会话、工具、权限、V4 agent loop、memory、tool kernel）。
- `Sources/UI/`：控制中心与设置页 UI。
- `Sources/Resources/`：资源、Agent 提示、技能配置。
- `Tests/`：单元与场景测试。
- `docs/`：架构、产品、演进文档。
- `scripts/`：本地安装、诊断、测试与自动化脚本。

## 关键入口在哪里
- `PulseType.xcodeproj`：Xcode 工程入口。
- `Sources/App/PulseTypeApp.swift`：应用主入口。
- `Sources/Core/V4/AgentLoop/V4AgentLoopEngine.swift`：Agent 主循环。
- `Sources/Core/V4/ToolKernel/V4ToolKernel.swift`：工具执行内核。
- `Sources/Core/Interaction/InteractionCoordinator.swift`：交互协调核心。
- `Sources/UI/SettingsView.swift`：关键配置页入口。

## 最近改了什么
- 本次任务：为 PulseType 创建独立重构仓库与本地副本，作为“基于 OpenCLI 技术重构”的新起点。
- 改了哪些文件：
  - `PROJECT_CONTEXT.md`
  - `OPENCLI_REFACTOR_HANDOFF.md`（新建）
- 改了什么：
  - 新建并推送独立仓库 `niushuanan/pulsetype-opencli-rebuild`。
  - 在桌面创建新副本目录并导入现有 PulseType 代码。
  - 输出可直接开工的衔接上下文文档（目标、边界、切入点、里程碑）。
- 为什么这样改：
  - 把“新架构重构实验”从现有工作线隔离出来，降低风险并提升迭代速度。
- 影响了哪些模块：
  - 项目管理与版本管理层面；当前未改业务逻辑代码。
