import Foundation
import Combine

enum BridgeStatus: Equatable {
    case disconnected
    case connected
    case syncing
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connected: return "Connected"
        case .syncing: return "Syncing"
        case .error(let m): return m
        }
    }
}

@MainActor
final class BridgeController: ObservableObject {
    @Published private(set) var status: BridgeStatus = .disconnected
    @Published private(set) var account: SlackAccount?
    @Published private(set) var workspaces: [SlackWorkspace] = []
    @Published var lastError: String?
    @Published var channelCache: [String: [SlackChannel]] = [:]
    @Published var channelListLoading: Set<String> = []
    @Published var archiveMessageCount: Int = 0
    @Published var archiveSizeBytes: Int64 = 0
    @Published var mcpRunning: Bool = false
    /// Live map workspaceID -> userID (also persisted in settings.identities).
    @Published var selfUserIDs: [String: String] = [:]
    @Published var storageWarning: String?
    @Published var lastSessionRefreshAt: Date?

    let settings: Settings
    let tokens: AgentTokenManager
    let archiveSync: ArchiveSyncService
    let automations: AutomationEngine
    let api = SlackAPIClient()

    private var mcpServer: MCPHTTPServer?
    private var sessionRefreshTimer: Timer?
    private var sessionRefreshInFlight = false
    private var lastSlackKeychainReadAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings
        self.tokens = AgentTokenManager()
        self.archiveSync = ArchiveSyncService()
        self.automations = AutomationEngine()
        tokens.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        for (wid, identity) in settings.identities {
            selfUserIDs[wid] = identity.userID
        }
        if let cached = KeychainStore.load() {
            applyAccount(cached)
            status = .connected
        }
    }

    var isConnected: Bool { account != nil }

    func bootstrap() {
        if account == nil {
            Task { await useLocalSession() }
        } else {
            // Periodic refresh so Slack desktop updates do not strand stale tokens.
            scheduleSessionRefresh()
            Task { await ensureIdentities() }
        }
        refreshArchiveStats()
        restartMCPIfNeeded()
        archiveSync.start(settings: settings, bridge: self)
        automations.start(settings: settings, bridge: self)
    }

    func shutdown() {
        sessionRefreshTimer?.invalidate()
        sessionRefreshTimer = nil
        archiveSync.stop()
        automations.stop()
        mcpServer?.stop()
        mcpRunning = false
    }

    @discardableResult
    func useLocalSession(reuseCookie: String? = nil, forceCookieRefresh: Bool = false) async -> Bool {
        do {
            let cookieToReuse = forceCookieRefresh ? nil : (reuseCookie ?? account?.cookieHeader)
            let (cookie, teams) = try LocalSlackSession.readSession(reuseCookie: cookieToReuse)
            if cookieToReuse == nil {
                lastSlackKeychainReadAt = Date()
            }
            var workspaces: [SlackWorkspace] = []
            for team in teams {
                var id = team.id
                var name = team.name
                var url = team.url
                var userID: String?
                do {
                    let auth = try await api.authTest(token: team.token, cookie: cookie)
                    if name.isEmpty || id.hasPrefix("xoxc") {
                        id = auth.teamID
                        name = auth.team
                        url = auth.url
                    }
                    userID = auth.userID
                    selfUserIDs[id] = auth.userID
                    persistIdentity(workspaceID: id, userID: auth.userID, displayName: nil)
                } catch {
                    Log.info("auth.test failed for team: \(error.localizedDescription)")
                    if let existing = settings.identities[id] {
                        userID = existing.userID
                        selfUserIDs[id] = existing.userID
                    }
                }
                _ = userID
                workspaces.append(SlackWorkspace(id: id, name: name.isEmpty ? id : name, url: url, token: team.token))
            }
            let account = SlackAccount(cookieHeader: cookie, workspaces: workspaces)
            _ = KeychainStore.save(account)
            applyAccount(account)
            status = .connected
            lastError = nil
            lastSessionRefreshAt = Date()
            settings.ensureConfigs(for: workspaces.map(\.id))
            restartMCPIfNeeded()
            scheduleSessionRefresh()
            // Resolve self-DM channels in the background for enabled write workspaces.
            Task { await ensureIdentities() }
            return true
        } catch {
            lastError = error.localizedDescription
            status = .error(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func refreshLocalSession(forceCookieRefresh: Bool = false) async -> Bool {
        guard !sessionRefreshInFlight else { return account != nil }
        sessionRefreshInFlight = true
        defer { sessionRefreshInFlight = false }

        // Token-only refresh avoids Slack's Keychain prompt in most cases.
        if !forceCookieRefresh {
            let ok = await useLocalSession(reuseCookie: account?.cookieHeader)
            if ok { return true }
            // Throttle full Keychain reads (cookie decrypt) to once per 30s unless forced.
            if let last = lastSlackKeychainReadAt, Date().timeIntervalSince(last) < 30 {
                return account != nil
            }
        }
        return await useLocalSession(forceCookieRefresh: true)
    }

    func disconnect() {
        KeychainStore.clear()
        account = nil
        workspaces = []
        channelCache = [:]
        selfUserIDs = [:]
        status = .disconnected
        mcpServer?.stop()
        mcpRunning = false
        sessionRefreshTimer?.invalidate()
        sessionRefreshTimer = nil
    }

    private func applyAccount(_ account: SlackAccount) {
        self.account = account
        self.workspaces = account.workspaces
        settings.ensureConfigs(for: account.workspaces.map(\.id))
    }

    func refreshConnectionState() {
        if account == nil, let cached = KeychainStore.load() {
            applyAccount(cached)
            status = .connected
        }
        refreshArchiveStats()
        mcpRunning = mcpServer?.isListening == true
    }

    func refreshArchiveStats() {
        archiveMessageCount = MessageArchive.shared.messageCount()
        archiveSizeBytes = MessageArchive.shared.databaseFileSize()
        if archiveSizeBytes >= settings.storageWarnBytes {
            let gb = Double(archiveSizeBytes) / (1024 * 1024 * 1024)
            storageWarning = String(format: "Archive is using %.1f GB. Shorten retention or wipe old channels to free space.", gb)
        } else {
            storageWarning = nil
        }
    }

    func loadChannels(for workspaceID: String) async {
        guard credentials(for: workspaceID) != nil else { return }
        channelListLoading.insert(workspaceID)
        defer { channelListLoading.remove(workspaceID) }
        do {
            var channels = try await withAuthRetry(workspaceID) {
                guard let creds = self.credentials(for: workspaceID) else {
                    throw SlackError.notConnected
                }
                return try await self.api.listConversations(
                    token: creds.token,
                    cookie: creds.cookie
                )
            }
            _ = try? await resolveSelfIdentity(workspaceID: workspaceID, forceRefresh: false)
            channels = await resolvePeerLabels(channels: channels, workspaceID: workspaceID)
            channelCache[workspaceID] = channels.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            let config = settings.config(for: workspaceID)
            if config.automationDeliveryMode == .groupDM,
               let inboxID = config.automationInboxChannelID, !inboxID.isEmpty {
                registerAutomationInboxChannel(workspaceID: workspaceID, channelID: inboxID)
            }
            for ch in channels {
                var stored = ch
                if ch.isIM || ch.isMPIM {
                    stored.name = ch.displayName
                }
                MessageArchive.shared.upsertChannel(stored, workspaceID: workspaceID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetches workspace members once and labels IM / MPIM conversations with real names.
    private func resolvePeerLabels(channels: [SlackChannel], workspaceID: String) async -> [SlackChannel] {
        let needsUsers = channels.contains { $0.isIM || $0.isMPIM }
        guard needsUsers, let creds = credentials(for: workspaceID) else { return channels }

        let selfUID = selfUserIDs[workspaceID] ?? settings.identities[workspaceID]?.userID
        let selfChannelID = settings.identities[workspaceID]?.selfDMChannelID

        guard let users = try? await api.usersList(token: creds.token, cookie: creds.cookie) else {
            return markSelfDMs(channels, selfUserID: selfUID, selfChannelID: selfChannelID, labels: [:], workspaceID: workspaceID)
        }
        let labels = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0.dmLabel) })
        for user in users {
            MessageArchive.shared.upsertUser(user, workspaceID: workspaceID)
        }

        return markSelfDMs(channels, selfUserID: selfUID, selfChannelID: selfChannelID, labels: labels, workspaceID: workspaceID)
    }

    private func markSelfDMs(
        _ channels: [SlackChannel],
        selfUserID: String?,
        selfChannelID: String?,
        labels: [String: String],
        workspaceID: String
    ) -> [SlackChannel] {
        channels.map { ch in
            var updated = ch
            if ch.isIM, let uid = ch.userID {
                let isSelf = (selfUserID != nil && uid == selfUserID) || ch.id == selfChannelID
                updated.isSelfDM = isSelf
                if isSelf {
                    updated.peerLabel = labels[uid] ?? updated.peerLabel
                    cacheSelfDMChannel(workspaceID: workspaceID, channelID: ch.id)
                } else if uid == SlackChannel.slackbotUserID {
                    let wsConfig = settings.config(for: workspaceID)
                    if wsConfig.automationInboxChannelID == ch.id {
                        updated.peerLabel = wsConfig.automationInboxLabel
                    } else if updated.peerLabel == nil || updated.peerLabel == labels[uid] {
                        updated.peerLabel = wsConfig.automationInboxLabel
                    }
                } else if let label = labels[uid] {
                    updated.peerLabel = label
                }
            } else if ch.isMPIM, !ch.name.isEmpty {
                let parts = ch.name.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let names = parts.compactMap { part -> String? in
                    if part.hasPrefix("U") || part.hasPrefix("W") { return labels[part] }
                    return part.isEmpty ? nil : part
                }
                if !names.isEmpty {
                    updated.peerLabel = names.joined(separator: ", ")
                }
            }
            return updated
        }
    }

    func restartMCPIfNeeded() {
        mcpServer?.stop()
        mcpRunning = false
        guard settings.mcpServerEnabled, account != nil else { return }
        let server = MCPHTTPServer(port: settings.mcpPort, bridge: self)
        do {
            try server.start()
            mcpServer = server
            mcpRunning = true
            Log.info("MCP server listening on 127.0.0.1:\(settings.mcpPort)")
        } catch {
            lastError = "MCP server failed: \(error.localizedDescription). If another Slack Agent Bridge is running, quit duplicates in Activity Monitor."
            mcpRunning = false
            Log.error(lastError ?? "MCP start failed")
        }
    }

    func workspace(for id: String) -> SlackWorkspace? {
        workspaces.first { $0.id == id }
    }

    /// Creates a private Slack channel for automation output (only you need to be a member).
    func createAutomationInbox(workspaceID: String, name: String) async throws -> SlackChannel {
        guard let creds = credentials(for: workspaceID) else { throw SlackError.notConnected }
        let channel = try await api.createPrivateChannel(
            name: name, token: creds.token, cookie: creds.cookie
        )
        var config = settings.config(for: workspaceID)
        config.capabilities.postToChannels = true
        config.automationDeliveryMode = .privateChannel
        config.automationInboxChannelID = channel.id
        config.setChannel(channel.id, archive: true, agent: true)
        settings.updateConfig(config)
        await loadChannels(for: workspaceID)
        return channel
    }

    /// Creates a group DM (you + Slackbot) as a low-profile automation inbox.
    func createAutomationGroupDM(workspaceID: String) async throws -> String {
        guard let creds = credentials(for: workspaceID) else { throw SlackError.notConnected }
        let identity = try await resolveSelfIdentity(workspaceID: workspaceID, forceRefresh: false)
        let channelID = try await api.openMPIM(
            userIDs: [identity.userID, SlackChannel.slackbotUserID],
            token: creds.token,
            cookie: creds.cookie
        )
        var config = settings.config(for: workspaceID)
        config.capabilities.postToGroupDMs = true
        config.automationDeliveryMode = .groupDM
        config.automationInboxChannelID = channelID
        config.setChannel(channelID, archive: true, agent: true)
        settings.updateConfig(config)
        await loadChannels(for: workspaceID)
        await surfaceAutomationInbox(workspaceID: workspaceID, channelID: channelID)
        return channelID
    }

    /// Star inbox in Slack + set topic label. Slackbot's display name cannot be renamed via API.
    func surfaceAutomationInbox(workspaceID: String, channelID: String) async {
        let config = settings.config(for: workspaceID)
        let label = config.automationInboxLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = label.isEmpty ? "Agent Bridge inbox" : label
        registerAutomationInboxChannel(workspaceID: workspaceID, channelID: channelID, label: displayLabel)

        guard let creds = credentials(for: workspaceID) else { return }
        if config.slackStarAutomationInbox {
            try? await api.starChannel(channelID: channelID, token: creds.token, cookie: creds.cookie)
        }
        let topic = "🤖 \(displayLabel) — automations & agent alerts"
        try? await api.setConversationTopic(
            channelID: channelID, topic: topic, token: creds.token, cookie: creds.cookie
        )
    }

    /// Ensures the automation inbox appears in the channel cache with a friendly label.
    func registerAutomationInboxChannel(workspaceID: String, channelID: String, label: String? = nil) {
        let displayLabel = label ?? settings.config(for: workspaceID).automationInboxLabel
        if var channels = channelCache[workspaceID],
           let idx = channels.firstIndex(where: { $0.id == channelID }) {
            channels[idx].peerLabel = displayLabel
            channels[idx].isSelfDM = false
            channelCache[workspaceID] = channels
            return
        }
        var channels = channelCache[workspaceID] ?? []
        channels.append(SlackChannel.syntheticAutomationInbox(id: channelID, label: displayLabel))
        channelCache[workspaceID] = channels.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func credentials(for workspaceID: String) -> (token: String, cookie: String)? {
        guard let account, let ws = account.workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        return (ws.token, account.cookieHeader)
    }

    // MARK: - Self identity / DM

    func resolveSelfIdentity(workspaceID: String, forceRefresh: Bool) async throws -> WorkspaceIdentity {
        if !forceRefresh, let cached = settings.identities[workspaceID], !cached.userID.isEmpty {
            selfUserIDs[workspaceID] = cached.userID
            return cached
        }
        guard let creds = credentials(for: workspaceID) else {
            throw SlackError.notConnected
        }
        let auth = try await api.authTest(token: creds.token, cookie: creds.cookie)
        var identity = WorkspaceIdentity(
            userID: auth.userID,
            selfDMChannelID: settings.identities[workspaceID]?.selfDMChannelID,
            displayName: auth.userID,
            updatedAt: Date()
        )
        // Prefer display name from users.info when available.
        if let user = try? await api.userInfo(userID: auth.userID, token: creds.token, cookie: creds.cookie) {
            identity.displayName = user.label
            MessageArchive.shared.upsertUser(user, workspaceID: workspaceID)
        }
        if identity.selfDMChannelID == nil {
            if let channelID = try? await api.openIM(userID: auth.userID, token: creds.token, cookie: creds.cookie) {
                identity.selfDMChannelID = channelID
            }
        }
        settings.identities[workspaceID] = identity
        selfUserIDs[workspaceID] = identity.userID
        return identity
    }

    func cacheSelfDMChannel(workspaceID: String, channelID: String) {
        var identity = settings.identities[workspaceID] ?? WorkspaceIdentity(
            userID: selfUserIDs[workspaceID] ?? "",
            selfDMChannelID: nil,
            displayName: nil,
            updatedAt: Date()
        )
        identity.selfDMChannelID = channelID
        identity.updatedAt = Date()
        settings.identities[workspaceID] = identity
    }

    private func persistIdentity(workspaceID: String, userID: String, displayName: String?) {
        var identity = settings.identities[workspaceID] ?? WorkspaceIdentity(
            userID: userID,
            selfDMChannelID: nil,
            displayName: displayName,
            updatedAt: Date()
        )
        identity.userID = userID
        if let displayName { identity.displayName = displayName }
        identity.updatedAt = Date()
        settings.identities[workspaceID] = identity
    }

    private func ensureIdentities() async {
        for ws in workspaces {
            let config = settings.config(for: ws.id)
            guard config.enabled else { continue }
            _ = try? await resolveSelfIdentity(workspaceID: ws.id, forceRefresh: false)
        }
    }

    private func scheduleSessionRefresh() {
        sessionRefreshTimer?.invalidate()
        let hours = max(1, settings.sessionRefreshHours)
        sessionRefreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = await self?.refreshLocalSession()
            }
        }
    }

    /// Runs an API closure; on authExpired, refreshes local Slack session once and retries.
    func withAuthRetry<T>(_ workspaceID: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch SlackError.authExpired {
            _ = await refreshLocalSession(forceCookieRefresh: true)
            return try await body()
        }
    }
}
