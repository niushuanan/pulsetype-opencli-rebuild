# PROJECT_CONTEXT

## 这个项目是干什么的
PulseType 是一个 macOS 普通语音输入法。当前项目只保留一条主链：录音、ASR 语音识别、DeepSeek 文本整理、写入当前输入位置、保存普通听写历史。

该项目仓库：
- https://github.com/niushuanan/pulsetype-opencli-rebuild

## 代码结构是什么
- `Sources/App/`：应用入口、运行时装配、菜单栏与窗口启动。
- `Sources/Core/Audio/`：录音与临时音频片段。
- `Sources/Core/Speech/`：ASR provider、DeepSeek 配置、连接测试、凭据状态。
- `Sources/Core/TextProcessing/`：DeepSeek 文本整理 provider、普通听写整理 prompt、流式文本生成。
- `Sources/Core/Interaction/`：普通听写链路协调，负责录音停止后串起 ASR、DeepSeek、写入、历史。
- `Sources/Core/Session/`：会话状态与界面状态文案。
- `Sources/Core/History/`：普通听写历史与统计。
- `Sources/Core/TextOutput/`：把最终文本写入目标应用。
- `Sources/Core/Permissions/`：麦克风和辅助功能权限。
- `Sources/Core/Hotkey/`：开始听写与取消会话快捷键。
- `Sources/UI/`：控制中心、历史页、设置页、菜单栏状态。
- `Tests/`：普通听写主链的单元测试与链路测试。
- `scripts/`：本地安装、诊断、发布脚本。

## 关键入口在哪里
- `PulseType.xcodeproj`：Xcode 工程入口，由 `project.yml` 生成。
- `Sources/App/PulseTypeApp.swift`：应用主入口。
- `Sources/App/AppModel.swift`：运行时依赖装配入口。
- `Sources/Core/Interaction/InteractionCoordinator.swift`：普通听写主链入口。
- `Sources/Core/Speech/ProviderSettingsStore.swift`：ASR 与 DeepSeek 配置入口。
- `Sources/Core/TextProcessing/DictationPostProcessor.swift`：DeepSeek 文本整理 prompt 与结果处理入口。
- `Sources/UI/SettingsView.swift`：控制中心页面入口。

## 最近改了什么
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
  - ASR 保留 OpenAI 兼容接口和阿里云 Qwen ASR；DeepSeek 作为文本整理 provider。
  - 历史页只展示普通听写记录，旧类型记录在读取时直接跳过。
  - 控制中心只保留首页、历史、设置三页。
  - 设置页合并 ASR 与 DeepSeek 参数，不再有单独引擎页。
  - 新增普通听写主链测试，覆盖配置、历史过滤、会话状态、流式稳定前缀、ASR 到 DeepSeek 到写入历史。
- 为什么这样改：
  - 让产品形态回到最清楚的语音输入场景，减少无关能力造成的复杂度和维护风险。
- 影响了哪些模块：
  - 运行时装配、会话状态、ASR 配置、DeepSeek 文本处理、历史、控制中心 UI、快捷键、项目配置、测试体系。
