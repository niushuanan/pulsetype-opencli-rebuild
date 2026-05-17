import Foundation

enum InputLane: String {
    case directDictation
    case agentMusic

    var title: String {
        switch self {
        case .directDictation:
            return "普通听写"
        case .agentMusic:
            return "Agent 音乐"
        }
    }

    var summary: String {
        switch self {
        case .directDictation:
            return "说话后由 ASR 转写，再交给文字模型整理，最后写入当前输入位置。"
        case .agentMusic:
            return "长按 Agent 键说出音乐指令，ASR 转写后直接调用 Music 控制链路。"
        }
    }

    var listeningStatusMessage: String {
        switch self {
        case .directDictation:
            return "正在听写，完成后会自动交给文字模型整理。"
        case .agentMusic:
            return "正在监听 Agent 指令，松开按键后会执行音乐控制。"
        }
    }
}
