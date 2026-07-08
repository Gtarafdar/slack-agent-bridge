import SwiftUI

/// In-app copy for macOS Keychain prompts so users know to choose Always Allow.
enum KeychainGuidance {
  static let alwaysAllowTitle = "macOS Keychain prompt"

  static let alwaysAllowBody = """
  The first time you connect (or after an app update), macOS may ask whether \
  “Slack Agent Bridge” can access Keychain data — often labeled “Slack Safe Storage.”

  Click Always Allow.

  That saves permission on this Mac only and stops the prompt from coming back on \
  every connect, refresh, or MCP tool call. It does not send your Slack password or \
  tokens to anyone; it unlocks data Slack already stored locally.

  If you clicked Deny by mistake: open Keychain Access → search “Slack” → delete old \
  “Slack Agent Bridge” entries, then connect again and choose Always Allow.
  """

  static let tokenCopyBody = """
  Copying a saved agent token uses your Mac login password (Touch ID works). \
  That unlocks the token on this device only — nothing is uploaded.
  """
}

struct KeychainAlwaysAllowNote: View {
  var compact: Bool = false

  var body: some View {
    GroupBox(KeychainGuidance.alwaysAllowTitle) {
      VStack(alignment: .leading, spacing: 6) {
        if compact {
          Text("If macOS asks to access Keychain (e.g. “Slack Safe Storage”), click Always Allow so you are not prompted again on every connect or MCP call.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(KeychainGuidance.alwaysAllowBody)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
  }
}
