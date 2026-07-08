import Foundation
import AppKit
import LocalAuthentication

/// Gate sensitive actions (copy token, edit) behind macOS login password / Touch ID.
enum DeviceAuth {
    static func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            context.localizedReason = reason
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Returns an authenticated `LAContext` for Keychain items protected with `SecAccessControl`.
    static func authenticatedContext(reason: String) async -> LAContext? {
        let context = LAContext()
        context.localizedReason = reason
        let ok = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        return ok ? context : nil
    }

    static var unavailableMessage: String {
        "Turn on a Mac login password (System Settings → Users & Groups) to copy or edit stored tokens."
    }
}

enum PasteboardHelper {
    static func copy(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}
