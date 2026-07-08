import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.slackagentbridge.app", category: "app")
    private static var debugEnabled: Bool {
        ProcessInfo.processInfo.environment["SLACKAGENT_DEBUG"] == "1"
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        guard debugEnabled else { return }
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
