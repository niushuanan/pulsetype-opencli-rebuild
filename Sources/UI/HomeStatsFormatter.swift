import Foundation

enum HomeStatsFormatter {
    static func integerText(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func speedText(snapshot: HistoryLifetimeSnapshot) -> String {
        guard snapshot.speedSampleCount > 0 else {
            return "—"
        }
        let safe = max(0, Int(snapshot.averageCharactersPerMinute.rounded()))
        return "\(safe) 字/分"
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds > 0 else {
            return "0 秒"
        }

        let roundedSeconds = Int(seconds.rounded())
        if roundedSeconds < 60 {
            return "\(roundedSeconds) 秒"
        }

        let minutes = roundedSeconds / 60
        if minutes < 60 {
            let remainder = roundedSeconds % 60
            return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分"
    }
}
