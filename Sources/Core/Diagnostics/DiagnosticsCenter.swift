import Foundation

struct DiagnosticsCenter {
    let appVersion: String
    let buildNumber: String

    init(bundle: Bundle = .main) {
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1"
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "4"
    }

    func summaryLines() -> [String] {
        [
            "Version \(appVersion) (\(buildNumber))",
            "普通听写：ASR -> DeepSeek -> 写入",
            "本地历史与诊断日志"
        ]
    }
}
