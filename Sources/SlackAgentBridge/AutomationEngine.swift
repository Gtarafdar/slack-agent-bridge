import Foundation

/// Local automations: daily digest, keyword watch, task drafting.
@MainActor
final class AutomationEngine: ObservableObject {
    @Published var lastDigestPreview: String = ""
    @Published var lastDeliveryError: String?

    private var timer: Timer?
    private let api = SlackAPIClient()

    func start(settings: Settings, bridge: BridgeController) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.tick(settings: settings, bridge: bridge)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(settings: Settings, bridge: BridgeController) async {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        for rule in settings.automations where rule.enabled {
            switch rule.kind {
            case .dailyDigest:
                if rule.hour == hour, rule.minute == minute {
                    let already = rule.lastRunAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
                    if !already {
                        await runDigest(rule: rule, settings: settings, bridge: bridge, post: settings.digestPostToDM)
                    }
                }
            case .keywordWatch:
                await runKeywordWatch(rule: rule, settings: settings, bridge: bridge)
            }
        }
    }

    func runDigest(rule: AutomationRule, settings: Settings, bridge: BridgeController, post: Bool) async {
        let since = Date().addingTimeInterval(-24 * 3600)
        let channelIDs = settings.config(for: rule.workspaceID).archivedChannelIDs
        let messages = MessageArchive.shared.messagesSince(
            workspaceID: rule.workspaceID,
            since: since,
            channelIDs: channelIDs.isEmpty ? nil : channelIDs
        )
        let tasks = draftTasks(from: messages, workspaceID: rule.workspaceID)
        for task in tasks {
            if !settings.localTasks.contains(where: { $0.sourceTs == task.sourceTs && $0.sourceChannelID == task.sourceChannelID }) {
                settings.localTasks.insert(task, at: 0)
            }
        }

        let preview = formatDigest(messages: messages, tasks: tasks, workspaceName: bridge.workspace(for: rule.workspaceID)?.name ?? rule.workspaceID)
        lastDigestPreview = preview

        if post {
            do {
                try await deliverAutomation(workspaceID: rule.workspaceID, text: preview, bridge: bridge)
                lastDeliveryError = nil
            } catch {
                lastDeliveryError = error.localizedDescription
                Log.info("Digest delivery failed: \(error.localizedDescription)")
            }
        } else if bridge.settings.config(for: rule.workspaceID).automationDeliveryMode == .localOnly {
            lastDeliveryError = nil
        }

        if let idx = settings.automations.firstIndex(where: { $0.id == rule.id }) {
            settings.automations[idx].lastRunAt = Date()
        }
        MessageArchive.shared.appendAudit(actor: "automation", action: "digest.run", detail: rule.name)
    }

    func runKeywordWatch(rule: AutomationRule, settings: Settings, bridge: BridgeController) async {
        guard let keyword = rule.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
              !keyword.isEmpty else { return }
        let since = rule.lastRunAt ?? Date().addingTimeInterval(-3600)
        let hits = MessageArchive.shared.messagesSince(workspaceID: rule.workspaceID, since: since)
            .filter { $0.text.localizedCaseInsensitiveContains(keyword) }
        guard !hits.isEmpty else { return }

        let text = """
        Keyword watch: "\(keyword)"
        \(hits.prefix(10).map { "- [#\($0.channelID)] \($0.text.prefix(120))" }.joined(separator: "\n"))
        """
        if settings.digestPostToDM {
            do {
                try await deliverAutomation(workspaceID: rule.workspaceID, text: text, bridge: bridge)
                lastDeliveryError = nil
            } catch {
                lastDeliveryError = error.localizedDescription
            }
        }
        if let idx = settings.automations.firstIndex(where: { $0.id == rule.id }) {
            settings.automations[idx].lastRunAt = Date()
        }
    }

    func draftTasks(from messages: [SlackMessage], workspaceID: String) -> [LocalTask] {
        let patterns = ["please", "can you", "todo", "to-do", "action item", "follow up", "deadline", "remind"]
        var tasks: [LocalTask] = []
        for msg in messages {
            let lower = msg.text.lowercased()
            guard patterns.contains(where: { lower.contains($0) }) else { continue }
            let title = String(msg.text.prefix(160))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            tasks.append(LocalTask(
                id: UUID().uuidString,
                workspaceID: workspaceID,
                title: title,
                sourceChannelID: msg.channelID,
                sourceTs: msg.ts,
                createdAt: Date(),
                completed: false
            ))
        }
        return tasks
    }

    func formatDigest(messages: [SlackMessage], tasks: [LocalTask], workspaceName: String) -> String {
        var lines: [String] = []
        lines.append("Daily Slack digest — \(workspaceName)")
        lines.append("Messages in last 24h: \(messages.count)")
        if !tasks.isEmpty {
            lines.append("")
            lines.append("Suggested tasks:")
            for task in tasks.prefix(15) {
                lines.append("- \(task.title)")
            }
        }
        let unanswered = messages.filter {
            $0.text.contains("?") && $0.replyCount == 0 && $0.threadTs == nil
        }
        if !unanswered.isEmpty {
            lines.append("")
            lines.append("Possible unanswered questions:")
            for msg in unanswered.prefix(10) {
                lines.append("- [#\(msg.channelID)] \(msg.text.prefix(120))")
            }
        }
        if messages.isEmpty {
            lines.append("No archived messages in the selected channels for the last 24 hours.")
        }
        lines.append("")
        lines.append("Generated locally by Slack Agent Bridge.")
        return lines.joined(separator: "\n")
    }

    func formatChannelDigest(
        messages: [SlackMessage],
        channelName: String,
        workspaceName: String,
        hours: Int,
        highlightUserID: String?,
        highlightLabel: String?,
        userLabel: (String) -> String
    ) -> String {
        var lines: [String] = []
        lines.append("Channel summary — #\(channelName) (\(workspaceName))")
        lines.append("Window: last \(hours)h · \(messages.count) message(s)")
        if let highlightUserID, let highlightLabel {
            let fromUser = messages.filter { $0.userID == highlightUserID }
            lines.append("")
            lines.append("From \(highlightLabel): \(fromUser.count) message(s)")
            for msg in fromUser.prefix(25) {
                let when = ISO8601DateFormatter().string(from: msg.date)
                lines.append("- [\(when)] \(plainPreview(msg.text, userLabel: userLabel))")
            }
        }
        lines.append("")
        lines.append("Recent activity:")
        for msg in messages.prefix(40) {
            let who = msg.userID.map(userLabel) ?? "unknown"
            let when = ISO8601DateFormatter().string(from: msg.date)
            lines.append("- [\(when)] \(who): \(plainPreview(msg.text, userLabel: userLabel))")
        }
        if messages.isEmpty {
            lines.append("(No messages in archive for this channel and time window.)")
        }
        lines.append("")
        lines.append("Generated locally by Slack Agent Bridge.")
        return lines.joined(separator: "\n")
    }

    private func plainPreview(_ text: String, userLabel: (String) -> String) -> String {
        var out = text
        let pattern = #"<@([A-Z0-9]+)>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1 else { continue }
                let uid = ns.substring(with: match.range(at: 1))
                let label = userLabel(uid)
                out = (out as NSString).replacingCharacters(in: match.range, with: "@\(label)")
            }
        }
        if out.count > 200 { return String(out.prefix(200)) + "…" }
        return out
    }

    /// Posts automations per workspace delivery mode.
    func deliverAutomation(workspaceID: String, text: String, bridge: BridgeController) async throws {
        let config = bridge.settings.config(for: workspaceID)
        guard config.enabled else { throw SlackError.api("workspace_disabled") }

        switch config.automationDeliveryMode {
        case .localOnly:
            return
        case .selfDM:
            try await sendToSelfDM(workspaceID: workspaceID, text: text, bridge: bridge)
        case .privateChannel, .groupDM:
            guard let creds = bridge.credentials(for: workspaceID) else { throw SlackError.notConnected }
            guard let inbox = config.automationInboxChannelID, !inbox.isEmpty else {
                try await sendToSelfDM(workspaceID: workspaceID, text: text, bridge: bridge)
                await notifyAutomationDelivery(workspaceID: workspaceID, text: text, bridge: bridge)
                return
            }
            if config.automationDeliveryMode == .privateChannel {
                guard config.capabilities.postToChannels else {
                    throw SlackError.api("capability_denied_post_to_channels")
                }
            } else {
                guard config.capabilities.postToGroupDMs else {
                    throw SlackError.api("capability_denied_post_to_group_dms")
                }
            }
            _ = try await api.postMessage(
                channelID: inbox, text: text, token: creds.token, cookie: creds.cookie
            )
        }
        await notifyAutomationDelivery(workspaceID: workspaceID, text: text, bridge: bridge)
    }

    /// Mac + Slackbot reminders after any automation / agent message lands in Slack.
    func notifyAutomationDelivery(
        workspaceID: String,
        text: String,
        bridge: BridgeController,
        channelIDOverride: String? = nil,
        labelOverride: String? = nil
    ) async {
        let config = bridge.settings.config(for: workspaceID)
        guard config.macNotifyOnAutomation || config.slackReminderOnAutomation else { return }
        if config.automationDeliveryMode == .localOnly && channelIDOverride == nil { return }

        let wsName = bridge.workspace(for: workspaceID)?.name ?? workspaceID
        let label: String
        let channelID: String?
        if let labelOverride, let channelIDOverride {
            label = labelOverride
            channelID = channelIDOverride
        } else {
            switch config.automationDeliveryMode {
            case .groupDM, .privateChannel:
                label = config.automationInboxLabel
                channelID = config.automationInboxChannelID
            case .selfDM:
                label = "Personal DM"
                channelID = bridge.settings.identities[workspaceID]?.selfDMChannelID
            case .localOnly:
                return
            }
        }

        if config.macNotifyOnAutomation {
            await DeliveryNotifier.notifyAutomationDelivered(
                workspaceName: wsName,
                preview: text,
                inboxLabel: label,
                teamID: workspaceID,
                channelID: channelID
            )
        }

        if config.slackReminderOnAutomation, config.capabilities.setReminders,
           let creds = bridge.credentials(for: workspaceID) {
            let snippet = text
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? text
            let reminderText = "Agent Bridge (\(label)): \(String(snippet.prefix(100)))"
            try? await api.addReminder(
                text: reminderText,
                time: "in 1 minute",
                token: creds.token,
                cookie: creds.cookie
            )
        }
    }

    /// Resolves the signed-in user via auth.test, opens a self IM, caches both, then posts.
    /// This is how digests and MCP `send_dm_to_self` reach "you" — never other users.
    func sendToSelfDM(workspaceID: String, text: String, bridge: BridgeController) async throws {
        let config = bridge.settings.config(for: workspaceID)
        guard config.enabled, config.capabilities.postToMyDM else {
            throw SlackError.api("capability_denied_post_to_dm")
        }
        guard let creds = bridge.credentials(for: workspaceID) else {
            throw SlackError.notConnected
        }

        let identity = try await bridge.resolveSelfIdentity(workspaceID: workspaceID, forceRefresh: false)
        let channelID: String
        if let cached = identity.selfDMChannelID, !cached.isEmpty {
            channelID = cached
        } else {
            channelID = try await api.openIM(userID: identity.userID, token: creds.token, cookie: creds.cookie)
            bridge.cacheSelfDMChannel(workspaceID: workspaceID, channelID: channelID)
        }

        do {
            _ = try await api.postMessage(channelID: channelID, text: text, token: creds.token, cookie: creds.cookie)
        } catch SlackError.authExpired {
            _ = await bridge.refreshLocalSession(forceCookieRefresh: true)
            let refreshed = try await bridge.resolveSelfIdentity(workspaceID: workspaceID, forceRefresh: true)
            guard let newCreds = bridge.credentials(for: workspaceID) else { throw SlackError.notConnected }
            let ch = try await api.openIM(userID: refreshed.userID, token: newCreds.token, cookie: newCreds.cookie)
            bridge.cacheSelfDMChannel(workspaceID: workspaceID, channelID: ch)
            _ = try await api.postMessage(channelID: ch, text: text, token: newCreds.token, cookie: newCreds.cookie)
        } catch SlackError.api(let code) where code.contains("channel") || code == "channel_not_found" {
            // Stale IM id after workspace change — reopen.
            let refreshed = try await bridge.resolveSelfIdentity(workspaceID: workspaceID, forceRefresh: true)
            guard let newCreds = bridge.credentials(for: workspaceID) else { throw SlackError.notConnected }
            let ch = try await api.openIM(userID: refreshed.userID, token: newCreds.token, cookie: newCreds.cookie)
            bridge.cacheSelfDMChannel(workspaceID: workspaceID, channelID: ch)
            _ = try await api.postMessage(channelID: ch, text: text, token: newCreds.token, cookie: newCreds.cookie)
        }
    }

    func createSlackReminder(workspaceID: String, text: String, time: String, bridge: BridgeController) async throws -> String {
        let config = bridge.settings.config(for: workspaceID)
        guard config.enabled, config.capabilities.setReminders else {
            throw SlackError.api("capability_denied_reminders")
        }
        guard let creds = bridge.credentials(for: workspaceID) else {
            throw SlackError.notConnected
        }
        do {
            return try await api.addReminder(text: text, time: time, token: creds.token, cookie: creds.cookie)
        } catch SlackError.authExpired {
            _ = await bridge.refreshLocalSession(forceCookieRefresh: true)
            guard let newCreds = bridge.credentials(for: workspaceID) else { throw SlackError.notConnected }
            return try await api.addReminder(text: text, time: time, token: newCreds.token, cookie: newCreds.cookie)
        }
    }

    func setStatus(workspaceID: String, text: String, emoji: String, expiration: Int, bridge: BridgeController) async throws {
        let config = bridge.settings.config(for: workspaceID)
        guard config.enabled, config.capabilities.setStatus else {
            throw SlackError.api("capability_denied_status")
        }
        guard let creds = bridge.credentials(for: workspaceID) else {
            throw SlackError.notConnected
        }
        do {
            try await api.setStatus(text: text, emoji: emoji, expiration: expiration, token: creds.token, cookie: creds.cookie)
        } catch SlackError.authExpired {
            _ = await bridge.refreshLocalSession(forceCookieRefresh: true)
            guard let newCreds = bridge.credentials(for: workspaceID) else { throw SlackError.notConnected }
            try await api.setStatus(text: text, emoji: emoji, expiration: expiration, token: newCreds.token, cookie: newCreds.cookie)
        }
    }
}
