import Foundation

/// Per-workspace capability flags. Agents and automations inherit these gates.
struct WorkspaceCapabilities: Codable, Equatable, Hashable {
    var readChannels: Bool
    var archiveChannels: Bool
    var postToMyDM: Bool
    var postToDMs: Bool
    var postToChannels: Bool
    var postToGroupDMs: Bool
    var setReminders: Bool
    var setStatus: Bool
    var addReactions: Bool
    var pinMessages: Bool
    var scheduleMessages: Bool
    var editMessages: Bool
    var deleteMessages: Bool
    var removeReactions: Bool
    var unpinMessages: Bool

    static let none = WorkspaceCapabilities(
        readChannels: false,
        archiveChannels: false,
        postToMyDM: false,
        postToDMs: false,
        postToChannels: false,
        postToGroupDMs: false,
        setReminders: false,
        setStatus: false,
        addReactions: false,
        pinMessages: false,
        scheduleMessages: false,
        editMessages: false,
        deleteMessages: false,
        removeReactions: false,
        unpinMessages: false
    )

    /// Sensible defaults when first enabling a workspace for read/archive.
    static let readArchiveDefault = WorkspaceCapabilities(
        readChannels: true,
        archiveChannels: true,
        postToMyDM: false,
        postToDMs: false,
        postToChannels: false,
        postToGroupDMs: false,
        setReminders: false,
        setStatus: false,
        addReactions: false,
        pinMessages: false,
        scheduleMessages: false,
        editMessages: false,
        deleteMessages: false,
        removeReactions: false,
        unpinMessages: false
    )

    enum CodingKeys: String, CodingKey {
        case readChannels, archiveChannels, postToMyDM, postToDMs, postToChannels, postToGroupDMs, setReminders, setStatus
        case addReactions, pinMessages, scheduleMessages, editMessages, deleteMessages, removeReactions, unpinMessages
    }

    init(readChannels: Bool, archiveChannels: Bool, postToMyDM: Bool,
         postToDMs: Bool = false, postToChannels: Bool = false, postToGroupDMs: Bool = false,
         setReminders: Bool, setStatus: Bool,
         addReactions: Bool = false, pinMessages: Bool = false,
         scheduleMessages: Bool = false, editMessages: Bool = false, deleteMessages: Bool = false,
         removeReactions: Bool = false, unpinMessages: Bool = false) {
        self.readChannels = readChannels
        self.archiveChannels = archiveChannels
        self.postToMyDM = postToMyDM
        self.postToDMs = postToDMs
        self.postToChannels = postToChannels
        self.postToGroupDMs = postToGroupDMs
        self.setReminders = setReminders
        self.setStatus = setStatus
        self.addReactions = addReactions
        self.pinMessages = pinMessages
        self.scheduleMessages = scheduleMessages
        self.editMessages = editMessages
        self.deleteMessages = deleteMessages
        self.removeReactions = removeReactions
        self.unpinMessages = unpinMessages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readChannels = try c.decodeIfPresent(Bool.self, forKey: .readChannels) ?? false
        archiveChannels = try c.decodeIfPresent(Bool.self, forKey: .archiveChannels) ?? false
        postToMyDM = try c.decodeIfPresent(Bool.self, forKey: .postToMyDM) ?? false
        postToDMs = try c.decodeIfPresent(Bool.self, forKey: .postToDMs) ?? postToMyDM
        postToChannels = try c.decodeIfPresent(Bool.self, forKey: .postToChannels) ?? false
        postToGroupDMs = try c.decodeIfPresent(Bool.self, forKey: .postToGroupDMs) ?? false
        setReminders = try c.decodeIfPresent(Bool.self, forKey: .setReminders) ?? false
        setStatus = try c.decodeIfPresent(Bool.self, forKey: .setStatus) ?? false
        addReactions = try c.decodeIfPresent(Bool.self, forKey: .addReactions) ?? false
        pinMessages = try c.decodeIfPresent(Bool.self, forKey: .pinMessages) ?? false
        scheduleMessages = try c.decodeIfPresent(Bool.self, forKey: .scheduleMessages) ?? false
        editMessages = try c.decodeIfPresent(Bool.self, forKey: .editMessages) ?? false
        deleteMessages = try c.decodeIfPresent(Bool.self, forKey: .deleteMessages) ?? false
        removeReactions = try c.decodeIfPresent(Bool.self, forKey: .removeReactions) ?? false
        unpinMessages = try c.decodeIfPresent(Bool.self, forKey: .unpinMessages) ?? false
    }

    func allows(_ capability: CapabilityFlag) -> Bool {
        switch capability {
        case .readChannels: return readChannels
        case .archiveChannels: return archiveChannels
        case .postToMyDM: return postToMyDM
        case .postToDMs: return postToDMs
        case .postToChannels: return postToChannels
        case .postToGroupDMs: return postToGroupDMs
        case .setReminders: return setReminders
        case .setStatus: return setStatus
        case .addReactions: return addReactions
        case .pinMessages: return pinMessages
        case .scheduleMessages: return scheduleMessages
        case .editMessages: return editMessages
        case .deleteMessages: return deleteMessages
        case .removeReactions: return removeReactions
        case .unpinMessages: return unpinMessages
        }
    }
}

enum CapabilityFlag: String, CaseIterable, Codable {
    case readChannels
    case archiveChannels
    case postToMyDM
    case postToDMs
    case postToChannels
    case postToGroupDMs
    case setReminders
    case setStatus
    case addReactions
    case pinMessages
    case scheduleMessages
    case editMessages
    case deleteMessages
    case removeReactions
    case unpinMessages

    var label: String {
        switch self {
        case .readChannels: return "Read channels"
        case .archiveChannels: return "Archive channels"
        case .postToMyDM: return "Post to my DM"
        case .postToDMs: return "Post to DMs (agent-allowed)"
        case .postToChannels: return "Post to channels (agent-allowed)"
        case .postToGroupDMs: return "Post to group DMs (automation inbox)"
        case .setReminders: return "Set reminders"
        case .setStatus: return "Set status"
        case .addReactions: return "Add reactions"
        case .pinMessages: return "Pin messages"
        case .scheduleMessages: return "Schedule messages (DM / channel)"
        case .editMessages: return "Edit messages"
        case .deleteMessages: return "Delete messages"
        case .removeReactions: return "Remove reactions"
        case .unpinMessages: return "Unpin messages"
        }
    }
}

/// How long archived messages are kept on disk. User-controlled; pruning is local only.
enum RetentionPreset: Int, CaseIterable, Identifiable, Codable, Hashable {
    case threeMonths = 3
    case sixMonths = 6
    case twelveMonths = 12
    case twentyFourMonths = 24
    case forever = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .twelveMonths: return "12 months (recommended)"
        case .twentyFourMonths: return "24 months"
        case .forever: return "Keep forever"
        }
    }

    var months: Int? {
        self == .forever ? nil : rawValue
    }

    static func from(months: Int?) -> RetentionPreset {
        guard let months else { return .forever }
        return RetentionPreset(rawValue: months) ?? .twelveMonths
    }
}

struct WorkspaceConfig: Codable, Equatable, Identifiable {
    var id: String
    var enabled: Bool
    var capabilities: WorkspaceCapabilities
    /// Channel IDs selected for archiving (local SQLite sync).
    var archivedChannelIDs: [String]
    /// Channel IDs agents may read via MCP. Independent of archive list.
    var agentChannelIDs: [String]
    /// Retention in months; nil = keep forever. Default is 12 months to protect disk.
    var retentionMonths: Int?
    /// Where digests / keyword watches are delivered in Slack (if enabled).
    var automationDeliveryMode: AutomationDeliveryMode
    /// Target channel or group-DM id when mode is privateChannel or groupDM.
    var automationInboxChannelID: String?
    /// Custom label (Slack topic + app UI). Slackbot itself cannot be renamed without a custom app.
    var automationInboxLabel: String
    /// Star the inbox in Slack (sidebar → Starred) after create / surface.
    var slackStarAutomationInbox: Bool
    /// macOS notification when an automation posts to Slack.
    var macNotifyOnAutomation: Bool
    /// Slackbot reminder (pings Slack desktop / mobile — works for self-DM and inbox).
    var slackReminderOnAutomation: Bool

    enum CodingKeys: String, CodingKey {
        case id, enabled, capabilities, archivedChannelIDs, agentChannelIDs, retentionMonths
        case automationDeliveryMode, automationInboxChannelID
        case automationInboxLabel, slackStarAutomationInbox, macNotifyOnAutomation, slackReminderOnAutomation
    }

    init(id: String, enabled: Bool, capabilities: WorkspaceCapabilities,
         archivedChannelIDs: [String], agentChannelIDs: [String] = [],
         retentionMonths: Int?, automationDeliveryMode: AutomationDeliveryMode = .selfDM,
         automationInboxChannelID: String? = nil,
         automationInboxLabel: String = "Agent Bridge inbox",
         slackStarAutomationInbox: Bool = true,
         macNotifyOnAutomation: Bool = true,
         slackReminderOnAutomation: Bool = true) {
        self.id = id
        self.enabled = enabled
        self.capabilities = capabilities
        self.archivedChannelIDs = archivedChannelIDs
        self.agentChannelIDs = agentChannelIDs
        self.retentionMonths = retentionMonths
        self.automationDeliveryMode = automationDeliveryMode
        self.automationInboxChannelID = automationInboxChannelID
        self.automationInboxLabel = automationInboxLabel
        self.slackStarAutomationInbox = slackStarAutomationInbox
        self.macNotifyOnAutomation = macNotifyOnAutomation
        self.slackReminderOnAutomation = slackReminderOnAutomation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        capabilities = try c.decodeIfPresent(WorkspaceCapabilities.self, forKey: .capabilities) ?? .readArchiveDefault
        archivedChannelIDs = try c.decodeIfPresent([String].self, forKey: .archivedChannelIDs) ?? []
        agentChannelIDs = try c.decodeIfPresent([String].self, forKey: .agentChannelIDs) ?? []
        retentionMonths = try c.decodeIfPresent(Int.self, forKey: .retentionMonths)
        automationInboxChannelID = try c.decodeIfPresent(String.self, forKey: .automationInboxChannelID)
        automationInboxLabel = try c.decodeIfPresent(String.self, forKey: .automationInboxLabel) ?? "Agent Bridge inbox"
        slackStarAutomationInbox = try c.decodeIfPresent(Bool.self, forKey: .slackStarAutomationInbox) ?? true
        macNotifyOnAutomation = try c.decodeIfPresent(Bool.self, forKey: .macNotifyOnAutomation) ?? true
        slackReminderOnAutomation = try c.decodeIfPresent(Bool.self, forKey: .slackReminderOnAutomation) ?? true
        if let mode = try c.decodeIfPresent(AutomationDeliveryMode.self, forKey: .automationDeliveryMode) {
            automationDeliveryMode = mode
        } else if automationInboxChannelID != nil {
            automationDeliveryMode = .privateChannel
        } else {
            automationDeliveryMode = .selfDM
        }
    }

    static func fresh(id: String) -> WorkspaceConfig {
        WorkspaceConfig(
            id: id,
            enabled: false,
            capabilities: .readArchiveDefault,
            archivedChannelIDs: [],
            agentChannelIDs: [],
            retentionMonths: 12
        )
    }

    /// Channels agents may read: agent allow-list only (never entire workspace by accident).
    func agentReadableChannelIDs() -> [String] {
        agentChannelIDs
    }

    mutating func setChannel(_ channelID: String, archive: Bool?, agent: Bool?) {
        if let archive {
            if archive {
                if !archivedChannelIDs.contains(channelID) { archivedChannelIDs.append(channelID) }
            } else {
                archivedChannelIDs.removeAll { $0 == channelID }
            }
        }
        if let agent {
            if agent {
                if !agentChannelIDs.contains(channelID) { agentChannelIDs.append(channelID) }
            } else {
                agentChannelIDs.removeAll { $0 == channelID }
            }
        }
    }
}

/// Where automation output goes. Local-only never touches Slack (most private from workspace admins).
enum AutomationDeliveryMode: String, Codable, CaseIterable, Identifiable {
    case selfDM
    case localOnly
    case groupDM
    case privateChannel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .selfDM: return "Self DM (default)"
        case .localOnly: return "This Mac only (no Slack post)"
        case .groupDM: return "Group DM"
        case .privateChannel: return "Private channel"
        }
    }

    var detail: String {
        switch self {
        case .selfDM:
            return "Your “Jot something down” thread. Simple but can get crowded."
        case .localOnly:
            return "Digest preview stays in the app only. Nothing appears in Slack — admins cannot see it there."
        case .groupDM:
            return "Slackbot DM starred in your sidebar. Slackbot’s name can’t be changed without a custom Slack app; use Inbox label for topic + Mac alerts."
        case .privateChannel:
            return "A private channel you create. Workspace admins may see it exists on some plans."
        }
    }
}

struct LocalTask: Codable, Identifiable, Equatable {
    var id: String
    var workspaceID: String
    var title: String
    var sourceChannelID: String?
    var sourceTs: String?
    var createdAt: Date
    var completed: Bool
}

struct AutomationRule: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var kind: Kind
    var workspaceID: String
    /// Hour of day (local) for daily digest; ignored for other kinds.
    var hour: Int
    var minute: Int
    var keyword: String?
    var lastRunAt: Date?

    enum Kind: String, Codable, CaseIterable {
        case dailyDigest
        case keywordWatch

        var label: String {
            switch self {
            case .dailyDigest: return "Daily digest"
            case .keywordWatch: return "Keyword watch"
            }
        }
    }
}

/// Cached non-secret identity for DM delivery (user id + IM channel).
struct WorkspaceIdentity: Codable, Equatable {
    var userID: String
    var selfDMChannelID: String?
    var displayName: String?
    var updatedAt: Date
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let workspaceConfigs = "sab.workspaceConfigs"
        static let mcpEnabled = "sab.mcpEnabled"
        static let mcpPort = "sab.mcpPort"
        static let archivePaused = "sab.archivePaused"
        static let syncIntervalMinutes = "sab.syncIntervalMinutes"
        static let launchAtLogin = "sab.launchAtLogin"
        static let digestPostToDM = "sab.digestPostToDM"
        static let tasks = "sab.localTasks"
        static let automations = "sab.automations"
        static let selectedSettingsTab = "sab.selectedSettingsTab"
        static let identities = "sab.workspaceIdentities"
        static let storageWarnBytes = "sab.storageWarnBytes"
        static let sessionRefreshHours = "sab.sessionRefreshHours"
        static let firstLaunchDone = "sab.firstLaunchDone"
        static let tourCompleted = "sab.tourCompleted"
        static let tourStep = "sab.tourStep"
        static let wizardDismissed = "sab.wizardDismissed"
        static let agentLinkVerified = "sab.agentLinkVerified"
        static let agentLinkAcknowledged = "sab.agentLinkAcknowledged"
        static let allowHeadlessCLI = "sab.allowHeadlessCLI"
    }

    @Published var workspaceConfigs: [String: WorkspaceConfig] {
        didSet { saveConfigs() }
    }

    @Published var mcpServerEnabled: Bool {
        didSet { defaults.set(mcpServerEnabled, forKey: Keys.mcpEnabled) }
    }

    @Published var mcpPort: Int {
        didSet { defaults.set(mcpPort, forKey: Keys.mcpPort) }
    }

    @Published var archivePaused: Bool {
        didSet { defaults.set(archivePaused, forKey: Keys.archivePaused) }
    }

    @Published var syncIntervalMinutes: Int {
        didSet { defaults.set(syncIntervalMinutes, forKey: Keys.syncIntervalMinutes) }
    }

    @Published var digestPostToDM: Bool {
        didSet { defaults.set(digestPostToDM, forKey: Keys.digestPostToDM) }
    }

    /// When false (default), `SAB_SEND_TEXT` headless CLI cannot post to Slack.
    @Published var allowHeadlessCLI: Bool {
        didSet { defaults.set(allowHeadlessCLI, forKey: Keys.allowHeadlessCLI) }
    }

    @Published var localTasks: [LocalTask] {
        didSet { saveCodable(localTasks, key: Keys.tasks) }
    }

    @Published var automations: [AutomationRule] {
        didSet { saveCodable(automations, key: Keys.automations) }
    }

    @Published var selectedSettingsTab: Int? {
        didSet {
            if let selectedSettingsTab {
                defaults.set(selectedSettingsTab, forKey: Keys.selectedSettingsTab)
            }
        }
    }

    /// Non-secret per-workspace identity cache (user id + self DM channel).
    @Published var identities: [String: WorkspaceIdentity] {
        didSet { saveCodable(identities, key: Keys.identities) }
    }

    /// Warn in UI when archive exceeds this size (default 2 GB).
    @Published var storageWarnBytes: Int64 {
        didSet { defaults.set(storageWarnBytes, forKey: Keys.storageWarnBytes) }
    }

    /// How often to re-read the Slack desktop session (hours). Survives Slack updates.
    @Published var sessionRefreshHours: Int {
        didSet { defaults.set(sessionRefreshHours, forKey: Keys.sessionRefreshHours) }
    }

    var firstLaunchDone: Bool {
        get { defaults.bool(forKey: Keys.firstLaunchDone) }
        set { defaults.set(newValue, forKey: Keys.firstLaunchDone) }
    }

    @Published var tourCompleted: Bool {
        didSet { defaults.set(tourCompleted, forKey: Keys.tourCompleted) }
    }

    /// 0-based step inside Quick Setup; -1 when not touring.
    @Published var tourStep: Int {
        didSet { defaults.set(tourStep, forKey: Keys.tourStep) }
    }

    /// User closed the wizard without finishing (can replay from Quick Setup).
    @Published var wizardDismissed: Bool {
        didSet { defaults.set(wizardDismissed, forKey: Keys.wizardDismissed) }
    }

    /// Set when MCP test succeeds during setup.
    @Published var agentLinkVerified: Bool {
        didSet { defaults.set(agentLinkVerified, forKey: Keys.agentLinkVerified) }
    }

    /// Manual confirmation that mcp.json was added to Cursor/Claude.
    @Published var agentLinkAcknowledged: Bool {
        didSet { defaults.set(agentLinkAcknowledged, forKey: Keys.agentLinkAcknowledged) }
    }

    /// Wizard asks Workspaces pane to expand this workspace.
    @Published var wizardExpandWorkspaceID: String?

    /// Wizard asks Agent Access to create a token.
    @Published var wizardRequestCreateToken = false

    var isWizardActive: Bool {
        !tourCompleted && !wizardDismissed
    }

    private init() {
        if let data = defaults.data(forKey: Keys.workspaceConfigs),
           let decoded = try? JSONDecoder().decode([String: WorkspaceConfig].self, from: data) {
            workspaceConfigs = decoded
        } else {
            workspaceConfigs = [:]
        }
        mcpServerEnabled = defaults.object(forKey: Keys.mcpEnabled) as? Bool ?? true
        mcpPort = defaults.object(forKey: Keys.mcpPort) as? Int ?? 47821
        archivePaused = defaults.bool(forKey: Keys.archivePaused)
        syncIntervalMinutes = defaults.object(forKey: Keys.syncIntervalMinutes) as? Int ?? 15
        digestPostToDM = defaults.object(forKey: Keys.digestPostToDM) as? Bool ?? false
        allowHeadlessCLI = defaults.object(forKey: Keys.allowHeadlessCLI) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.tasks),
           let decoded = try? JSONDecoder().decode([LocalTask].self, from: data) {
            localTasks = decoded
        } else {
            localTasks = []
        }
        if let data = defaults.data(forKey: Keys.automations),
           let decoded = try? JSONDecoder().decode([AutomationRule].self, from: data) {
            automations = decoded
        } else {
            automations = []
        }
        if defaults.object(forKey: Keys.selectedSettingsTab) != nil {
            selectedSettingsTab = defaults.integer(forKey: Keys.selectedSettingsTab)
        } else {
            selectedSettingsTab = 0
        }
        if let data = defaults.data(forKey: Keys.identities),
           let decoded = try? JSONDecoder().decode([String: WorkspaceIdentity].self, from: data) {
            identities = decoded
        } else {
            identities = [:]
        }
        storageWarnBytes = (defaults.object(forKey: Keys.storageWarnBytes) as? Int64) ?? (2 * 1024 * 1024 * 1024)
        sessionRefreshHours = defaults.object(forKey: Keys.sessionRefreshHours) as? Int ?? 6
        tourCompleted = defaults.bool(forKey: Keys.tourCompleted)
        tourStep = defaults.object(forKey: Keys.tourStep) as? Int ?? 0
        wizardDismissed = defaults.bool(forKey: Keys.wizardDismissed)
        agentLinkVerified = defaults.bool(forKey: Keys.agentLinkVerified)
        agentLinkAcknowledged = defaults.bool(forKey: Keys.agentLinkAcknowledged)
    }

    func startTour() {
        tourCompleted = false
        tourStep = 0
        wizardDismissed = false
        agentLinkVerified = false
        agentLinkAcknowledged = false
        selectedSettingsTab = SetupWizardStep.connectSlack.settingsTab
    }

    func dismissWizard() {
        wizardDismissed = true
        selectedSettingsTab = 0
    }

    func completeTour() {
        tourCompleted = true
        tourStep = 0
        wizardDismissed = false
        firstLaunchDone = true
    }

    func config(for workspaceID: String) -> WorkspaceConfig {
        if let existing = workspaceConfigs[workspaceID] { return existing }
        let fresh = WorkspaceConfig.fresh(id: workspaceID)
        workspaceConfigs[workspaceID] = fresh
        return fresh
    }

    func updateConfig(_ config: WorkspaceConfig) {
        var updated = workspaceConfigs
        updated[config.id] = config
        workspaceConfigs = updated
    }

    func ensureConfigs(for workspaceIDs: [String]) {
        for id in workspaceIDs where workspaceConfigs[id] == nil {
            workspaceConfigs[id] = WorkspaceConfig.fresh(id: id)
        }
    }

    private func saveConfigs() {
        saveCodable(workspaceConfigs, key: Keys.workspaceConfigs)
    }

    private func saveCodable<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
