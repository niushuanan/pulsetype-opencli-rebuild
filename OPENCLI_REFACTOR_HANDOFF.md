# PulseType x OpenCLI 重构衔接上下文

## 1. 这条新线要做什么
目标不是“把 PulseType 变成命令行工具”，而是把 PulseType 的执行层改造成：
- 上层：语音理解 + 意图规划（现有 V4 Agent Loop）
- 下层：标准化动作接口（参考 OpenCLI 的 adapter / command 思路）

一句话：
**让 PulseType 的“会想”与“会做”彻底解耦。**

## 2. 为什么现在就该拆新仓
- 老仓的目标是持续可用产品迭代，新重构会涉及执行层重排，风险高。
- 新仓可以大胆做架构升级，不阻塞现有版本。
- 未来可以按模块回迁（cherry-pick 或目录级迁移），可控合并。

## 3. 当前资产（你已经有）
- 完整 PulseType 代码副本（已提交到新仓 main）。
- 现有 V4 体系：`AgentLoop`、`ToolKernel`、`Memory`、`Prompt` 已成型。
- 与外部系统的工具接口基础也在（AppleScript、Shell、Mail、Notes、Calendar 等）。

## 4. 建议的重构主线（按优先级）

### 第一阶段：抽象统一命令层（先不改功能）
目标：让所有工具能力先挂到统一 command contract 上。
- 设计 `CommandSpec` / `CommandResult` / `CommandError` 统一协议。
- 给现有 `V4ToolKernel` 增加 adapter 注册层（像 OpenCLI 的 registry）。
- 先把已有工具做“壳适配”，行为不变。

### 第二阶段：引入“站点/应用适配器”模型
目标：让 PulseType 的动作能力可插拔、可发现。
- 本地目录约定（例如 `Adapters/<domain>/<action>.json|swift`）。
- 支持 metadata（能力描述、参数 schema、权限声明、超时策略）。
- 在 UI 或诊断面板里展示“当前可用能力清单”。

### 第三阶段：把语音意图映射到命令执行计划
目标：从“直接调工具”升级为“规划后执行”。
- 意图 -> 标准命令计划（可串行/并行、可重试、可回滚提示）。
- 执行证据（evidence）统一记录，提升可解释性与调试效率。

## 5. 建议你第一天先干的三件事
1. 先画出当前 `V4ToolKernel` 的调用链（从意图到工具落地）。
2. 定一个最小 command 协议草案，只做兼容封装，不改业务行为。
3. 选 2 个高频工具做 PoC（比如 `Shell` + `AppleScript`）。

## 6. 关键边界（避免踩坑）
- 不要一开始就大规模改 UI，先稳住执行层抽象。
- 不要把“浏览器自动化”绑死成唯一方向，OpenCLI 的核心是协议化，不是某个单一驱动。
- 每个阶段都保持可回退，避免一次性硬切。

## 7. 当前路径与远端
- 本地目录：`/Users/zhuanghongkai/Desktop/PulseType-OpenCLI-重构`
- 远端仓库：`https://github.com/niushuanan/pulsetype-opencli-rebuild`
- 当前分支：`main`
- 初始化提交：`d55e366`
