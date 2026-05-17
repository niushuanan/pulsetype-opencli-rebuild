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
