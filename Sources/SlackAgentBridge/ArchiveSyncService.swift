import Foundation
import AppKit

/// Syncs selected channels into the local archive with rate-limit backoff.
@MainActor
final class ArchiveSyncService: ObservableObject {
    @Published var isSyncing = false
    @Published var statusText = "Idle"
    @Published var lastError: String?

    private let api = SlackAPIClient()
    private let archive = MessageArchive.shared
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func start(settings: Settings, bridge: BridgeController) {
        stop()
        schedule(settings: settings, bridge: bridge)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.syncAll(settings: settings, bridge: bridge)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func schedule(settings: Settings, bridge: BridgeController) {
        let interval = TimeInterval(max(5, settings.syncIntervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncAll(settings: settings, bridge: bridge)
            }
        }
        Task { await syncAll(settings: settings, bridge: bridge) }
    }

    func syncAll(settings: Settings, bridge: BridgeController) async {
        guard !settings.archivePaused else {
            statusText = "Paused"
            return
        }
        guard !isSyncing else { return }
        guard let account = bridge.account else {
            statusText = "Not connected"
            return
        }

        isSyncing = true
        statusText = "Syncing…"
        lastError = nil
        defer { isSyncing = false }

        for workspace in account.workspaces {
            let config = settings.config(for: workspace.id)
            guard config.enabled, config.capabilities.archiveChannels else { continue }
            guard !config.archivedChannelIDs.isEmpty else { continue }

            archive.upsertWorkspace(id: workspace.id, name: workspace.name, url: workspace.url)

            for channelID in config.archivedChannelIDs {
                do {
                    try await syncChannel(
                        workspace: workspace,
                        channelID: channelID,
                        cookie: account.cookieHeader
                    )
                    if let months = config.retentionMonths {
                        archive.applyRetention(workspaceID: workspace.id, months: months)
                    }
                } catch SlackError.rateLimited(let retry) {
                    let wait = retry ?? 5
                    statusText = "Rate limited — waiting \(Int(wait))s"
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch SlackError.authExpired {
                    _ = await bridge.refreshLocalSession(forceCookieRefresh: true)
                    lastError = "Session expired; refreshed."
                    statusText = lastError ?? "Error"
                    return
                } catch {
                    lastError = error.localizedDescription
                    Log.info("Archive sync error: \(error.localizedDescription)")
                }
            }
        }

        if let last = archive.lastSyncDate() {
            let formatter = RelativeDateTimeFormatter()
            statusText = "Last sync \(formatter.localizedString(for: last, relativeTo: Date()))"
        } else {
            statusText = "Synced"
        }
        bridge.refreshArchiveStats()
        // Apply retention after a full pass so disk stays within user preference.
        for workspace in account.workspaces {
            let config = settings.config(for: workspace.id)
            if let months = config.retentionMonths {
                archive.applyRetention(workspaceID: workspace.id, months: months)
            }
        }
        bridge.refreshArchiveStats()
    }

    private func syncChannel(workspace: SlackWorkspace, channelID: String, cookie: String) async throws {
        statusText = "Syncing \(workspace.name) / \(channelID)"
        var cursorState = archive.syncCursor(workspaceID: workspace.id, channelID: channelID)

        // Incremental: fetch newer than newest_synced
        if let newest = cursorState.newestSynced {
            try await pageHistory(
                workspace: workspace,
                channelID: channelID,
                cookie: cookie,
                oldest: newest,
                updateNewest: true,
                updateOldest: false,
                markBackfill: cursorState.backfillDone
            )
            cursorState = archive.syncCursor(workspaceID: workspace.id, channelID: channelID)
        }

        // Backfill until Slack returns empty (Free tier ~90 days horizon)
        if !cursorState.backfillDone {
            var latest: String? = cursorState.oldestSynced
            var emptyPages = 0
            while emptyPages < 1 {
                let beforeCount = archive.messageCount()
                try await pageHistory(
                    workspace: workspace,
                    channelID: channelID,
                    cookie: cookie,
                    latest: latest,
                    updateNewest: cursorState.newestSynced == nil,
                    updateOldest: true,
                    markBackfill: false
                )
                let afterCount = archive.messageCount()
                let updated = archive.syncCursor(workspaceID: workspace.id, channelID: channelID)
                if afterCount == beforeCount || updated.oldestSynced == latest {
                    emptyPages += 1
                    archive.updateSyncCursor(
                        workspaceID: workspace.id,
                        channelID: channelID,
                        oldest: updated.oldestSynced,
                        newest: updated.newestSynced,
                        backfillDone: true
                    )
                    break
                }
                latest = updated.oldestSynced
            }
        }
    }

    private func pageHistory(
        workspace: SlackWorkspace,
        channelID: String,
        cookie: String,
        latest: String? = nil,
        oldest: String? = nil,
        updateNewest: Bool,
        updateOldest: Bool,
        markBackfill: Bool
    ) async throws {
        var pageCursor: String?
        var fetched: [SlackMessage] = []
        repeat {
            let result = try await api.history(
                channelID: channelID,
                token: workspace.token,
                cookie: cookie,
                latest: latest,
                oldest: oldest,
                cursor: pageCursor
            )
            for raw in result.messages {
                if let msg = api.parseHistoryMessage(raw, workspaceID: workspace.id, channelID: channelID) {
                    fetched.append(msg)
                    // Pull thread replies when present
                    if msg.replyCount > 0, let threadTs = msg.threadTs ?? Optional(msg.ts) {
                        try await fetchThread(
                            workspace: workspace,
                            channelID: channelID,
                            threadTs: threadTs,
                            cookie: cookie
                        )
                    }
                }
            }
            pageCursor = result.nextCursor
        } while pageCursor != nil

        archive.upsertMessages(fetched)

        let timestamps = fetched.map(\.ts).compactMap { Double($0) }
        let existing = archive.syncCursor(workspaceID: workspace.id, channelID: channelID)
        var newest = existing.newestSynced
        var oldestSynced = existing.oldestSynced
        if let maxTS = timestamps.max() {
            let s = String(maxTS)
            if updateNewest {
                if let n = newest, let nd = Double(n), maxTS > nd { newest = s }
                else if newest == nil { newest = s }
            }
        }
        if let minTS = timestamps.min() {
            let s = String(minTS)
            if updateOldest {
                if let o = oldestSynced, let od = Double(o), minTS < od { oldestSynced = s }
                else if oldestSynced == nil { oldestSynced = s }
            }
        }
        // First sync with messages: set newest from max
        if newest == nil, let maxTS = timestamps.max() {
            newest = String(maxTS)
        }
        archive.updateSyncCursor(
            workspaceID: workspace.id,
            channelID: channelID,
            oldest: oldestSynced,
            newest: newest,
            backfillDone: markBackfill || existing.backfillDone
        )
    }

    private func fetchThread(workspace: SlackWorkspace, channelID: String,
                             threadTs: String, cookie: String) async throws {
        var pageCursor: String?
        var fetched: [SlackMessage] = []
        repeat {
            let result = try await api.replies(
                channelID: channelID,
                threadTs: threadTs,
                token: workspace.token,
                cookie: cookie,
                cursor: pageCursor
            )
            for raw in result.messages {
                if let msg = api.parseHistoryMessage(raw, workspaceID: workspace.id, channelID: channelID) {
                    fetched.append(msg)
                }
            }
            pageCursor = result.nextCursor
        } while pageCursor != nil
        archive.upsertMessages(fetched)
    }
}
