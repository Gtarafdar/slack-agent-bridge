import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController
    var onQuit: () -> Void

    private enum Tab: Int, CaseIterable, Identifiable, Hashable {
        case quickSetup = 0
        case connection = 1
        case workspaces = 2
        case archive = 3
        case automations = 4
        case agentAccess = 5
        case privacy = 6

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .quickSetup: return "Quick Setup"
            case .connection: return "Connection"
            case .workspaces: return "Workspaces"
            case .archive: return "Archive"
            case .automations: return "Automations"
            case .agentAccess: return "Agent Access"
            case .privacy: return "Privacy"
            }
        }

        var icon: String {
            switch self {
            case .quickSetup: return "list.bullet.clipboard"
            case .connection: return "cable.connector"
            case .workspaces: return "building.2"
            case .archive: return "archivebox"
            case .automations: return "clock.arrow.2.circlepath"
            case .agentAccess: return "key"
            case .privacy: return "lock.shield"
            }
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                AppBrandHeader(subtitle: "Local Slack ↔ AI bridge", compact: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                List(selection: $settings.selectedSettingsTab) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.title, systemImage: tab.icon)
                            .tag(tab.rawValue)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)

            VStack(spacing: 0) {
                if settings.isWizardActive {
                    SetupWizardBar(settings: settings, bridge: bridge)
                }
                paneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            if settings.selectedSettingsTab == nil {
                settings.selectedSettingsTab = 0
            }
            if settings.isWizardActive {
                if settings.tourStep == 0 && !settings.tourCompleted {
                    settings.selectedSettingsTab = SetupWizardStep.connectSlack.settingsTab
                }
            } else if !settings.tourCompleted && !settings.firstLaunchDone {
                settings.selectedSettingsTab = 0
                settings.tourStep = 0
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch Tab(rawValue: settings.selectedSettingsTab ?? 0) ?? .quickSetup {
        case .quickSetup:
            QuickSetupPane(settings: settings, bridge: bridge)
        case .connection:
            ConnectionPane(settings: settings, bridge: bridge, onQuit: onQuit)
        case .workspaces:
            WorkspacesPane(settings: settings, bridge: bridge)
        case .archive:
            ArchivePane(settings: settings, bridge: bridge)
        case .automations:
            AutomationsPane(settings: settings, bridge: bridge)
        case .agentAccess:
            AgentAccessPane(settings: settings, bridge: bridge)
        case .privacy:
            PrivacyPane(settings: settings, bridge: bridge)
        }
    }
}

// MARK: - Connection

struct ConnectionPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController
    var onQuit: () -> Void
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header("Connection", subtitle: "Uses your local Slack desktop session. No admin approval and no Slack app install.")

                statusCard

                GroupBox("First open on this Mac") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This build is ad-hoc signed (same approach as many free open-source Mac utilities). No paid Apple Developer certificate is required.")
                            .font(.callout)
                        Text("If macOS blocks the app: right-click the app → Open → Open. Or allow it in System Settings → Privacy & Security. This is a local Gatekeeper prompt, not an App Store review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                KeychainAlwaysAllowNote()

                HStack(spacing: 12) {
                    Button(bridge.isConnected ? "Refresh local session" : "Connect Slack session") {
                        busy = true
                        Task {
                            let ok = await bridge.useLocalSession()
                            busy = false
                            if !ok {
                                presentAlert(title: "Could not read Slack session",
                                             message: bridge.lastError ?? "Install Slack and sign in, then try again.")
                            }
                        }
                    }
                    .disabled(busy)

                    if bridge.isConnected {
                        Button("Disconnect", role: .destructive) {
                            bridge.disconnect()
                        }
                    }
                }

                if bridge.isConnected {
                    Text("Signed-in identity is read with Slack auth.test per workspace. Digests and agent DM tools open a conversation with yourself only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(bridge.workspaces.filter { settings.config(for: $0.id).enabled }) { ws in
                        if let identity = settings.identities[ws.id] {
                            Text("\(ws.name): \(identity.displayName ?? identity.userID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        LoginItem.setEnabled(value)
                    }

                HStack {
                    Spacer()
                    Button("Quit") { onQuit() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if !settings.firstLaunchDone {
                settings.firstLaunchDone = true
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(bridge.status.label, systemImage: bridge.isConnected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(bridge.isConnected ? .primary : .secondary)
            if let err = bridge.lastError, !bridge.isConnected {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Text("MCP server: \(bridge.mcpRunning ? "listening on 127.0.0.1:\(settings.mcpPort)" : "stopped")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Archive: \(bridge.archiveMessageCount) messages (\(byteSize(bridge.archiveSizeBytes)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let refreshed = bridge.lastSessionRefreshAt {
                Text("Session last refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warn = bridge.storageWarning {
                Text(warn).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Workspaces

struct WorkspacesPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController
    @State private var expandedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Workspaces", subtitle: "Enable workspaces explicitly. Choose Archive and Agent channels separately — agents only see the Agent list.")

            if settings.isWizardActive {
                Text("Setup wizard: enable a workspace and configure channels below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if bridge.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No workspaces yet.")
                        .foregroundStyle(.secondary)
                    Text("Connect your Slack desktop session first.")
                        .font(.callout)
                    Button("Go to Connection") {
                        settings.selectedSettingsTab = 1
                    }
                }
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(bridge.workspaces) { ws in
                        WorkspaceRow(
                            workspace: ws,
                            config: Binding(
                                get: { settings.config(for: ws.id) },
                                set: { settings.updateConfig($0) }
                            ),
                            bridge: bridge,
                            isExpanded: expandedID == ws.id,
                            onToggleExpand: {
                                expandedID = expandedID == ws.id ? nil : ws.id
                            }
                        )
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { syncWizardExpand() }
        .onChange(of: settings.wizardExpandWorkspaceID) { _ in syncWizardExpand() }
    }

    private func syncWizardExpand() {
        if let id = settings.wizardExpandWorkspaceID {
            expandedID = id
        }
    }
}

struct WorkspaceRow: View {
    let workspace: SlackWorkspace
    @Binding var config: WorkspaceConfig
    @ObservedObject var bridge: BridgeController
    var isExpanded: Bool
    var onToggleExpand: () -> Void
    @State private var channelFilter = ""
    @State private var inboxBusy = false

    private var allChannels: [SlackChannel] {
        bridge.channelCache[workspace.id] ?? []
    }

    private var filteredChannels: [SlackChannel] {
        let q = channelFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allChannels }
        return allChannels.filter { ch in
            ch.displayName.lowercased().contains(q)
                || ch.name.lowercased().contains(q)
                || ch.id.lowercased().contains(q)
                || (ch.peerLabel?.lowercased().contains(q) ?? false)
                || (ch.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    /// MPIMs plus the configured automation inbox (Slackbot DM is `is_im`, not `is_mpim`).
    private var groupDMChoices: [SlackChannel] {
        var choices = allChannels.filter(\.isAutomationInboxEligible)
        if let inboxID = config.automationInboxChannelID, !inboxID.isEmpty,
           !choices.contains(where: { $0.id == inboxID }) {
            if let inbox = allChannels.first(where: { $0.id == inboxID }) {
                choices.insert(inbox, at: 0)
            } else {
                choices.insert(SlackChannel.syntheticAutomationInbox(id: inboxID), at: 0)
            }
        }
        return choices.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $config.enabled) {
                    VStack(alignment: .leading) {
                        Text(workspace.name).font(.headline)
                        Text(workspace.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isExpanded ? "Hide" : "Configure") { onToggleExpand() }
            }

            if isExpanded && config.enabled {
                Divider()
                Text("Capabilities").font(.subheadline).foregroundStyle(.secondary)
                Toggle("Read channels", isOn: $config.capabilities.readChannels)
                Toggle("Archive channels", isOn: $config.capabilities.archiveChannels)
                Toggle("Post to my DM", isOn: $config.capabilities.postToMyDM)
                Toggle("Post to DMs (agent-allowed)", isOn: $config.capabilities.postToDMs)
                Toggle("Post to channels (agent-allowed)", isOn: $config.capabilities.postToChannels)
                Toggle("Post to group DMs (automation inbox)", isOn: $config.capabilities.postToGroupDMs)
                Toggle("Schedule messages (DM / channel)", isOn: $config.capabilities.scheduleMessages)
                Toggle("Set reminders", isOn: $config.capabilities.setReminders)
                Toggle("Set status", isOn: $config.capabilities.setStatus)
                Toggle("Add reactions", isOn: $config.capabilities.addReactions)
                Toggle("Remove reactions", isOn: $config.capabilities.removeReactions)
                Toggle("Pin messages", isOn: $config.capabilities.pinMessages)
                Toggle("Unpin messages", isOn: $config.capabilities.unpinMessages)
                Toggle("Edit messages", isOn: $config.capabilities.editMessages)
                Toggle("Delete messages", isOn: $config.capabilities.deleteMessages)

                Divider()
                HStack {
                    Text("Channel access").font(.subheadline)
                    Spacer()
                    if bridge.channelListLoading.contains(workspace.id) {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh channel list") {
                        Task { await bridge.loadChannels(for: workspace.id) }
                    }
                    .disabled(bridge.channelListLoading.contains(workspace.id))
                }
                Text("Archive = store locally. Agent = AI tools may read. Mark both when you want continuous search past Slack Free’s limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("DM — Me (notes to self) is your own DM (Slack “Jot something down”). Other DMs are with other people.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let channels = bridge.channelCache[workspace.id] {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search channels and DMs…", text: $channelFilter)
                            .textFieldStyle(.roundedBorder)
                        if !channelFilter.isEmpty {
                            Button("Clear") { channelFilter = "" }
                                .font(.caption)
                        }
                    }
                    if !channelFilter.isEmpty {
                        Text("Showing \(filteredChannels.count) of \(channels.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("Automation delivery") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Where automations go", selection: $config.automationDeliveryMode) {
                                ForEach(AutomationDeliveryMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            Text(config.automationDeliveryMode.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if config.automationDeliveryMode != .localOnly {
                                Toggle("Mac notification when message delivers", isOn: $config.macNotifyOnAutomation)
                                    .font(.caption)
                                Toggle("Slackbot reminder (pings Slack app / phone)", isOn: $config.slackReminderOnAutomation)
                                    .font(.caption)
                                if config.slackReminderOnAutomation && !config.capabilities.setReminders {
                                    Text("Enable “Set reminders” under Capabilities for Slackbot pings.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }

                            if config.automationDeliveryMode == .groupDM {
                                Picker("Inbox thread", selection: Binding(
                                    get: { config.automationInboxChannelID ?? "" },
                                    set: { config.automationInboxChannelID = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text("Select an inbox thread…").tag("")
                                    ForEach(groupDMChoices) { ch in
                                        Text(ch.displayName).tag(ch.id)
                                    }
                                }
                                TextField("Inbox label (Slack topic + app)", text: $config.automationInboxLabel)
                                    .textFieldStyle(.roundedBorder)
                                Text("Slackbot’s name can’t be renamed without a custom Slack app. This label sets the thread topic and how it appears here.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Toggle("Star inbox in Slack (sidebar → Starred)", isOn: $config.slackStarAutomationInbox)
                                    .font(.caption)
                                if let inboxID = config.automationInboxChannelID,
                                   !inboxID.isEmpty,
                                   groupDMChoices.contains(where: { $0.id == inboxID }) {
                                    Text("Automations will post to the selected thread.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Button(inboxBusy ? "Creating…" : "Create Agent Bridge inbox (Slackbot DM)") {
                                    inboxBusy = true
                                    Task {
                                        defer { inboxBusy = false }
                                        do {
                                            _ = try await bridge.createAutomationGroupDM(workspaceID: workspace.id)
                                        } catch {
                                            presentAlert(
                                                title: "Could not create group DM",
                                                message: "\(error.localizedDescription)\n\nYou can also start a group DM manually in Slack, refresh the list, and pick it above."
                                            )
                                        }
                                    }
                                }
                                .disabled(inboxBusy || !config.capabilities.postToGroupDMs)
                                if config.automationInboxChannelID != nil {
                                    Button(inboxBusy ? "Updating…" : "Star & apply label in Slack") {
                                        inboxBusy = true
                                        Task {
                                            defer { inboxBusy = false }
                                            guard let inboxID = config.automationInboxChannelID else { return }
                                            await bridge.surfaceAutomationInbox(workspaceID: workspace.id, channelID: inboxID)
                                        }
                                    }
                                    .disabled(inboxBusy)
                                }
                                if !config.capabilities.postToGroupDMs {
                                    Text("Enable “Post to group DMs” above first.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }

                            if config.automationDeliveryMode == .privateChannel {
                                Picker("Private channel", selection: Binding(
                                    get: { config.automationInboxChannelID ?? "" },
                                    set: { config.automationInboxChannelID = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text("Select a channel…").tag("")
                                    ForEach(channels.filter { !$0.isSelfDM && ($0.isChannel || $0.isPrivate) }) { ch in
                                        Text(ch.displayName).tag(ch.id)
                                    }
                                }
                                Button(inboxBusy ? "Creating…" : "Create private inbox channel") {
                                    inboxBusy = true
                                    Task {
                                        defer { inboxBusy = false }
                                        do {
                                            _ = try await bridge.createAutomationInbox(
                                                workspaceID: workspace.id,
                                                name: "agent-bridge-inbox"
                                            )
                                        } catch {
                                            presentAlert(title: "Could not create channel", message: error.localizedDescription)
                                        }
                                    }
                                }
                                .disabled(inboxBusy || !config.capabilities.postToChannels)
                                if !config.capabilities.postToChannels {
                                    Text("Enable “Post to channels” above first.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                                Text("Note: workspace admins may see private channels exist on some Slack plans.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }

                            if config.automationDeliveryMode == .localOnly {
                                Text("Digests appear under Automations → Last digest preview on this Mac only.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        Text("Channel").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Archive").frame(width: 64)
                        Text("Agent").frame(width: 56)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if filteredChannels.isEmpty {
                                Text("No channels match your search.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                            ForEach(filteredChannels) { ch in
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(ch.displayName)
                                                .font(.callout)
                                                .lineLimit(1)
                                            if ch.isSelfDM {
                                                Text("You")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                                            }
                                        }
                                        if let sub = ch.subtitle {
                                            Text(sub)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Toggle("", isOn: Binding(
                                        get: { config.archivedChannelIDs.contains(ch.id) },
                                        set: { on in
                                            config.setChannel(ch.id, archive: on, agent: nil)
                                        }
                                    ))
                                    .labelsHidden()
                                    .frame(width: 64)
                                    Toggle("", isOn: Binding(
                                        get: { config.agentChannelIDs.contains(ch.id) },
                                        set: { on in
                                            config.setChannel(ch.id, archive: nil, agent: on)
                                        }
                                    ))
                                    .labelsHidden()
                                    .frame(width: 56)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)

                    HStack {
                        Button("Archive selected → also allow agents") {
                            for id in config.archivedChannelIDs where !config.agentChannelIDs.contains(id) {
                                config.agentChannelIDs.append(id)
                            }
                        }
                        Button("Clear agent access") {
                            config.agentChannelIDs = []
                        }
                    }
                    .font(.caption)
                } else {
                    Text("Click Refresh channel list to load channels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Keep archived messages", selection: Binding(
                    get: { RetentionPreset.from(months: config.retentionMonths) },
                    set: { config.retentionMonths = $0.months }
                )) {
                    ForEach(RetentionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Text("Older messages are removed from this Mac only. Slack’s own Free-plan limit is unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Archive

struct ArchivePane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header("Archive", subtitle: "Local store with full-text search. Once a message is synced here, agents can find it even after Slack Free stops showing it in Slack.")

            GroupBox("How the 90-day Free limit works") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Slack Free does not let the app pull messages older than about 90 days from Slack’s servers. Those older messages cannot reappear inside the official Slack app.")
                        .font(.callout)
                    Text("This archive keeps a private copy of messages captured while they were still visible. Search them in Cursor/Claude via MCP, or export them — not by injecting old history back into Slack’s UI.")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            LabeledContent("Status", value: bridge.archiveSync.statusText)
            LabeledContent("Messages", value: "\(bridge.archiveMessageCount)")
            LabeledContent("Disk", value: byteSize(bridge.archiveSizeBytes))
            if let warn = bridge.storageWarning {
                Text(warn).foregroundStyle(.orange).font(.caption)
            }
            if let err = bridge.archiveSync.lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            Toggle("Pause archive sync", isOn: $settings.archivePaused)
            Stepper("Sync every \(settings.syncIntervalMinutes) minutes",
                    value: $settings.syncIntervalMinutes, in: 5...120, step: 5)
            Stepper("Re-read Slack session every \(settings.sessionRefreshHours) hours",
                    value: $settings.sessionRefreshHours, in: 1...24)

            Text("Retention is set per workspace under Workspaces. Default is 12 months so long archives do not fill the disk unnoticed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Sync now") {
                    Task { await bridge.archiveSync.syncAll(settings: settings, bridge: bridge) }
                }
                .disabled(bridge.archiveSync.isSyncing || !bridge.isConnected)

                Button("Apply retention now") {
                    for ws in bridge.workspaces {
                        if let months = settings.config(for: ws.id).retentionMonths {
                            MessageArchive.shared.applyRetention(workspaceID: ws.id, months: months)
                        }
                    }
                    bridge.refreshArchiveStats()
                }

                Button("Export archive…") { exportArchive() }
                Button("Wipe archive…", role: .destructive) { confirmWipe() }
            }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { bridge.refreshArchiveStats() }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "slack-agent-bridge-archive.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try MessageArchive.shared.exportJSON(to: url)
            } catch {
                presentAlert(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    private func confirmWipe() {
        let alert = NSAlert()
        alert.messageText = "Wipe local archive?"
        alert.informativeText = "This permanently deletes all cached messages on this Mac. Slack itself is not affected."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Wipe")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            MessageArchive.shared.wipeAll()
            bridge.refreshArchiveStats()
        }
    }
}

// MARK: - Automations

struct AutomationsPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController
    @State private var newName = "Daily digest"
    @State private var newHour = 9
    @State private var newMinute = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Automations", subtitle: "Local schedules. Digests use archived messages. Agents can also call send_dm_to_self and run_automation over MCP.")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Post digests and watches to Slack", isOn: $settings.digestPostToDM)
                    Text("Delivered per workspace “Automation delivery” setting: self-DM, group DM, private channel, or this Mac only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let err = bridge.automations.lastDeliveryError {
                        Text("Last DM delivery error: \(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("Send test note") {
                        Task {
                            guard let ws = bridge.workspaces.first(where: {
                                let c = settings.config(for: $0.id)
                                guard c.enabled else { return false }
                                switch c.automationDeliveryMode {
                                case .localOnly: return true
                                case .selfDM: return c.capabilities.postToMyDM
                                case .privateChannel: return c.capabilities.postToChannels
                                case .groupDM: return c.capabilities.postToGroupDMs
                                }
                            }) else {
                                presentAlert(title: "Enable delivery", message: "Configure Automation delivery under Workspaces and enable the matching capability.")
                                return
                            }
                            do {
                                try await bridge.automations.deliverAutomation(
                                    workspaceID: ws.id,
                                    text: "Slack Agent Bridge test note — delivery works. \(Date().formatted())",
                                    bridge: bridge
                                )
                                let mode = settings.config(for: ws.id).automationDeliveryMode
                                let dest: String
                                switch mode {
                                case .localOnly: dest = "Automations preview on this Mac"
                                case .selfDM: dest = "self-DM"
                                case .groupDM: dest = "group DM inbox"
                                case .privateChannel: dest = "private channel inbox"
                                }
                                presentAlert(title: mode == .localOnly ? "Saved locally" : "Sent", message: mode == .localOnly ? "Check Automations → Last digest preview." : "Check your \(dest) in \(ws.name).")
                            } catch {
                                presentAlert(title: "Delivery failed", message: error.localizedDescription)
                            }
                        }
                    }

                    if let preview = Optional(bridge.automations.lastDigestPreview), !preview.isEmpty {
                        Text("Last digest preview").font(.subheadline).foregroundStyle(.secondary)
                        ScrollView {
                            Text(preview).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Divider()
                    Text("Rules").font(.headline)
                    if settings.automations.isEmpty {
                        Text("No automation rules yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.automations) { rule in
                            HStack {
                                Toggle(isOn: bindingEnabled(rule.id)) {
                                    VStack(alignment: .leading) {
                                        Text(rule.name)
                                        Text("\(rule.kind.label) · \(rule.workspaceID) · \(String(format: "%02d:%02d", rule.hour, rule.minute))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Button("Run") {
                                    Task {
                                        switch rule.kind {
                                        case .dailyDigest:
                                            await bridge.automations.runDigest(rule: rule, settings: settings, bridge: bridge, post: settings.digestPostToDM)
                                        case .keywordWatch:
                                            await bridge.automations.runKeywordWatch(rule: rule, settings: settings, bridge: bridge)
                                        }
                                    }
                                }
                                Button("Remove", role: .destructive) {
                                    settings.automations.removeAll { $0.id == rule.id }
                                }
                            }
                        }
                    }

                    if let first = bridge.workspaces.first(where: { settings.config(for: $0.id).enabled }) {
                        HStack {
                            TextField("Name", text: $newName)
                            Stepper("Hour \(newHour)", value: $newHour, in: 0...23)
                            Stepper("Min \(newMinute)", value: $newMinute, in: 0...59, step: 5)
                            Button("Add daily digest") {
                                let rule = AutomationRule(
                                    id: UUID().uuidString,
                                    name: newName,
                                    enabled: true,
                                    kind: .dailyDigest,
                                    workspaceID: first.id,
                                    hour: newHour,
                                    minute: newMinute,
                                    keyword: nil,
                                    lastRunAt: nil
                                )
                                settings.automations.append(rule)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bindingEnabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.automations.first(where: { $0.id == id })?.enabled ?? false },
            set: { val in
                if let i = settings.automations.firstIndex(where: { $0.id == id }) {
                    settings.automations[i].enabled = val
                }
            }
        )
    }
}

// MARK: - Agent Access

private struct IssuedTokenSheetData: Identifiable {
    let id: String
    let name: String
    let token: String
}

struct AgentAccessPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController
    @State private var newTokenName = "Cursor"
    @State private var issuedSheet: IssuedTokenSheetData?
    @State private var statusMessage = ""
    @State private var cursorConfigBanner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Agent Access", subtitle: "Issue tokens for Cursor, Claude, or Cowork. Slack credentials never leave this Mac.")

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let token = cursorConfigBanner {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token changed — update your agent MCP config")
                            .font(.subheadline.weight(.semibold))
                        Text("Cursor: Settings → MCP → edit slack-agent-bridge → paste the new Bearer token, or replace the whole JSON below. Then reload MCP servers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy updated mcp.json") {
                                let snippet = bridge.tokens.mcpJSONSnippet(token: token, port: settings.mcpPort)
                                if PasteboardHelper.copy(snippet) {
                                    statusMessage = "Updated mcp.json copied — reload MCP in Cursor."
                                }
                            }
                            Button("Dismiss") { cursorConfigBanner = nil }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            if settings.isWizardActive {
                Text("Setup wizard: create a token below, then use Test connection in the wizard bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Enable MCP server", isOn: $settings.mcpServerEnabled)
                .onChange(of: settings.mcpServerEnabled) { _ in
                    bridge.restartMCPIfNeeded()
                }

            HStack {
                Text("Port")
                TextField("", value: $settings.mcpPort, format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") { bridge.restartMCPIfNeeded() }
                Text(bridge.mcpRunning ? "Listening" : "Stopped")
                    .foregroundStyle(bridge.mcpRunning ? .green : .secondary)
            }

            Divider()
            KeychainAlwaysAllowNote(compact: true)
            HStack {
                TextField("Token name", text: $newTokenName)
                    .textFieldStyle(.roundedBorder)
                Button("Create token") { createToken() }
            }

            if bridge.tokens.tokens.isEmpty {
                Text("No agent tokens yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(bridge.tokens.tokens) { token in
                            tokenRow(token)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            GroupBox("Cursor / Claude config") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("After create or rotate, copy mcp.json from the sheet. For stored tokens, use Copy JSON on the row (login password required).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mcpTemplateSnippet)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy template (placeholder)") {
                        if PasteboardHelper.copy(mcpTemplateSnippet) {
                            statusMessage = "Template copied — replace <your-token> with your agent token."
                        }
                    }
                }
                .padding(4)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $issuedSheet) { data in
            TokenIssuedSheet(
                data: data,
                port: settings.mcpPort,
                mcpJSON: bridge.tokens.mcpJSONSnippet(token: data.token, port: settings.mcpPort),
                onDismiss: {
                    bridge.tokens.clearIssued()
                    issuedSheet = nil
                }
            )
        }
        .onChange(of: settings.wizardRequestCreateToken) { requested in
            if requested {
                settings.wizardRequestCreateToken = false
                createToken()
            }
        }
        .onChange(of: bridge.tokens.lastIssuedPlaintext?.id) { _ in
            presentIssuedSheetIfNeeded()
        }
        .onAppear {
            presentIssuedSheetIfNeeded()
        }
    }

    private var mcpTemplateSnippet: String {
        bridge.tokens.mcpJSONSnippet(token: "<your-token>", port: settings.mcpPort)
    }

    @ViewBuilder
    private func tokenRow(_ token: AgentTokenRecord) -> some View {
        let canCopyLater = bridge.tokens.hasStoredPlaintext(id: token.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(token.name).font(.headline)
                Spacer()
                Text(token.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Workspaces: \(token.workspaceIDs.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            if !canCopyLater {
                Text("This token was created before secure storage. Rotate to issue a new token you can copy anytime (login password required).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if canCopyLater {
                    Button("Copy token") { copyToken(token) }
                    Button("Copy JSON") { copyJSON(token) }
                    Button("Edit") { editToken(token) }
                    Button("Rotate") { rotateToken(token) }
                } else {
                    Button("Rotate & copy") { rotateToken(token) }
                    Button("Edit") { editToken(token) }
                }
                Button("Revoke", role: .destructive) {
                    bridge.tokens.revoke(id: token.id)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func presentIssuedSheetIfNeeded() {
        guard let issued = bridge.tokens.lastIssuedPlaintext else { return }
        issuedSheet = IssuedTokenSheetData(id: issued.id, name: issued.name, token: issued.token)
    }

    private func createToken() {
        let enabledIDs = bridge.workspaces
            .filter { settings.config(for: $0.id).enabled }
            .map(\.id)
        guard !enabledIDs.isEmpty else {
            presentAlert(title: "Enable a workspace first", message: "Agent tokens are scoped to workspaces you have enabled.")
            return
        }
        let caps = intersectionCapabilities(for: enabledIDs)
        let plaintext = bridge.tokens.create(name: newTokenName, workspaceIDs: enabledIDs, capabilities: caps)
        issuedSheet = IssuedTokenSheetData(
            id: bridge.tokens.lastIssuedPlaintext?.id ?? UUID().uuidString,
            name: newTokenName,
            token: plaintext
        )
        cursorConfigBanner = plaintext
        statusMessage = "Token created — copy it from the sheet."
    }

    private func rotateToken(_ token: AgentTokenRecord) {
        guard let plaintext = bridge.tokens.rotate(id: token.id) else { return }
        issuedSheet = IssuedTokenSheetData(id: token.id, name: token.name, token: plaintext)
        cursorConfigBanner = plaintext
        statusMessage = "Token rotated — update Cursor MCP config, then copy from the sheet or banner."
    }

    private func copyToken(_ token: AgentTokenRecord) {
        guard bridge.tokens.hasStoredPlaintext(id: token.id) else { return }
        Task {
            switch await bridge.tokens.revealPlaintext(
                id: token.id,
                reason: "Unlock to copy agent token \"\(token.name)\""
            ) {
            case .revealed(let plaintext):
                await MainActor.run {
                    if PasteboardHelper.copy(plaintext) {
                        statusMessage = "Token copied to clipboard."
                    } else {
                        presentAlert(title: "Copy failed", message: "Could not write to the clipboard.")
                    }
                }
            case .notStored, .cancelled:
                break
            }
        }
    }

    private func copyJSON(_ token: AgentTokenRecord) {
        guard bridge.tokens.hasStoredPlaintext(id: token.id) else { return }
        Task {
            switch await bridge.tokens.revealPlaintext(
                id: token.id,
                reason: "Unlock to copy MCP config for \"\(token.name)\""
            ) {
            case .revealed(let plaintext):
                let snippet = bridge.tokens.mcpJSONSnippet(token: plaintext, port: settings.mcpPort)
                await MainActor.run {
                    if PasteboardHelper.copy(snippet) {
                        statusMessage = "mcp.json snippet copied to clipboard."
                    } else {
                        presentAlert(title: "Copy failed", message: "Could not write to the clipboard.")
                    }
                }
            case .notStored, .cancelled:
                break
            }
        }
    }

    private func editToken(_ token: AgentTokenRecord) {
        Task {
            guard await DeviceAuth.authenticate(reason: "Unlock to edit agent token \"\(token.name)\"") else { return }
            await MainActor.run { renameToken(token) }
        }
    }

    private func intersectionCapabilities(for enabledIDs: [String]) -> WorkspaceCapabilities {
        var caps = WorkspaceCapabilities(
            readChannels: true, archiveChannels: true, postToMyDM: true, postToDMs: true, postToChannels: true, postToGroupDMs: true,
            setReminders: true, setStatus: true, addReactions: true, pinMessages: true,
            scheduleMessages: true, editMessages: true, deleteMessages: true, removeReactions: true, unpinMessages: true
        )
        for id in enabledIDs {
            let c = settings.config(for: id).capabilities
            caps.readChannels = caps.readChannels && c.readChannels
            caps.archiveChannels = caps.archiveChannels && c.archiveChannels
            caps.postToMyDM = caps.postToMyDM && c.postToMyDM
            caps.postToDMs = caps.postToDMs && c.postToDMs
            caps.postToChannels = caps.postToChannels && c.postToChannels
            caps.postToGroupDMs = caps.postToGroupDMs && c.postToGroupDMs
            caps.setReminders = caps.setReminders && c.setReminders
            caps.setStatus = caps.setStatus && c.setStatus
            caps.addReactions = caps.addReactions && c.addReactions
            caps.pinMessages = caps.pinMessages && c.pinMessages
            caps.scheduleMessages = caps.scheduleMessages && c.scheduleMessages
            caps.editMessages = caps.editMessages && c.editMessages
            caps.deleteMessages = caps.deleteMessages && c.deleteMessages
            caps.removeReactions = caps.removeReactions && c.removeReactions
            caps.unpinMessages = caps.unpinMessages && c.unpinMessages
        }
        return caps
    }

    private func renameToken(_ token: AgentTokenRecord) {
        let alert = NSAlert()
        alert.messageText = "Edit token"
        alert.informativeText = "Change the display name for this agent access token."
        let field = NSTextField(string: token.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            bridge.tokens.rename(id: token.id, name: field.stringValue)
            statusMessage = "Token renamed."
        }
    }
}

private struct TokenIssuedSheet: View {
    let data: IssuedTokenSheetData
    let port: Int
    let mcpJSON: String
    let onDismiss: () -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent token ready")
                .font(.title2.weight(.semibold))
            Text("Copy the token or full mcp.json snippet now. Tokens created on this Mac can be copied again later from the token row (login password required).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(data.name).font(.headline)

            Text("Token")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(data.token)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            Text("mcp.json")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(mcpJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(.green)
            }

            HStack {
                Button("Copy token") {
                    if PasteboardHelper.copy(data.token) {
                        feedback = "Token copied."
                    }
                }
                Button("Copy mcp.json") {
                    if PasteboardHelper.copy(mcpJSON) {
                        feedback = "mcp.json copied."
                    }
                }
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

// MARK: - Privacy

struct PrivacyPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Privacy & Advanced", subtitle: "Everything stays on this Mac. The app talks only to slack.com over HTTPS.")

            GroupBox("Data") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session credentials: macOS Keychain (this device only)")
                    Text("Agent tokens: hashed in Keychain")
                    Text(KeychainGuidance.alwaysAllowBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Message archive: \(MessageArchive.shared.databaseURL.path)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Button("Replay Quick Setup tour") {
                settings.startTour()
            }

            GroupBox("Local CLI (advanced)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Allow CLI send via SAB_SEND_TEXT", isOn: $settings.allowHeadlessCLI)
                    Text("Off by default. When enabled, any local process on this Mac can post to Slack using environment variables — only turn on if you trust scripts on this machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Verbose logging is off by default. Set environment variable SLACKAGENT_DEBUG=1 to enable.")
                        .font(.callout)
                    Text("Signing: ad-hoc (no Apple Developer Program). First open may require right-click → Open.")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("History honesty") {
                Text("On Slack Free, messages older than about 90 days will not reappear in the Slack app. This product archives them locally for search, digests, and agents. See the Archive pane and docs/FREE_TIER_AND_RETENTION.md.")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            Button("Clear Slack session from Keychain", role: .destructive) {
                bridge.disconnect()
            }
            Button("Revoke all agent tokens", role: .destructive) {
                let ids = bridge.tokens.tokens.map(\.id)
                for t in bridge.tokens.tokens { bridge.tokens.revoke(id: t.id) }
                AgentTokenPlaintextStore.clearAll(tokenIDs: ids)
                AgentTokenKeychain.clear()
                bridge.tokens.reload()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared helpers

private func header(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.weight(.semibold))
        Text(subtitle).foregroundStyle(.secondary)
    }
}

private func byteSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func presentAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
}
