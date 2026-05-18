# PROJECT_CONTEXT

## 这个项目是干什么的
PulseType 是一个 macOS 普通语音输入法。当前项目只保留一条主链：录音、ASR 语音识别、文字处理模型整理成稿、写入当前输入位置、保存普通听写历史。默认文本整理模型是 DeepSeek，但设置页允许改成 OpenAI、Anthropic 或其他 compatible gateway。

该项目仓库：
- https://github.com/niushuanan/pulsetype-opencli-rebuild

## 代码结构是什么
- `Sources/App/`：应用入口、运行时装配、菜单栏与窗口启动。
- `Sources/Core/Audio/`：录音与临时音频片段。
- `Sources/Core/Speech/`：ASR provider、文字处理模型配置、连接测试、凭据状态。
- `Sources/Core/TextProcessing/`：文字处理 provider、普通听写整理 prompt、流式文本生成。
- `Sources/Core/Interaction/`：普通听写链路协调，负责录音停止后串起 ASR、文字处理、写入、历史。
- `Sources/Core/Session/`：会话状态与界面状态文案。
- `Sources/Core/History/`：普通听写历史与统计。
- `Sources/Core/TextOutput/`：把最终文本写入目标应用。
- `Sources/Core/Permissions/`：麦克风和辅助功能权限。
- `Sources/Core/Hotkey/`：开始听写与取消会话快捷键，以及单键轻点/长按的状态机。
- `Sources/UI/`：控制中心、历史页、设置页、菜单栏状态、底部语音小条 HUD。
- `Tests/`：普通听写主链的单元测试与链路测试。
- `scripts/`：本地安装、诊断、发布脚本。

## 关键入口在哪里
- `PulseType.xcodeproj`：Xcode 工程入口，由 `project.yml` 生成。
- `Sources/App/PulseTypeApp.swift`：应用主入口。
- `Sources/App/AppModel.swift`：运行时依赖装配入口。
- `Sources/Core/Interaction/InteractionCoordinator.swift`：普通听写主链入口。
- `Sources/Core/Hotkey/GlobalHotkeyService.swift`：全局快捷键、单键长按与取消逻辑入口。
- `Sources/Core/Speech/ProviderSettingsStore.swift`：ASR 与文字处理模型配置入口。
- `Sources/Core/TextProcessing/DictationPostProcessor.swift`：文字整理 prompt 与结果处理入口。
- `Sources/UI/SettingsView.swift`：控制中心页面入口。
- `Sources/UI/StatusPulseHUDController.swift`：语音小条 HUD 入口。

## 最近改了什么
### 2026-05-18 12:30 - Clock 改为「受限 JSON + AppleScript 模板填参」，从通知提醒切到 Clock.app 路径

- 本次任务：把 `apple.clock.timer` 从“本地通知提醒”改为“Router 后二次模型提取 + AppleScript 模板执行”，并保持一次性闹钟语义。
- 改了哪些文件：
  - `Sources/Core/AgentClock/AgentClockTimerExecutor.swift`
  - `Tests/PulseTypeCoreTests.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - `LLMAgentClockParameterExtractor` 输出协议升级为受限 JSON：`action/title/fire_at/notes`，其中 `action` 强制收敛到 `create_one_shot_alarm`。
  - 新增并接入 `AppleScriptAgentClockRunner`：执行器不再直接调通知中心，而是把模型结果填入固定 AppleScript 模板，尝试在 `Clock.app` 里走“闹钟”页和新建流程。
  - `AgentClockTimerExecutor` 的执行结果改为脚本执行结果证据，历史里会记录 `action`、`fire_at`、`identifier`、`result`。
  - 删除旧的通知调度实现（`UNUserNotificationCenter` 路径），clock 工具职责收敛为模板化脚本执行。
  - 测试同步改造：把 `FakeAgentClockScheduler` 改为 `FakeAgentClockRunner`，并新增/更新 `clock` 用例覆盖脚本执行链路与路由结果。
- 为什么这样改：
  - 用户希望 clock 走“真实闹钟”路径，而不是只弹一条通知。
  - 架构上坚持“模型只出受限结构化参数，执行器负责模板填参和动作执行”，避免模型自由产出脚本导致不稳定。
- 影响了哪些模块：
  - Agent clock 参数协议、clock 执行器、Agent 历史证据结构、clock 相关测试桩与断言。

### 2026-05-18 12:05 - Router 软约束推理 + Calendar notes 补齐 + 新增 Clock 闹钟路径

- 本次任务：按 Agent 新规划完成三件事：Router 改为软约束推理、Calendar 自动补齐备注、新增 `clock` 工具完整路径（前后端 + 测试）。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Sources/Core/AgentCalendar/AgentCalendarExecutor.swift`
  - `Sources/Core/AgentClock/AgentClockTimerExecutor.swift`（新增）
  - `Sources/UI/SettingsView.swift`
  - `Tests/PulseTypeCoreTests.swift`
  - `PulseType.xcodeproj/project.pbxproj`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - Router prompt 从“硬规则字面匹配”升级为“软约束语义推理”：仍只输出 `tool_id`，但允许模型在 `clock/calendar` 交叉语义里做真实判断，不再像本地规则硬判断。
  - Agent 工具目录新增 `apple.clock.timer`，并增加对应能力开关 `agent.capability.clock.timer.enabled.v1`。
  - Calendar 参数提取器强化 `notes`：模型侧要求补一句简短备注；如果模型漏填，执行层会自动按“标题+原始口令”补齐，避免内容字段长期为空。
  - 新增 `AgentClockTimerExecutor`：
    - 先用 Agent 执行模型把“闹钟口令”提取成结构化 JSON（`title/fire_at/notes`）。
    - 再用本地通知中心（`UNUserNotificationCenter`）创建一次性闹钟提醒并写回证据（`apple.clock.timer|...`）。
    - 保持一次性路径，不追问、不确认。
  - `InteractionCoordinator` 新增 `clock` 分发分支，Router 选中后会调用 `agentClockExecutor`，并把路由证据 + 执行证据一起写历史/HUD。
  - Agent 页面新增“闹钟提醒”开关行，保持极简列表样式。
  - 测试新增 clock 全套覆盖：能力开关默认值、参数提取、执行器调度、Coordinator 路由到 clock。
  - 由于新增源码文件，重新生成了 Xcode 工程（`xcodegen generate`）。
- 为什么这样改：
  - Router 需要给模型推理空间，避免“偶尔命中关键词就误分流”的僵化问题。
  - Calendar 内容字段不能长期只有标题，notes 需要有可读上下文，便于后续复盘。
  - Clock 是高频动作，必须有独立执行器和可观测证据，且结构上要能复用到后续更多工具。
- 影响了哪些模块：
  - Agent 路由策略、Agent 工具目录与能力开关、Calendar 参数质量、Clock 新工具链路、Agent 页面 UI、核心测试集合。

### 2026-05-18 11:23 - Calendar 改为严格一次性执行，不追问缺失信息

- 本次任务：修正 Calendar 工具里“缺时间/标题可能失败或追问”的设计，改成一次性执行路径。
- 改了哪些文件：
  - `Sources/Core/AgentCalendar/AgentCalendarExecutor.swift`
  - `Tests/PulseTypeCoreTests.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 移除 Calendar 参数协议里的 `needs_confirmation` / `confirmation_question` 字段，工具不再支持“追问确认”分支。
  - Calendar prompt 改为强制模型一次性推理完整参数：缺标题就根据语义生成短标题，缺日期或时间就结合当前参考时间推理一个未来时间。
  - Swift 执行层不再因为标题为空直接失败；标题为空时用原始用户命令兜底。
  - Swift 执行层不再因为模型多返回确认字段而停止；即使模型错误返回确认字段，也会被忽略，继续走创建日程路径。
  - 增加稀疏模型输出兜底：如果模型仍然漏掉开始时间，使用参考时间后的下一个整点作为最后兜底，避免变成追问或缺字段失败。
  - 新增测试覆盖：模型返回确认字段也保持一次性路径；模型漏掉标题/开始时间也不会追问。
- 为什么这样改：
  - 用户要的是长按 Agent 后一次说完、一次执行，不要在 Calendar 这种高频动作里出现二次对话。
  - 模型应该负责理解自然语言中的隐含时间和标题，工具层只做安全兜底与执行。
- 影响了哪些模块：
  - Calendar 参数提取 prompt、Calendar 执行器失败分支、Agent 日程创建测试。

### 2026-05-18 11:20 - Agent 新增 Calendar 日程工具，只创建日历事件

- 本次任务：在现有 Agent Router 框架里新增 `apple.calendar.create_event` 工具，只做 Calendar 日程，不做 Reminder。
- 改了哪些文件：
  - `Sources/Core/AgentCalendar/AgentCalendarExecutor.swift`
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Sources/Core/Session/InputLane.swift`
  - `Sources/Core/Session/SessionStore.swift`
  - `Sources/UI/SettingsView.swift`
  - `Tests/PulseTypeCoreTests.swift`
  - `project.yml`
  - `PulseType.xcodeproj/project.pbxproj`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 新增 `AgentCalendarCreateEventExecutor`：工具内部先调用文字处理/Agent 执行模型，把自然语言日程口令标准化为 JSON 参数，再用 AppleScript 调用 Calendar 创建事件。
  - Calendar 参数提取 prompt 明确限制模型只输出 JSON，不输出 AppleScript、不解释；默认创建 Calendar 事件，不创建 Reminder；如果没有结束时间，默认 1 小时。
  - 新增 `AgentCalendarEventSpec` 与 AppleScript runner：在 Swift 侧校验标题、开始/结束时间、日历名、地点、备注、提前提醒分钟，再把确定参数传给 `osascript`。
  - `AgentToolCatalogStore` 增加内置 Calendar manifest，并将“音乐控制”和“日历日程”都写入 `Application Support/PulseType/AgentTools/<tool_id>/manifest.json`；Agent 页开关决定对应工具是否进入 Router 候选列表。
  - `InteractionCoordinator` 的 Agent 分发从只支持音乐，扩展为按 Router 返回的 `tool_id` 分发到音乐或 Calendar executor；历史证据会同时记录 `agent.route` 和具体工具证据。
  - Agent 页面保持极简：标题说明下面只有功能列表开关，新增“日历日程”一行，右侧使用 macOS 原生 switch。
  - 首页、历史、HUD 等文案从“Agent 音乐”调整为更通用的“Agent 执行”，避免和后续多工具能力冲突。
  - `project.yml` 更新 Apple Events 权限说明，包含 Apple Music 与 Calendar 等 Agent 功能；重新生成 Xcode 工程以纳入新增源码。
  - 新增测试覆盖 Calendar 能力开关、模型 JSON 参数解析、Calendar executor 组装事件并写证据、Router 分发到 Calendar executor。
- 为什么这样改：
  - Router 仍然只做分流，只输出 `tool_id`；Calendar 的时间标准化、字段校验、AppleScript 执行和结果证据都留在工具内部，职责边界清楚。
  - 日程创建比音乐播放更依赖时间理解，所以 Calendar 工具内部需要第二次模型调用，但输出必须被限制成稳定 JSON，不能让模型直接生成可执行脚本。
  - 前端只让用户看到“这个功能是否启用”，不暴露复杂路由和参数细节。
- 影响了哪些模块：
  - Agent Router 候选工具目录、Agent 执行分发、Calendar AppleScript 执行链路、Agent 页开关、首页/历史/HUD 文案、核心单测集合、应用自动化权限说明。

### 2026-05-18 10:24 - Agent 接入 LLM Router，只让路由决定 tool_id

- 本次任务：把 Agent 从“ASR 后直接执行音乐”改成“ASR 后先走 LLM Router，再按 `tool_id` 分发到工具执行器”，前端页面保持不变。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Sources/Core/Session/SessionStore.swift`
  - `Sources/Core/Storage/LocalStore.swift`
  - `Sources/App/AppModel.swift`
  - `Tests/PulseTypeCoreTests.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 新增 `AgentToolManifest`、`AgentToolCatalogStore`、`AgentRouteRequest`、`AgentRouteOutcome`、`LLMAgentToolRouter`。
  - `AgentToolCatalogStore` 会在 `Application Support/PulseType/AgentTools/apple.music.control/manifest.json` 准备内置音乐工具清单；当前 Agent 页的“音乐控制”开关只控制该工具是否进入 Router 候选列表。
  - `LLMAgentToolRouter` 使用文字处理/Agent 执行模型发起一次路由请求，只要求模型返回 `{"tool_id":"..."}`，不让 Router 生成参数、代码或执行步骤。
  - `InteractionCoordinator` 的 Agent 链路改为：ASR 原文 -> 加载已开启工具 -> LLM Router 选 `tool_id` -> 音乐 executor 继续处理原始命令 -> 写入 Agent 历史和证据。
  - `SessionStore` 增加 Agent 路由中的 HUD 文案，历史证据中同时记录 `agent.route` 和 `apple.music.control` 两段证据。
  - 新增测试覆盖 Router JSON 解析、Agent 路由后执行音乐、无可用工具时不调用 Router 并写失败历史。
- 为什么这样改：
  - 用户后续会加入浏览器、飞书、时钟等更多工具；Router 只负责分流，具体命令解析和执行仍留在各工具 executor 内，职责更清楚。
  - 前端的功能开关不应该变成“是否启用路由”，而应该表示“这个工具是否参与路由选择”。
- 影响了哪些模块：
  - Agent 底层分发链路、Agent 历史证据、运行时本地目录结构、测试覆盖。

### 2026-05-18 09:57 - Agent 播放路径提速（去掉队列重建/扫描）并清理证据重复字段

- 本次任务：针对“播放命令明显变慢”的反馈做提速优化，保持资料库顺序语义不变。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - `runPlay(query:)` 从“旋转队列复用/重建模式”改为“资料库直达播放模式”：
    - 保留资料库检索与顺序锚定语义（`selection_source=library|queue_anchor=library_order`）。
    - 移除每次播放时的队列扫描、队列完整性校验和可能的队列重建，减少大库下的额外耗时。
    - 保留短轮询稳态确认，只在确认进入 `playing` 后返回成功；否则带上 `target_matched_but_inactive` 或 `play_mismatch` 证据。
  - 证据拼接处增加去重：如果 AppleScript 回传里已经有 `requested_track=...`，上层不再重复追加。
- 为什么这样改：
  - 真实日志显示主要慢在 `asr.success -> agent.music.*` 阶段，典型 4s+，不是 ASR 慢。
  - 慢点来自播放工具层的“全库+队列”重操作；改成资料库直达可显著缩短执行时间，同时保留顺序控制能力。
- 影响了哪些模块：
  - Agent 音乐执行器 `play` 路径性能、执行证据可读性。

### 2026-05-18 09:50 - 播放确认逻辑下沉到 AppleScript，移除 Swift 临时补丁

- 本次任务：按真实触发链路修复“命中目标歌曲但被判失败”的问题，并避免在 Swift 层继续堆补丁。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - `runPlay(query:)` 的 `queue_reused=true` 分支从“单次 delay + 单次读状态”改为“最多 10 次短轮询确认播放态”，并在第 4 次尝试时补发一次 `play queueTrack`。
  - `queue_reused=false` 分支同步改成“只有 `state=playing/play` 才提前成功返回”；若只是命中目标但仍非播放态，继续轮询，不再过早返回。
  - 失败证据新增 `target_matched_but_inactive=true`，用于区分“没命中目标”和“命中目标但播放态没稳定”两类问题。
  - 移除了 Swift 执行层的 `runResume()` 临时补救路径，恢复为“执行层只解释结果，稳态确认由 AppleScript 一层完成”。
- 为什么这样改：
  - 根因是播放态读取时序抖动，最稳的修复点在 AppleScript 执行层，而不是在上层继续叠逻辑。
  - 统一在工具层完成确认后，代码职责更清晰，后续扩展路由和多工具也更容易维护。
- 影响了哪些模块：
  - Agent 音乐执行器 `play` 路径、播放态确认策略、失败证据结构。

### 2026-05-18 09:44 - 播放后误判失败修复（state=stopped 自动补救）

- 本次任务：修复 Agent 音乐播放里“已经选中目标歌曲，但历史仍报播放失败”的问题。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 在 `AgentMusicControlExecutor.execute(...)` 的 `play` 分支增加自动补救：当首轮执行回传 `state=stopped` 时，立即调用一次 `runResume()` 做恢复播放并再次读取状态。
  - 如果补救后状态进入 `playing/play`，则按成功返回；若仍非播放态，才保留失败判定。
  - 证据字段新增补救轨迹：`auto_resume=true/false`、`resume_state=...`，并在可用时补充 `resume_track`、`resume_artist`，方便历史页排障。
- 为什么这样改：
  - 之前播放校验是“单次瞬时状态判定”，在 Music 刚切歌但状态还没稳定时会误报失败。
  - 自动补救能覆盖这类时序抖动，保持“说播放就应尽量播放成功”的用户体验。
- 影响了哪些模块：
  - Agent 音乐执行器播放校验路径、历史证据可观测性。

### 2026-05-18 02:12 - Agent 页改成极简开关，并把开关接入真实执行门禁

- 本次任务：把 Agent 页面收敛成“标题说明 + 功能开关列表”，并确保开关不是纯展示，而是真正控制 Agent 音乐执行。
- 改了哪些文件：
  - `Sources/UI/SettingsView.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Tests/PulseTypeCoreTests.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - Agent 页移除原来的多卡片信息区，只保留一行“音乐控制”能力项，右侧使用 macOS 原生胶囊 `Toggle(.switch)`。
  - 新增 `AgentCapabilitySettings`（放在 `InteractionCoordinatorTypes.swift`）统一管理能力开关 key 与默认值策略（未设置时默认开启）。
  - 在 `executeAgentMusicCommand(...)` 入口增加能力门禁：当音乐控制关闭时，直接失败返回，并写入 Agent 历史与执行日志，避免“UI 关了但底层还在跑”。
  - 增加单测 `testAgentMusicCapabilityDefaultsToEnabledAndCanBeTurnedOff`，覆盖默认开启与关闭持久化场景。
- 为什么这样改：
  - 用户要的是干净、可读、接近系统设置风格的页面，而不是技术说明页。
  - 开关必须控制真实行为，否则会形成“看起来可控，实际上不可控”的体验落差。
- 影响了哪些模块：
  - Agent 页面 UI 信息架构、能力开关持久化、Agent 音乐执行入口、历史失败可观测性、核心测试集合。

### 2026-05-18 02:01 - 控制中心新增独立 Agent 页面（位于设置上方）

- 本次任务：在左侧列表中新增 `Agent` 入口，并提供一个面向用户的独立页面，为后续多能力扩展预留结构。
- 改了哪些文件：
  - `Sources/UI/ControlCenterState.swift`
  - `Sources/UI/SettingsView.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 左侧导航 `DesktopSection` 新增 `agent`，显示为“Agent”，位置在“设置”上方，图标使用 `sparkles`。
  - `SettingsView` 新增 `agentPage`，包含四块信息：当前入口（长按触发 + 一键跳转快捷键设置）、当前可用能力（音乐控制动作 + 语音示例）、最近执行（Agent 最近记录预览 + 跳转历史筛选）、后续能力（智能判断/多能力扩展/跨应用执行）。
  - 页面文案尽量用户化，隐藏底层实现细节，避免把模型和工具内部机制直接暴露给用户。
- 为什么这样改：
  - 用户明确需要“Agent 独立一层”，且未来会从单一音乐路径扩展到多工具路由，必须先把导航和页面骨架建立好。
  - 页面要先服务真实使用场景：看得懂、点得快、能复盘，而不是技术配置面板。
- 影响了哪些模块：
  - 控制中心左侧导航枚举、右侧详情页分发、Agent 信息展示与历史联动路径。

### 2026-05-18 01:48 - Agent “下一首/上一首”强制按资料库顺序执行

- 本次任务：修复“播放后说下一首仍会跳到非资料库预期歌曲”的问题。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 重写 `runNext()`：不再调用 `next track`，改为每次读取 `library playlist 1`，按当前曲目的 `persistent ID` 在资料库里定位索引，再显式播放“下一条”资料库曲目（末尾回绕到第一首）。
  - 重写 `runPrevious()`：同样按资料库索引显式播放“上一条”资料库曲目（首位回绕到最后一首）。
  - 两条路径都强制 `shuffle=false`、`song repeat=off`，并在证据里标注 `selection_source=library|queue_anchor=library_order|step=next/previous`。
- 为什么这样改：
  - 之前 `next track` 受 Music 当前上下文影响，可能被系统队列或上下文接管，导致结果偏离资料库顺序。
  - 显式按资料库索引选曲可以把行为固定下来，不依赖当前队列状态。
- 影响了哪些模块：
  - Agent 音乐执行器的 `next/previous` 路径、播放证据可观测性、资料库顺序一致性。

### 2026-05-18 01:41 - Agent 音乐执行失败修复（AppleScript 语法纠正 + 错误证据补齐）

- 本次任务：修复“执行失败”且历史只显示 `osascript_failed`、看不到真实错误的问题。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 删除 `runPlay(query:)` AppleScript 里的非法语句 `next repeat`（位于 `on error` 分支），避免脚本编译阶段直接失败。
  - `osascript` 失败时把 stderr 回传到证据字段 `osascript_stderr=...`，后续可直接在历史里看具体错误，不再是黑盒失败。
- 为什么这样改：
  - 这次失败的直接根因是脚本语法错误，导致命令未真正执行。
  - 没有 stderr 会让排障只能猜，补齐后能快速定位具体报错行。
- 影响了哪些模块：
  - Agent 音乐执行器 `play` 路径稳定性、失败证据可观测性、历史诊断效率。

### 2026-05-18 01:37 - Agent 音乐下一首乱跳修复（队列旋转锁定 + 匹配校验纠偏）

- 本次任务：修复“播放指定歌曲后，下一首会跳到陌生歌曲”的问题，并定位证据校验误判。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - `runPlay(query:)` 从“直接播放资料库单曲”改为“可复用的旋转队列播放列表”策略：先在资料库定位目标曲目，再优先复用 `PulseType Agent Library Queue`（曲目总数一致时），否则按目标曲目起点重建完整队列并播放。
  - 执行证据新增 `queue_mode=playlist_rotation`、`queue_reused=true/false`、`album` 等字段，便于判断是否命中复用路径和实际播放结果。
  - 修复 `exact_match` 误判：匹配校验只基于 `track/artist/album`，不再把 `requested_track` 和整段 evidence 文本拼进去，避免“播错歌却仍判定命中”。
- 为什么这样改：
  - 单纯 `play library playlist + play track` 不能稳定锁住后续队列，Music 仍可能按当前上下文跳转。
  - 旋转队列能把“下一首”固定在资料库顺序里，符合“先从资料库找到歌，再沿资料库继续播”的预期。
  - 校验误判会掩盖真实播放偏差，必须先修正才能让历史证据可信。
- 影响了哪些模块：
  - Agent 音乐执行器 AppleScript 播放策略、播放结果证据结构、命中验证逻辑、历史可观测性。

### 2026-05-18 01:27 - Agent 音乐链路增强（自动拉起 Music + 同键轻点/长按分流 + 资料库顺序锚定）

- 本次任务：按最新反馈修复三件事：Music 未打开时执行失败、开始键与 Agent 键不能复用、播放指定歌曲后下一首容易偏离资料库顺序。
- 改了哪些文件：
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Sources/Core/Hotkey/HotkeyStateStore.swift`
  - `Sources/Core/Hotkey/GlobalHotkeyService.swift`
  - `Sources/UI/SettingsView.swift`
  - `Tests/PulseTypeCoreTests.swift`
- 改了什么：
  - Agent 执行前新增 `ensureMusicAppRunning()`：如果 Music 没开就先拉起并短轮询确认运行，再继续执行 AppleScript。
  - 热键冲突规则调整为允许“开始/结束说话”和“开启Agent”使用同一个修饰键。
  - 新增“同键位模式”分流逻辑：同键位时，轻点只触发普通听写，长按只触发 Agent，避免互相抢占。
  - `runPlay(query:)` 改为资料库锚定播放：先在 `library playlist 1` 检索，再显式锚定到资料库队列并关闭 `shuffle`，同时在证据里回传 `selection_source=library`、`queue_anchor=library_order`。
  - 设置页提示文案补充“支持同一键位轻点/长按自动区分”。
  - 新增单测 `testHotkeyStoreAllowsWakeAndAgentUsingSameModifier`，防止后续回归。
- 为什么这样改：
  - 第一条是可用性问题：用户不应先手动打开 Music 才能用 Agent。
  - 第二条是交互效率问题：同一键位更符合语音场景的肌肉记忆。
  - 第三条是播放一致性问题：要优先保证“从资料库选歌并沿资料库顺序继续播放”。
- 影响了哪些模块：
  - Agent 音乐执行前置检查、AppleScript 播放策略、全局热键状态机、设置页快捷键提示、核心单测集合。

### 2026-05-18 01:08 - 新增独立 Agent 音乐层（长按触发 + 历史分栏 + Apple Music 快路径）

- 本次任务：在不接入 planner 的前提下，新增一层独立 Agent 功能，只做音乐控制，并保持现有普通听写链路不受影响。
- 改了哪些文件：
  - `Sources/Core/Session/InputLane.swift`
  - `Sources/Core/Session/SessionStore.swift`
  - `Sources/Core/Hotkey/HotkeyStateStore.swift`
  - `Sources/Core/Hotkey/GlobalHotkeyService.swift`
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Sources/Core/History/LocalHistoryStore.swift`
  - `Sources/UI/SettingsView.swift`
  - `Sources/UI/SettingsViewComponents.swift`
  - `Sources/UI/StatusPulseHUDController.swift`
  - `Sources/App/AppModel.swift`
  - `Tests/PulseTypeCoreTests.swift`
- 改了什么：
  - 新增 `agentMusic` lane，并把会话状态、HUD 标题、历史数据模型扩展为“普通听写 / Agent 调用”双模式。
  - 设置页快捷键新增“开启Agent”键位选择（长按触发）；模型卡标题改为“文字处理模型 / Agent 执行模型”。
  - 历史页新增“Agent 调用”筛选维度，卡片支持展示命令、结果与证据摘要。
  - 新增轻量 `apple.music.control` 执行器：ASR 转写后直接走 Music 命令解析 -> 固定 AppleScript 执行 -> 播放状态与匹配验证 -> 证据回传（含 `fast_path` 标记）。
  - 全局热键新增第二套独立长按状态机，支持“开始/结束说话”和“开启Agent”分别配置。
- 为什么这样改：
  - 目标是满足“独立一层、速度优先、只做音乐”的产品要求，避免把 Agent 能力和当前听写主链绑死在一起。
  - 通过固定工具执行 + 结果校验，可以在不引入复杂框架的情况下保证可用性与可追踪性。
- 影响了哪些模块：
  - 热键触发层、会话状态机、交互协调器、历史存储与历史 UI、首页/设置页文案与配置入口、HUD 展示层、核心单测覆盖。

### 2026-05-17 22:28 - 历史卡片移除 “ASR 原文：” 前缀

- 本次任务：按反馈去掉历史记录中原文行的标签字样。
- 改了哪些文件：`Sources/UI/SettingsViewComponents.swift`
- 改了什么：历史卡片中原文展示由 `ASR 原文：{text}` 改为仅展示 `{text}`，保留原有字体、颜色、可选中复制能力。
- 为什么这样改：标签字样在密集历史卡片里增加视觉噪音，用户明确要求隐藏。
- 影响了哪些模块：历史页记录卡片展示文案（不影响数据、复制逻辑与筛选逻辑）。

### 2026-05-17 22:13 - 首页补回产品介绍卡片并改成当前能力文案

- 本次任务：修复首页标题区空洞问题，复用旧版产品介绍卡片结构。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：在首页 `pageTitleText` 下方新增 `homeProductIntroCard`，沿用旧版“核心特点 + Label 列表”表现形式；文案按当前精简版能力重写，只保留单键触发、ASR+文本整理、模型配置、历史统计四点，不再出现魔术先生/时光机等旧能力描述。
- 为什么这样改：当前首页标题下方信息密度过低，视觉留白过大；旧版卡片结构成熟，可直接复用。
- 影响了哪些模块：首页 UI 结构与产品说明文案层（不影响功能链路）。

### 2026-05-17 22:07 - 空输入保存密钥逻辑修正

- 本次任务：修复“保存密钥”在空输入时的交互逻辑。
- 改了哪些文件：`Sources/Core/Speech/ProviderSettingsStore.swift`
- 改了什么：在 ASR/文字处理模型密钥保存入口增加分支：当输入框为空且系统已存在密钥时，不再报“API 密钥不能为空”，改为短提示“已存在，无需重复保存”；当输入为空且本地确实没有密钥时，仍保持“API 密钥不能为空”校验。
- 为什么这样改：原逻辑会把“空输入 + 已有密钥”的场景误判为错误，和用户直觉冲突。
- 影响了哪些模块：设置页密钥保存反馈逻辑（不影响模型请求与运行时调用）。

### 2026-05-17 21:51 - 模型卡片测试按钮降级并并入操作行

- 本次任务：修复“测试连接”按钮视觉突兀问题。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：把“测试连接”从单独一行蓝色主按钮改为和“保存密钥/删除密钥”同一行的次级按钮，保留 `测试中` 文案与禁用逻辑。
- 为什么这样改：主按钮单独悬空会破坏卡片操作层级，且和之前减少蓝色常驻状态的目标冲突。
- 影响了哪些模块：设置页模型配置卡片的操作区布局与按钮视觉层级。

### 2026-05-17 21:48 - 设置页模型配置反馈改为短暂轻提示

- 本次任务：调整设置页模型配置卡片的状态颜色与反馈显示方式，解决蓝色成功文案长期占据页面的问题。
- 改了哪些文件：`Sources/UI/SettingsView.swift`，`Sources/Core/Speech/ProviderSettingsStore.swift`
- 改了什么：不再按密钥 `saved` 状态常驻显示“密钥已保存”；保存/删除密钥后的反馈改为 3 秒短暂提示；连接测试结果改为 4 秒短暂提示，并清理旧版本持久化的测试结果；测试成功文案从蓝色改为次级正文色，避免和主按钮抢视觉焦点。
- 为什么这样改：模型配置页的蓝色应主要服务当前操作，不应长期停留在页面里；成功态常驻会让设置页显得像调试面板，也会让按钮和状态提示的层级混在一起。
- 影响了哪些模块：设置页模型配置 UI、密钥保存/删除反馈、连接测试结果展示、旧测试结果持久化清理。

### 2026-05-17 21:30 - 设置页快捷键与提示词语义修正，成功色改为系统蓝

- 本次任务：继续调整设置页：开始方式只保留单键触发；修改默认提示词，让语音输入结果更强调分行、分点、分段和结构感；移除难看的自定义绿色。
- 改了哪些文件：`Sources/UI/SettingsView.swift`，`Sources/Core/Speech/ProviderSettingsStore.swift`，`Sources/UI/ControlCenter/ControlCenterVisualSystem.swift`
- 改了什么：删除设置页“开始方式”选择行，进入设置页时强制开始/结束说话使用单键模式；把“单键”改成“开始/结束说话”，把“取消会话”改成“退出输入”，并把 Esc 显示成不可选择的系统设置风格值；默认文字处理提示词改成语音输入整理助手语义，强调自动分行、分点、分段和结构化输出；旧默认提示词会自动迁移到新版默认提示词；成功色从自定义绿色改为 macOS `systemBlue`。
- 为什么这样改：当前产品只需要单键触发，不应保留无意义的开始方式选择；语音输入后处理更需要结构化整理；原成功绿不是系统色，观感偏脏。
- 影响了哪些模块：设置页快捷键 UI、热键模式持久化、默认提示词与旧默认提示词迁移、全局成功态颜色。

### 2026-05-17 21:16 - 设置页颠覆式重构（仅保留三大核心能力）

- 本次任务：对设置页做整页重构，只保留快捷键、模型设置、自定义提示词三个核心能力，并清理 UI 噪音。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：重写设置页信息架构与区块层级；模型配置改为双卡并列（窄窗口自动换列）；删除冗余状态说明与长提示文本；测试结果改为紧凑单行反馈；快捷键区重排并修复“单键”标签重复显示。
- 为什么这样改：旧版设置页文本密度过高、主次不清、操作焦点分散，导致扫描效率差。
- 影响了哪些模块：设置页视觉结构、快捷键配置区交互、模型配置区反馈样式、提示词编辑区布局。

### 2026-05-17 21:07 - 历史卡片隐藏模型来源字段

- 本次任务：删除历史记录卡片中“模型来源 + 模型名”这一行展示字段。
- 改了哪些文件：`Sources/UI/SettingsViewComponents.swift`
- 改了什么：在 `HistoryRowView` 的底部信息行里移除 `textProcessingProvider` 与 `textProcessingModel` 的文本渲染，只保留应用名和操作按钮。
- 为什么这样改：该字段在当前历史页信息密度里属于冗余噪音，用户明确要求不展示。
- 影响了哪些模块：历史页记录卡片的元信息展示层（不影响数据记录与复制/删除功能）。

### 2026-05-17 21:02 - 按桌面旧代码恢复首页卡片文案与内部排版

- 本次任务：不再参考仓库历史版本，直接对照桌面旧代码恢复首页四卡文案和卡片内部结构。
- 改了哪些文件：`Sources/UI/SettingsView.swift`，`Sources/UI/SettingsViewComponents.swift`
- 改了什么：四张卡片文案改为旧代码版本（历史对话时长、历史输入字数、平均速度、总计节省时间及对应副标题）；卡片内部去掉右上图标行，恢复旧版文本三段式结构（标题、主值、说明），减少中段视觉空洞。
- 为什么这样改：用户明确要求参考桌面旧代码而不是当前仓库历史，且当前卡片中段留白和说明文案风格偏离旧版。
- 影响了哪些模块：首页统计卡片文案体系、卡片内容布局层级和信息密度。

### 2026-05-17 20:58 - 首页卡片压缩中部留白并恢复旧版说明文案风格

- 本次任务：减少首页四张卡片中部空白，并参考旧代码调整卡片内说明文案表现。
- 改了哪些文件：`Sources/UI/SettingsViewComponents.swift`，`Sources/UI/SettingsView.swift`
- 改了什么：卡片内纵向间距从 12 改为 8，去掉固定高度约束，避免中部被硬撑出留白；卡片底部灰字从 `tertiary` 提升为 `secondary` 可读性；“成稿字数”卡片说明文案恢复为旧版风格“DeepSeek 处理后的最终文本”。
- 为什么这样改：固定高度和偏淡说明文字会在当前窗口比例下让信息重心发散，读起来发空。
- 影响了哪些模块：首页统计卡片布局密度、次级文本对比度、卡片说明文案语义。

### 2026-05-17 22:40 - 设置页主操作按钮统一改成系统蓝底白字

- 本次任务：把设置页里核心操作按钮从灰底样式改成苹果风格的主操作样式（蓝底白字）。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：将「保存密钥」「删除密钥」「测试连接」「恢复默认提示词」按钮统一改用 `buttonStyle(.borderedProminent)` + `systemBlue` + 白色文字，并抽成 `settingsBlueActionButton()` 复用，替换原有次级灰色按钮样式。
- 为什么这样改：当前灰色按钮对主操作不够突出，且与左侧导航已使用的系统蓝风格不一致，视觉上显得杂和旧。
- 影响了哪些模块：设置页模型配置区、自定义提示词区的按钮视觉规范（不影响任何业务逻辑）。

### 2026-05-17 22:48 - 修复窗口失焦时按钮发白难读问题

- 本次任务：修复设置页在窗口失焦（切到其他 app）时，按钮文字和底色对比度过低、看起来“糊成一片”的问题。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：把设置页主按钮样式从系统默认 `borderedProminent` 切换为自定义 `SettingsPrimaryButtonStyle`，按 `isEnabled` 与 `controlActiveState` 区分四种状态：可用态保持蓝底白字，禁用态改为灰底深灰字，失焦时只做轻微降饱和，不再把文字冲淡成近白色。
- 为什么这样改：系统默认在“禁用 + 失焦”叠加下会明显降对比度，用户误认为颜色异常；自定义态能保留可读性，同时保持 macOS 风格。
- 影响了哪些模块：设置页模型配置区和提示词区按钮的跨状态视觉表现（不影响数据保存、测试连接和业务流程）。

### 2026-05-17 22:56 - 回退设置页按钮到原生系统样式

- 本次任务：按反馈去掉“自定义主按钮样式”，恢复更原生的 macOS 视觉。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：删除 `SettingsPrimaryButtonStyle`，`settingsBlueActionButton()` 改回系统 `borderedProminent + systemBlue`。
- 为什么这样改：自定义样式在当前页面观感偏重且不自然，和其他控件风格不一致。
- 影响了哪些模块：设置页按钮视觉（不影响任何业务逻辑）。

### 2026-05-17 23:02 - 设置页操作按钮对齐侧栏选中态配色

- 本次任务：把设置页操作按钮改成接近左侧目录选中项的底色和字色风格。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：`settingsBlueActionButton()` 改为自定义 `SettingsSidebarSelectionButtonStyle`，可用态使用 `controlAccentColor` 蓝色渐变 + 白字 + 12 圆角，禁用态使用低对比灰底与灰字，保留按压反馈。
- 为什么这样改：用户希望按钮与左侧目录选中态统一，不接受默认系统灰按钮和普通蓝按钮的观感差异。
- 影响了哪些模块：设置页模型配置区和提示词区按钮视觉表现（不影响保存密钥、删除密钥、测试连接与提示词恢复逻辑）。

### 2026-05-17 23:08 - 按钮颜色改为侧栏同源系统语义色

- 本次任务：按“1:1 模仿”要求，把设置页按钮颜色改为与侧栏选中态同源的系统色，而非手调蓝色。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：`SettingsSidebarSelectionButtonStyle` 不再使用 `controlAccentColor` 渐变，改为直接使用 `selectedContentBackgroundColor / unemphasizedSelectedContentBackgroundColor` 作为底色，文字使用 `alternateSelectedControlTextColor / labelColor`，并保留禁用态。
- 为什么这样改：要做到视觉一致，必须复用系统语义色，而不是“接近”的自定义配色。
- 影响了哪些模块：设置页按钮在激活窗口/非激活窗口下的配色一致性（不影响业务功能）。

### 2026-05-17 23:14 - 设置页按钮圆角回归项目统一规范

- 本次任务：修复设置页按钮圆角与整体 UI 风格不匹配的问题。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：将按钮背景和描边的圆角从硬编码 `12` 改为统一 token `PulseUI.Radius.compactCard`。
- 为什么这样改：减少按钮“单独一套圆角”的割裂感，让按钮和输入框、卡片细节保持一致的设计语言。
- 影响了哪些模块：设置页操作按钮视觉一致性（不影响功能逻辑）。

### 2026-05-17 23:22 - 设置页按钮高度再下调一档

- 本次任务：按反馈把设置页按钮高度进一步压低。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：`SettingsSidebarSelectionButtonStyle` 的垂直内边距由 `8` 调整为 `6`。
- 为什么这样改：当前按钮显得偏高，压缩高度后与列表、输入框比例更协调。
- 影响了哪些模块：设置页按钮纵向占用（不影响功能逻辑）。

### 2026-05-17 23:28 - 设置页按钮高度继续下调到 5

- 本次任务：继续压低按钮高度，按最新反馈改到 5。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：`SettingsSidebarSelectionButtonStyle` 的垂直内边距由 `6` 调整为 `5`。
- 为什么这样改：进一步减少按钮高度，让模型配置区纵向节奏更紧凑。
- 影响了哪些模块：设置页按钮高度（不影响功能逻辑）。

### 2026-05-17 23:34 - 首页标题与副标题文案更新

- 本次任务：按反馈将首页顶部主文案改为“首页”，并替换副标题为一句产品介绍。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：首页 `pageTitleText` 的标题从“语音输入概览”改成“首页”；副标题改为“单键开口即写，ASR 转写与智能整理无缝衔接，语音内容可直接成为可用成稿。”
- 为什么这样改：让首屏信息结构更直观，减少“概览”这种中性标题，直接强化产品定位。
- 影响了哪些模块：首页头部文案展示（不影响业务逻辑）。

### 2026-05-17 23:40 - 设置页三处标题改为常规字重

- 本次任务：把用户圈出的三处标题统一改成常规字重。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：将「开始/结束说话」「退出输入」以及模型卡片标题（如「语音识别 ASR」「文字处理模型」）从 `PulseUI.Typography.bodyStrong` 调整为 `PulseUI.Typography.body`。
- 为什么这样改：当前字重偏粗，视觉压迫感偏强，和页面其它正文层级不协调。
- 影响了哪些模块：设置页文案层级与可读性（不影响功能逻辑）。

### 2026-05-17 23:48 - 模型设置区域固定为单列布局

- 本次任务：修复窗口拉宽后模型配置区自动变成两列的问题。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：将模型设置区域从 `LazyVGrid(.adaptive...)` 改为 `VStack` 单列布局，保持「语音识别 ASR」「文字处理模型」始终纵向堆叠。
- 为什么这样改：该区域是配置表单，不是信息卡片看板；单列更符合设置页认知和操作流。
- 影响了哪些模块：设置页模型配置区响应式布局行为（不影响保存/删除密钥与连接测试逻辑）。

### 2026-05-17 20:50 - 首页卡片高度按指定值压到 84

- 本次任务：按反馈把首页统计卡片高度直接压到指定数值 84。
- 改了哪些文件：`Sources/UI/SettingsViewComponents.swift`
- 改了什么：`HomeMetricCard` 的固定高度从 168 调整为 84。
- 为什么这样改：上一版在窄窗口下卡片留白仍偏大，本次按明确指定值直接收紧。
- 影响了哪些模块：首页概览卡片视觉密度与垂直占用。

### 2026-05-17 20:46 - 首页统计卡片改为自适应网格并统一尺寸

- 本次任务：修复窗口缩小时首页四张统计卡片大小不一致、且不能自动换行的问题。
- 改了哪些文件：`Sources/UI/SettingsView.swift`，`Sources/UI/SettingsViewComponents.swift`，`Sources/App/PulseTypeApp.swift`
- 改了什么：把首页指标网格从固定 4 列改为 `adaptive` 列（最小 220，最大 360），窗口变窄时自动从 4 列降到 2 列/1 列；给 `HomeMetricCard` 增加统一最小高度（230）保证四张卡片等高；下调控制中心窗口最小尺寸约束为 `760 x 560`，允许继续缩小并触发布局重排。
- 为什么这样改：固定四列会把最小窗口宽度顶住，同时卡片文案换行会导致高度不一致，影响可读性和整体质感。
- 影响了哪些模块：首页概览布局、卡片尺寸策略、控制中心窗口最小尺寸策略。

### 2026-05-17 20:30 - 历史页筛选栏左对齐并去掉大气泡容器

- 本次任务：按历史页视觉反馈调整筛选栏排版，去掉顶部大气泡背景。
- 改了哪些文件：`Sources/UI/SettingsView.swift`
- 改了什么：保留「全部 / 普通听写 / 失败」和「清空历史」原有功能，把它们所在行从 `controlCenterSectionGroup` 容器中移出，删除这层圆角浅色大背景；筛选控件保持左侧位置，不再被整条大气泡包裹。
- 为什么这样改：当前历史页顶部筛选区域视觉重心偏中且容器过重，和用户期望的“靠左、简洁”不一致。
- 影响了哪些模块：历史页 UI 布局与视觉层级（不影响历史筛选、清空历史和数据逻辑）。

### 2026-05-17 20:06 - 普通听写热键主链与语音小条完整修复

- 本次任务：把普通听写保留链路里退化掉的长按热键、语音小条和取消逻辑一次补齐。
- 改了哪些文件：`Sources/Core/Hotkey/GlobalHotkeyService.swift`，`Sources/Core/Hotkey/HotkeyStateStore.swift`，`Sources/Core/Interaction/InteractionCoordinator.swift`，`Sources/App/AppModel.swift`，`Sources/UI/StatusPulseHUDController.swift`，`Sources/UI/SettingsView.swift`，`Sources/UI/MenuBarMenuView.swift`，`Tests/GlobalHotkeyStateMachineTests.swift`，`Tests/HUDProgressStateMachineTests.swift`，`Tests/PulseTypeCoreTests.swift`，`PulseType.xcodeproj/project.pbxproj`
- 改了什么：恢复单键轻点与长按并存的热键语义，长按开始录音、松开自动结束；补回底部浮层语音小条，重新显示音量条、处理中进度、完成态、取消态和失败态；补上 `flagsChanged` 丢失左右修饰键 keyCode 时的回退逻辑；把 `Esc` 的取消范围限制在真正可取消的阶段，避免重复写入“已取消”历史；首页和设置页文案同步改成符合真实交互；新增热键状态机与 HUD 状态机测试。
- 为什么这样改：当前精简版虽然保住了 ASR 到文字处理主链，但把最核心的交互体验删坏了，导致按住说话、松手停止、底部语音小条这些普通听写主能力都不再成立，同时取消逻辑还会污染历史记录。
- 影响了哪些模块：全局热键、会话取消规则、AppModel 运行时绑定、浮层 HUD、首页与设置页文案、菜单栏交互、单元测试与工程文件。

### 2026-05-17 19:40 - 历史页与设置页进一步精简

- 本次任务：继续清理历史页和设置页，只保留普通听写需要的配置与说明。
- 改了哪些文件：`Sources/UI/SettingsView.swift`，`Sources/Core/Speech/ProviderSettingsStore.swift`，`Sources/Core/Speech/SpeechProvider.swift`，`Sources/Core/Speech/OpenAIEndpointResolver.swift`，`Sources/Core/Speech/SpeechConnectionTesters.swift`，`Sources/Core/TextProcessing/OpenAITextGenerationProvider.swift`，`Sources/Core/TextProcessing/DictationPostProcessor.swift`，`Sources/Core/Interaction/InteractionCoordinator.swift`，`Sources/Core/Session/SessionPhase.swift`，`Sources/Core/Session/SessionStore.swift`，`Sources/Core/Session/InputLane.swift`，`Sources/Core/Diagnostics/DiagnosticsCenter.swift`，`Sources/App/AppModel.swift`，`Sources/Core/Context/AppScenePolicyStore.swift`，`PulseType.xcodeproj/project.pbxproj`，`project.yml`，`README.md`，`Tests/PulseTypeCoreTests.swift`
- 改了什么：历史页顶部去掉“筛选”字样；设置页删掉“当前应用处理要求”和“数据”区，只保留快捷键、ASR、文字处理模型；模型配置统一成 `Base URL + API key + 模型名`；文字处理模型新增前端可直接编辑并即时生效的全局提示词；文本模型接入补上 Anthropic messages 接口；旧的 per-app prompt store 整个删除。
- 为什么这样改：让普通听写的配置面更直接，避免继续保留已经不需要的 per-app 策略和本地数据管理入口；同时把文本模型接口抽成更通用的 URL 驱动方式，便于兼容更多 provider。
- 影响了哪些模块：历史页 UI、设置页 UI、文本模型配置持久化、听写后处理主链、文本模型连接测试、工程文件、项目说明与测试。

### 2026-05-17 17:52 - 首页信息架构调整

- 本次任务：按反馈简化首页，只展示语音输入成果数据，不再放操作按钮和权限说明。
- 改了哪些文件：`Sources/UI/SettingsView.swift`，`Sources/UI/SettingsViewComponents.swift`，`Sources/UI/HomeStatsFormatter.swift`，`Sources/Core/History/LocalHistoryStore.swift`，`Tests/PulseTypeCoreTests.swift`
- 改了什么：首页删除主操作卡片和权限区；四张数据卡改为累计语音、成稿字数、语音速度、少打键盘，并固定为四列展示；统计公式改为按中文手打 80 字/分钟估算少打键盘时间；平均速度和少打键盘时间只使用带录音时长的成功记录。
- 为什么这样改：首页只需要回答“这个输入法帮我产出了什么”，启动和取消交给快捷键，权限问题不再占用首页空间；统计口径用更贴近中文输入的手打基准，避免数字长期显示 0。
- 影响了哪些模块：首页 UI、历史统计、首页数字格式化、普通听写核心测试。

- 本次任务：把项目重构成只保留普通语音输入的版本。
- 改了哪些文件：
  - `Sources/App/AppModel.swift`
  - `Sources/Core/Audio/`
  - `Sources/Core/Context/`
  - `Sources/Core/Diagnostics/`
  - `Sources/Core/History/`
  - `Sources/Core/Hotkey/`
  - `Sources/Core/Interaction/`
  - `Sources/Core/Session/`
  - `Sources/Core/Speech/`
  - `Sources/Core/Storage/`
  - `Sources/Core/TextProcessing/`
  - `Sources/Core/TextOutput/`
  - `Sources/UI/`
  - `Tests/PulseTypeCoreTests.swift`
  - `project.yml`
  - `README.md`
  - `scripts/doctor-runtime.sh`
- 改了什么：
  - 删掉高级自动化、工具调用、旧资源、旧测试和旧文档，只保留普通听写主链。
  - ASR 保留 OpenAI 兼容接口和阿里云 Qwen ASR；默认文本整理 provider 为 DeepSeek。
  - 历史页只展示普通听写记录，旧类型记录在读取时直接跳过。
  - 控制中心只保留首页、历史、设置三页。
  - 设置页合并 ASR 与文本模型参数，不再有单独引擎页。
  - 新增普通听写主链测试，覆盖配置、历史过滤、会话状态、流式稳定前缀、ASR 到文字整理再到写入历史。
- 为什么这样改：
  - 让产品形态回到最清楚的语音输入场景，减少无关能力造成的复杂度和维护风险。
- 影响了哪些模块：
  - 运行时装配、会话状态、ASR 配置、文本处理、历史、控制中心 UI、快捷键、项目配置、测试体系。
