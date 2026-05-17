import Foundation

enum SessionPhase: String, CaseIterable {
    case idle
    case listening
    case transcribing
    case textProcessing
    case inserting
    case cancelled
    case error

    var title: String {
        switch self {
        case .idle:
            return "待命"
        case .listening:
            return "听写中"
        case .transcribing:
            return "ASR 转写中"
        case .textProcessing:
            return "文字整理中"
        case .inserting:
            return "写入中"
        case .cancelled:
            return "已取消"
        case .error:
            return "异常"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle:
            return "waveform.circle"
        case .listening:
            return "waveform.circle.fill"
        case .transcribing:
            return "text.bubble"
        case .textProcessing:
            return "sparkles"
        case .inserting:
            return "arrow.down.doc"
        case .cancelled:
            return "slash.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}
