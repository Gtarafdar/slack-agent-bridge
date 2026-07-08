import Foundation
import CryptoKit
import LocalAuthentication
import Security

@MainActor
final class AgentTokenManager: ObservableObject {
    @Published private(set) var tokens: [AgentTokenRecord] = []

    /// Plaintext shown once after create/rotate; cleared on dismiss.
    @Published var lastIssuedPlaintext: (id: String, name: String, token: String)?

    init() {
        reload()
    }

    func reload() {
        tokens = AgentTokenKeychain.load().tokens.sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates a new agent token. Returns plaintext once.
    @discardableResult
    func create(name: String, workspaceIDs: [String], capabilities: WorkspaceCapabilities) -> String {
        let plaintext = Self.generateToken()
        let record = AgentTokenRecord(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : name,
            tokenHash: Self.hash(plaintext),
            workspaceIDs: workspaceIDs,
            capabilities: capabilities,
            createdAt: Date(),
            lastUsedAt: nil
        )
        var payload = AgentTokenKeychain.load()
        payload.tokens.append(record)
        AgentTokenKeychain.save(payload)
        _ = AgentTokenPlaintextStore.save(tokenID: record.id, plaintext: plaintext)
        reload()
        lastIssuedPlaintext = (record.id, record.name, plaintext)
        MessageArchive.shared.appendAudit(actor: "user", action: "token.create", detail: record.name)
        if !AgentTokenPlaintextStore.hasEntry(tokenID: record.id) {
            Log.info("Agent token created but secure copy was not saved (tokenID=\(record.id))")
        }
        return plaintext
    }

    func rename(id: String, name: String) {
        var payload = AgentTokenKeychain.load()
        guard let idx = payload.tokens.firstIndex(where: { $0.id == id }) else { return }
        payload.tokens[idx].name = name
        AgentTokenKeychain.save(payload)
        reload()
    }

    func updateScopes(id: String, workspaceIDs: [String], capabilities: WorkspaceCapabilities) {
        var payload = AgentTokenKeychain.load()
        guard let idx = payload.tokens.firstIndex(where: { $0.id == id }) else { return }
        payload.tokens[idx].workspaceIDs = workspaceIDs
        payload.tokens[idx].capabilities = capabilities
        AgentTokenKeychain.save(payload)
        reload()
    }

    /// Rotates token; returns new plaintext once.
    @discardableResult
    func rotate(id: String) -> String? {
        var payload = AgentTokenKeychain.load()
        guard let idx = payload.tokens.firstIndex(where: { $0.id == id }) else { return nil }
        let plaintext = Self.generateToken()
        payload.tokens[idx].tokenHash = Self.hash(plaintext)
        let tokenID = payload.tokens[idx].id
        AgentTokenKeychain.save(payload)
        _ = AgentTokenPlaintextStore.save(tokenID: tokenID, plaintext: plaintext)
        reload()
        lastIssuedPlaintext = (tokenID, payload.tokens[idx].name, plaintext)
        MessageArchive.shared.appendAudit(actor: "user", action: "token.rotate", detail: payload.tokens[idx].name)
        return plaintext
    }

    func revoke(id: String) {
        var payload = AgentTokenKeychain.load()
        let name = payload.tokens.first(where: { $0.id == id })?.name
        payload.tokens.removeAll { $0.id == id }
        AgentTokenKeychain.save(payload)
        AgentTokenPlaintextStore.delete(tokenID: id)
        reload()
        if lastIssuedPlaintext?.id == id { lastIssuedPlaintext = nil }
        MessageArchive.shared.appendAudit(actor: "user", action: "token.revoke", detail: name)
    }

    enum RevealResult {
        case cancelled
        case notStored
        case revealed(String)
    }

    /// Reveal a stored token after macOS login authentication.
    func revealPlaintext(id: String, reason: String) async -> RevealResult {
        guard let context = await DeviceAuth.authenticatedContext(reason: reason) else {
            return .cancelled
        }
        guard let plaintext = AgentTokenPlaintextStore.load(tokenID: id, context: context) else {
            return .notStored
        }
        return .revealed(plaintext)
    }

    func hasStoredPlaintext(id: String) -> Bool {
        AgentTokenPlaintextStore.hasEntry(tokenID: id)
    }

    func clearIssued() {
        lastIssuedPlaintext = nil
    }

    /// Nonisolated validation for MCP HTTP handlers.
    nonisolated static func authenticate(bearer: String) -> AgentTokenRecord? {
        let hash = hash(bearer)
        let payload = AgentTokenKeychain.load()
        guard let record = payload.tokens.first(where: { $0.tokenHash == hash }) else {
            return nil
        }
        // Memory-only touch — avoid Keychain writes on every MCP poll.
        AgentTokenKeychain.touchInMemory(recordID: record.id, lastUsedAt: Date())
        return record
    }

    nonisolated static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "sab_" + hex
    }

    nonisolated static func hash(_ plaintext: String) -> String {
        let digest = SHA256.hash(data: Data(plaintext.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func mcpJSONSnippet(token: String, port: Int) -> String {
        """
        {
          "mcpServers": {
            "slack-agent-bridge": {
              "url": "http://127.0.0.1:\(port)/mcp",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }
}
