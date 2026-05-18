import Foundation

enum InputLane: String {
    case directDictation
    case agentMusic

    var title: String {
        switch self {
        case .directDictation:
            return "普通听写"
        case .agentMusic:
            return "Agent"
        }
    }

    var summary: String {
        switch self {
        case .directDictation:
            return "说话后由 ASR 转写，再交给文字模型整理，最后写入当前输入位置。"
        case .agentMusic:
            return "长按 Agent 键说出指令，ASR 转写后交给 Agent 路由选择对应功能执行。"
        }
    }

    var listeningStatusMessage: String {
        switch self {
        case .directDictation:
            return "正在听写，完成后会自动交给文字模型整理。"
        case .agentMusic:
            return "正在监听 Agent 指令，松开按键后会判断并执行对应功能。"
        }
    }
}
