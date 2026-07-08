import Foundation
import LocalAuthentication
import Security

/// A single Slack workspace the user is signed into (via the Slack desktop app).
/// All workspaces share the same `d` cookie; each has its own `xoxc` token.
struct SlackWorkspace: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String?
    var token: String
}

/// The full local Slack session: one shared cookie + all detected workspaces.
struct SlackAccount: Codable, Equatable {
    var cookieHeader: String
    var workspaces: [SlackWorkspace]
}

enum KeychainStore {
    private static let service = "com.slackagentbridge.session"
    private static let account = "slack-credentials"
    private static let lock = NSLock()
    private static var memoryAccount: SlackAccount?

    @discardableResult
    static func save(_ slackAccount: SlackAccount) -> Bool {
        lock.lock()
        memoryAccount = slackAccount
        lock.unlock()
        return persist(slackAccount)
    }

    static func load() -> SlackAccount? {
        lock.lock()
        if let memoryAccount {
            let cached = memoryAccount
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let account = readFromKeychain() else { return nil }
        lock.lock()
        memoryAccount = account
        lock.unlock()
        return account
    }

    static func clear() {
        lock.lock()
        memoryAccount = nil
        lock.unlock()
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }

    private static func readFromKeychain() -> SlackAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let account = try? JSONDecoder().decode(SlackAccount.self, from: data)
        else {
            return nil
        }
        return account
    }

    private static func persist(_ slackAccount: SlackAccount) -> Bool {
        guard let data = try? JSONEncoder().encode(slackAccount) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = query.merging(update) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.info("Keychain save failed: status=\(status)")
        }
        return status == errSecSuccess
    }
}

// MARK: - Agent access tokens (hashed at rest)

struct AgentTokenRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var tokenHash: String
    var workspaceIDs: [String]
    var capabilities: WorkspaceCapabilities
    var createdAt: Date
    var lastUsedAt: Date?
}

struct AgentTokenStorePayload: Codable, Equatable {
    var tokens: [AgentTokenRecord]
}

/// Recoverable agent token plaintext, one Keychain item per token, readable only after device passcode.
enum AgentTokenPlaintextStore {
    private static let service = "com.slackagentbridge.agent-token-plaintext"

    @discardableResult
    static func save(tokenID: String, plaintext: String) -> Bool {
        guard let data = plaintext.data(using: .utf8) else { return false }
        delete(tokenID: tokenID)

        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .devicePasscode,
            nil
        ) else { return false }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenID,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.info("Agent token plaintext save failed: status=\(status)")
        }
        return status == errSecSuccess
    }

    static func load(tokenID: String, context: LAContext) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let plaintext = String(data: data, encoding: .utf8) else {
            return nil
        }
        return plaintext
    }

    static func delete(tokenID: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenID
        ] as CFDictionary)
    }

    static func clearAll(tokenIDs: [String]) {
        for id in tokenIDs { delete(tokenID: id) }
    }

    static func hasEntry(tokenID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenID,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}

enum AgentTokenKeychain {
    private static let service = "com.slackagentbridge.agent-tokens"
    private static let account = "agent-access-tokens"
    private static let lock = NSLock()
    private static var memoryPayload: AgentTokenStorePayload?
    private static var loadedFromKeychain = false

    @discardableResult
    static func save(_ payload: AgentTokenStorePayload) -> Bool {
        lock.lock()
        memoryPayload = payload
        loadedFromKeychain = true
        lock.unlock()
        return persist(payload)
    }

    static func load() -> AgentTokenStorePayload {
        lock.lock()
        if loadedFromKeychain, let memoryPayload {
            let cached = memoryPayload
            lock.unlock()
            return cached
        }
        lock.unlock()

        let payload = readFromKeychain()
        lock.lock()
        memoryPayload = payload
        loadedFromKeychain = true
        lock.unlock()
        return payload
    }

    /// Updates the in-memory store without touching Keychain (e.g. lastUsedAt from MCP).
    static func touchInMemory(recordID: String, lastUsedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard loadedFromKeychain, var payload = memoryPayload,
              let idx = payload.tokens.firstIndex(where: { $0.id == recordID }) else { return }
        payload.tokens[idx].lastUsedAt = lastUsedAt
        memoryPayload = payload
    }

    static func clear() {
        lock.lock()
        memoryPayload = nil
        loadedFromKeychain = false
        lock.unlock()
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }

    private static func readFromKeychain() -> AgentTokenStorePayload {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONDecoder().decode(AgentTokenStorePayload.self, from: data)
        else {
            return AgentTokenStorePayload(tokens: [])
        }
        return payload
    }

    private static func persist(_ payload: AgentTokenStorePayload) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = query.merging(update) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
