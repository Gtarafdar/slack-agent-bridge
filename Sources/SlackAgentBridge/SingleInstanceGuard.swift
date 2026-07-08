import AppKit
import Foundation

/// Prevents two menu-bar instances (which can fight over MCP port 47821).
enum SingleInstanceGuard {
    private static var lockFD: Int32 = -1

    @discardableResult
    static func enforce() -> Bool {
        if acquireFileLock() { return true }

        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != current && $0.processIdentifier != current.processIdentifier && !$0.isTerminated }

        others.first?.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

        let alert = NSAlert()
        alert.messageText = "Slack Agent Bridge is already running"
        alert.informativeText = """
        Only one instance should run at a time. The existing app was brought to the front.

        If you still see two copies in Activity Monitor, quit all “SlackAgentBridge” processes, \
        then open only /Applications/Slack Agent Bridge.app.
        """
        alert.alertStyle = .informational
        alert.runModal()
        return false
    }

    private static func acquireFileLock() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlackAgentBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockURL = dir.appendingPathComponent("singleton.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }
}
