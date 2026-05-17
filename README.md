# PulseType

PulseType 是一个 macOS 普通语音输入法。

当前版本只保留一条主链：

1. 录音。
2. ASR 语音识别。
3. DeepSeek 文本整理。
4. 写入当前输入位置，失败时提示用户。
5. 在历史里保存普通听写结果。

## 功能范围

保留：

- 普通听写。
- ASR 服务设置。
- DeepSeek 文本整理设置。
- 麦克风与辅助功能权限检查。
- 普通听写历史。
- 菜单栏启动、停止、取消。

## 本地开发

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -configuration Debug build
```

安装到 `/Applications/PulseType.app`：

```bash
scripts/install-local-app.sh
```
