import Foundation
import OSLog

/// Unified logging policy shared with the Zig library through the C API.
enum BobrvmLogging {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.bobrvm.app"

    static let debugEnabled = bobrvm_log_enabled(BOBRVM_LOG_LEVEL_DEBUG)
    static let infoEnabled = bobrvm_log_enabled(BOBRVM_LOG_LEVEL_INFO)
    static let warningEnabled = bobrvm_log_enabled(BOBRVM_LOG_LEVEL_WARNING)

    static func logger(for type: Any.Type) -> Logger {
        Logger(subsystem: subsystem, category: String(describing: type))
    }
}
