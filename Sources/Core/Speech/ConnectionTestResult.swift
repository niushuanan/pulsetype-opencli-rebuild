import Foundation

enum ConnectionTestStatus: String, Equatable, Codable {
    case success
    case failure
}

struct ConnectionTestResult: Equatable, Codable {
    let status: ConnectionTestStatus
    let message: String
    let hint: String
    let timestamp: Date
    let httpStatus: Int?

    static func success(
        message: String,
        hint: String = "配置可用。",
        httpStatus: Int? = 200
    ) -> ConnectionTestResult {
        ConnectionTestResult(
            status: .success,
            message: message,
            hint: hint,
            timestamp: Date(),
            httpStatus: httpStatus
        )
    }

    static func failure(
        message: String,
        hint: String,
        httpStatus: Int? = nil
    ) -> ConnectionTestResult {
        ConnectionTestResult(
            status: .failure,
            message: message,
            hint: hint,
            timestamp: Date(),
            httpStatus: httpStatus
        )
    }
}
