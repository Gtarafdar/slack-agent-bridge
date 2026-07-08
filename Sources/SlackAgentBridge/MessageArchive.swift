import Foundation
import SQLite3

/// Local message archive with FTS5 search. Survives Slack Free 90-day visibility.
final class MessageArchive {
    static let shared = MessageArchive()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.slackagentbridge.archive", qos: .utility)

    var supportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SlackAgentBridge", isDirectory: true)
        SecureStorage.hardenDirectory(at: base)
        return base
    }

    var databaseURL: URL {
        supportDirectory.appendingPathComponent("archive.sqlite")
    }

    private init() {
        open()
        migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func open() {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            Log.error("Failed to open archive database")
            db = nil
            return
        }
        SecureStorage.hardenFile(at: databaseURL)
    }

    private func migrate() {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                url TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS channels (
                workspace_id TEXT NOT NULL,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                is_im INTEGER DEFAULT 0,
                is_mpim INTEGER DEFAULT 0,
                is_private INTEGER DEFAULT 0,
                PRIMARY KEY (workspace_id, id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS users (
                workspace_id TEXT NOT NULL,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                real_name TEXT,
                display_name TEXT,
                tz TEXT,
                is_bot INTEGER DEFAULT 0,
                PRIMARY KEY (workspace_id, id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS messages (
                workspace_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                ts TEXT NOT NULL,
                thread_ts TEXT,
                user_id TEXT,
                text TEXT NOT NULL,
                reply_count INTEGER DEFAULT 0,
                subtype TEXT,
                ingested_at REAL NOT NULL,
                PRIMARY KEY (workspace_id, channel_id, ts)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sync_cursors (
                workspace_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                oldest_synced TEXT,
                newest_synced TEXT,
                backfill_done INTEGER DEFAULT 0,
                last_sync_at REAL,
                PRIMARY KEY (workspace_id, channel_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                detail TEXT
            )
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                workspace_id UNINDEXED,
                channel_id UNINDEXED,
                ts UNINDEXED,
                user_id UNINDEXED,
                text,
                content='messages',
                content_rowid='rowid'
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, workspace_id, channel_id, ts, user_id, text)
                VALUES (new.rowid, new.workspace_id, new.channel_id, new.ts, new.user_id, new.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, workspace_id, channel_id, ts, user_id, text)
                VALUES ('delete', old.rowid, old.workspace_id, old.channel_id, old.ts, old.user_id, old.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, workspace_id, channel_id, ts, user_id, text)
                VALUES ('delete', old.rowid, old.workspace_id, old.channel_id, old.ts, old.user_id, old.text);
                INSERT INTO messages_fts(rowid, workspace_id, channel_id, ts, user_id, text)
                VALUES (new.rowid, new.workspace_id, new.channel_id, new.ts, new.user_id, new.text);
            END
            """
        ]
        for sql in statements {
            exec(sql)
        }
    }

    // MARK: - Upserts

    func upsertWorkspace(id: String, name: String, url: String?) {
        queue.sync {
            exec("INSERT INTO workspaces(id,name,url) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, url=excluded.url",
                 bind: { stmt in
                self.bindText(stmt, 1, id)
                self.bindText(stmt, 2, name)
                self.bindText(stmt, 3, url)
            })
        }
    }

    func upsertChannel(_ channel: SlackChannel, workspaceID: String) {
        let storedName = channel.isIM || channel.isMPIM ? channel.displayName : channel.name
        queue.sync {
            exec("""
                INSERT INTO channels(workspace_id,id,name,is_im,is_mpim,is_private)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(workspace_id,id) DO UPDATE SET name=excluded.name
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channel.id)
                self.bindText(stmt, 3, storedName)
                sqlite3_bind_int(stmt, 4, channel.isIM ? 1 : 0)
                sqlite3_bind_int(stmt, 5, channel.isMPIM ? 1 : 0)
                sqlite3_bind_int(stmt, 6, channel.isPrivate ? 1 : 0)
            })
        }
    }

    /// Human-readable channel label from the local archive (survives app restarts).
    func channelName(workspaceID: String, channelID: String) -> String? {
        queue.sync {
            var name: String?
            query("""
                SELECT name FROM channels WHERE workspace_id=? AND id=? LIMIT 1
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
            }, row: { stmt in
                name = self.textColumn(stmt, 0)
            })
            return name
        }
    }

    func upsertUser(_ user: SlackUser, workspaceID: String) {
        queue.sync {
            exec("""
                INSERT INTO users(workspace_id,id,name,real_name,display_name,tz,is_bot)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(workspace_id,id) DO UPDATE SET
                    name=excluded.name, real_name=excluded.real_name,
                    display_name=excluded.display_name, tz=excluded.tz
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, user.id)
                self.bindText(stmt, 3, user.name)
                self.bindText(stmt, 4, user.realName)
                self.bindText(stmt, 5, user.displayName)
                self.bindText(stmt, 6, user.tz)
                sqlite3_bind_int(stmt, 7, user.isBot ? 1 : 0)
            })
        }
    }

    func upsertMessages(_ messages: [SlackMessage]) {
        guard !messages.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for message in messages {
                exec("""
                    INSERT INTO messages(workspace_id,channel_id,ts,thread_ts,user_id,text,reply_count,subtype,ingested_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(workspace_id,channel_id,ts) DO UPDATE SET
                        text=excluded.text, reply_count=excluded.reply_count, thread_ts=excluded.thread_ts
                    """, bind: { stmt in
                    self.bindText(stmt, 1, message.workspaceID)
                    self.bindText(stmt, 2, message.channelID)
                    self.bindText(stmt, 3, message.ts)
                    self.bindText(stmt, 4, message.threadTs)
                    self.bindText(stmt, 5, message.userID)
                    self.bindText(stmt, 6, message.text)
                    sqlite3_bind_int(stmt, 7, Int32(message.replyCount))
                    self.bindText(stmt, 8, message.subtype)
                    sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
                })
            }
            exec("COMMIT")
        }
    }

    // MARK: - Sync cursors

    struct SyncCursor {
        var oldestSynced: String?
        var newestSynced: String?
        var backfillDone: Bool
        var lastSyncAt: Date?
    }

    func syncCursor(workspaceID: String, channelID: String) -> SyncCursor {
        queue.sync {
            var cursor = SyncCursor(oldestSynced: nil, newestSynced: nil, backfillDone: false, lastSyncAt: nil)
            query("SELECT oldest_synced, newest_synced, backfill_done, last_sync_at FROM sync_cursors WHERE workspace_id=? AND channel_id=?",
                  bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
            }, row: { stmt in
                cursor.oldestSynced = self.textColumn(stmt, 0)
                cursor.newestSynced = self.textColumn(stmt, 1)
                cursor.backfillDone = sqlite3_column_int(stmt, 2) == 1
                let ts = sqlite3_column_double(stmt, 3)
                if ts > 0 { cursor.lastSyncAt = Date(timeIntervalSince1970: ts) }
            })
            return cursor
        }
    }

    func updateSyncCursor(workspaceID: String, channelID: String,
                          oldest: String?, newest: String?,
                          backfillDone: Bool) {
        queue.sync {
            exec("""
                INSERT INTO sync_cursors(workspace_id,channel_id,oldest_synced,newest_synced,backfill_done,last_sync_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(workspace_id,channel_id) DO UPDATE SET
                    oldest_synced=COALESCE(excluded.oldest_synced, sync_cursors.oldest_synced),
                    newest_synced=COALESCE(excluded.newest_synced, sync_cursors.newest_synced),
                    backfill_done=excluded.backfill_done,
                    last_sync_at=excluded.last_sync_at
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
                self.bindText(stmt, 3, oldest)
                self.bindText(stmt, 4, newest)
                sqlite3_bind_int(stmt, 5, backfillDone ? 1 : 0)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            })
        }
    }

    // MARK: - Queries

    func search(query searchText: String, workspaceID: String? = nil, limit: Int = 50) -> [SlackMessage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Escape FTS special chars roughly by quoting tokens.
        let ftsQuery = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            .joined(separator: " ")

        return queue.sync {
            var results: [SlackMessage] = []
            var sql = """
                SELECT m.workspace_id, m.channel_id, m.ts, m.thread_ts, m.user_id, m.text, m.reply_count, m.subtype
                FROM messages_fts f
                JOIN messages m ON m.rowid = f.rowid
                WHERE messages_fts MATCH ?
                """
            if workspaceID != nil {
                sql += " AND m.workspace_id = ?"
            }
            sql += " ORDER BY CAST(m.ts AS REAL) DESC LIMIT ?"

            query(sql, bind: { stmt in
                self.bindText(stmt, 1, ftsQuery)
                var idx: Int32 = 2
                if let workspaceID {
                    self.bindText(stmt, idx, workspaceID)
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(limit))
            }, row: { stmt in
                if let msg = self.messageFromRow(stmt) { results.append(msg) }
            })
            return results
        }
    }

    func history(workspaceID: String, channelID: String, limit: Int = 100,
                 beforeTS: String? = nil, afterTS: String? = nil) -> [SlackMessage] {
        queue.sync {
            var results: [SlackMessage] = []
            var sql = """
                SELECT workspace_id, channel_id, ts, thread_ts, user_id, text, reply_count, subtype
                FROM messages
                WHERE workspace_id=? AND channel_id=?
                """
            if beforeTS != nil { sql += " AND CAST(ts AS REAL) < CAST(? AS REAL)" }
            if afterTS != nil { sql += " AND CAST(ts AS REAL) > CAST(? AS REAL)" }
            sql += " ORDER BY CAST(ts AS REAL) DESC LIMIT ?"

            query(sql, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
                var idx: Int32 = 3
                if let beforeTS {
                    self.bindText(stmt, idx, beforeTS)
                    idx += 1
                }
                if let afterTS {
                    self.bindText(stmt, idx, afterTS)
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(limit))
            }, row: { stmt in
                if let msg = self.messageFromRow(stmt) { results.append(msg) }
            })
            return results
        }
    }

    func thread(workspaceID: String, channelID: String, threadTs: String) -> [SlackMessage] {
        queue.sync {
            var results: [SlackMessage] = []
            query("""
                SELECT workspace_id, channel_id, ts, thread_ts, user_id, text, reply_count, subtype
                FROM messages
                WHERE workspace_id=? AND channel_id=? AND (ts=? OR thread_ts=?)
                ORDER BY CAST(ts AS REAL) ASC
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
                self.bindText(stmt, 3, threadTs)
                self.bindText(stmt, 4, threadTs)
            }, row: { stmt in
                if let msg = self.messageFromRow(stmt) { results.append(msg) }
            })
            return results
        }
    }

    func user(workspaceID: String, userID: String) -> SlackUser? {
        queue.sync {
            var user: SlackUser?
            query("""
                SELECT id, name, real_name, display_name, tz, is_bot
                FROM users WHERE workspace_id=? AND id=?
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, userID)
            }, row: { stmt in
                guard let id = self.textColumn(stmt, 0), let name = self.textColumn(stmt, 1) else { return }
                user = SlackUser(
                    id: id,
                    name: name,
                    realName: self.textColumn(stmt, 2),
                    displayName: self.textColumn(stmt, 3),
                    tz: self.textColumn(stmt, 4),
                    isBot: sqlite3_column_int(stmt, 5) == 1
                )
            })
            return user
        }
    }

    func messagesSince(workspaceID: String, since: Date, channelIDs: [String]? = nil, limit: Int = 500) -> [SlackMessage] {
        messagesInRange(
            workspaceID: workspaceID,
            since: since,
            until: nil,
            channelIDs: channelIDs,
            userID: nil,
            limit: limit
        )
    }

    func messagesInRange(
        workspaceID: String,
        since: Date?,
        until: Date?,
        channelIDs: [String]? = nil,
        userID: String? = nil,
        limit: Int = 500
    ) -> [SlackMessage] {
        queue.sync {
            var results: [SlackMessage] = []
            var sql = """
                SELECT workspace_id, channel_id, ts, thread_ts, user_id, text, reply_count, subtype
                FROM messages
                WHERE workspace_id=?
                """
            var bindValues: [String] = [workspaceID]

            if let since {
                sql += " AND CAST(ts AS REAL) >= CAST(? AS REAL)"
                bindValues.append(String(since.timeIntervalSince1970))
            }
            if let until {
                sql += " AND CAST(ts AS REAL) <= CAST(? AS REAL)"
                bindValues.append(String(until.timeIntervalSince1970))
            }
            if let channelIDs, !channelIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: channelIDs.count).joined(separator: ",")
                sql += " AND channel_id IN (\(placeholders))"
                bindValues.append(contentsOf: channelIDs)
            }
            if let userID, !userID.isEmpty {
                sql += " AND user_id = ?"
                bindValues.append(userID)
            }
            sql += " ORDER BY CAST(ts AS REAL) DESC LIMIT ?"

            query(sql, bind: { stmt in
                var idx: Int32 = 1
                for value in bindValues {
                    self.bindText(stmt, idx, value)
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(limit))
            }, row: { stmt in
                if let msg = self.messageFromRow(stmt) { results.append(msg) }
            })
            return results
        }
    }

    /// Resolve a Slack user by @handle, display name, first name, or user ID.
    func findUser(workspaceID: String, query searchText: String) -> SlackUser? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("U") || trimmed.hasPrefix("W") {
            if let exact = user(workspaceID: workspaceID, userID: trimmed) { return exact }
        }

        let candidates = findUserCandidates(workspaceID: workspaceID, searchText: trimmed, limit: 30)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].user }

        let needle = trimmed.lowercased()
        let ranked = candidates.map { item -> (SlackUser, Int) in
            (item.user, scoreUserMatch(item.user, needle: needle, messageCount: item.messageCount))
        }
        .sorted { $0.1 > $1.1 }

        guard let best = ranked.first, best.1 > 0 else { return candidates[0].user }
        return best.0
    }

    private struct UserCandidate {
        var user: SlackUser
        var messageCount: Int
    }

    private func findUserCandidates(workspaceID: String, searchText: String, limit: Int) -> [UserCandidate] {
        let trimmed = searchText.lowercased()
        let pattern = "%\(trimmed)%"
        let prefix = "\(trimmed)%"
        return queue.sync {
            var results: [UserCandidate] = []
            query("""
                SELECT u.id, u.name, u.real_name, u.display_name, u.tz, u.is_bot,
                       (SELECT COUNT(*) FROM messages m
                        WHERE m.workspace_id = u.workspace_id AND m.user_id = u.id) AS msg_count
                FROM users u
                WHERE u.workspace_id=?
                  AND (
                    lower(u.id)=? OR lower(u.name)=? OR lower(u.real_name)=? OR lower(u.display_name)=?
                    OR lower(u.name) LIKE ? OR lower(u.real_name) LIKE ? OR lower(u.display_name) LIKE ?
                    OR lower(u.name) LIKE ? OR lower(u.real_name) LIKE ? OR lower(u.display_name) LIKE ?
                  )
                ORDER BY msg_count DESC
                LIMIT ?
                """, bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, trimmed)
                self.bindText(stmt, 3, trimmed)
                self.bindText(stmt, 4, trimmed)
                self.bindText(stmt, 5, trimmed)
                self.bindText(stmt, 6, pattern)
                self.bindText(stmt, 7, pattern)
                self.bindText(stmt, 8, pattern)
                self.bindText(stmt, 9, prefix)
                self.bindText(stmt, 10, prefix)
                self.bindText(stmt, 11, prefix)
                sqlite3_bind_int(stmt, 12, Int32(limit))
            }, row: { stmt in
                guard let id = self.textColumn(stmt, 0), let name = self.textColumn(stmt, 1) else { return }
                let user = SlackUser(
                    id: id,
                    name: name,
                    realName: self.textColumn(stmt, 2),
                    displayName: self.textColumn(stmt, 3),
                    tz: self.textColumn(stmt, 4),
                    isBot: sqlite3_column_int(stmt, 5) == 1
                )
                let count = Int(sqlite3_column_int64(stmt, 6))
                results.append(UserCandidate(user: user, messageCount: count))
            })
            return results
        }
    }

    private func scoreUserMatch(_ user: SlackUser, needle: String, messageCount: Int) -> Int {
        var score = min(messageCount, 50)
        let fields = [user.name, user.realName, user.displayName, user.label]
            .compactMap { $0?.lowercased() }
        for field in fields {
            if field == needle { score += 200 }
            if field.hasPrefix(needle + " ") || field.hasPrefix(needle + ".") { score += 150 }
            if field.split(separator: " ").first == Substring(needle) { score += 120 }
            if field.hasPrefix(needle) { score += 80 }
            if field.contains(needle) { score += 40 }
        }
        return score
    }

    func messageCount() -> Int {
        queue.sync {
            var count = 0
            query("SELECT COUNT(*) FROM messages", bind: { _ in }, row: { stmt in
                count = Int(sqlite3_column_int64(stmt, 0))
            })
            return count
        }
    }

    func databaseFileSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    func lastSyncDate() -> Date? {
        queue.sync {
            var date: Date?
            query("SELECT MAX(last_sync_at) FROM sync_cursors", bind: { _ in }, row: { stmt in
                let v = sqlite3_column_double(stmt, 0)
                if v > 0 { date = Date(timeIntervalSince1970: v) }
            })
            return date
        }
    }

    // MARK: - Retention / wipe / export

    func applyRetention(workspaceID: String, months: Int) {
        let cutoff = Date().addingTimeInterval(-Double(months) * 30 * 24 * 3600).timeIntervalSince1970
        queue.sync {
            exec("DELETE FROM messages WHERE workspace_id=? AND CAST(ts AS REAL) < ?", bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                sqlite3_bind_double(stmt, 2, cutoff)
            })
            exec("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
        }
    }

    func wipeChannel(workspaceID: String, channelID: String) {
        queue.sync {
            exec("DELETE FROM messages WHERE workspace_id=? AND channel_id=?", bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
            })
            exec("DELETE FROM sync_cursors WHERE workspace_id=? AND channel_id=?", bind: { stmt in
                self.bindText(stmt, 1, workspaceID)
                self.bindText(stmt, 2, channelID)
            })
        }
    }

    func wipeAll() {
        queue.sync {
            exec("DELETE FROM messages")
            exec("DELETE FROM sync_cursors")
            exec("DELETE FROM channels")
            exec("DELETE FROM users")
            exec("DELETE FROM audit_log")
            exec("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
            exec("VACUUM")
        }
    }

    func exportJSON(to url: URL) throws {
        let messages = historyExport()
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func historyExport() -> [[String: Any]] {
        queue.sync {
            var rows: [[String: Any]] = []
            query("""
                SELECT workspace_id, channel_id, ts, thread_ts, user_id, text, reply_count, subtype
                FROM messages ORDER BY CAST(ts AS REAL) ASC
                """, bind: { _ in }, row: { stmt in
                var dict: [String: Any] = [:]
                dict["workspace_id"] = self.textColumn(stmt, 0) ?? ""
                dict["channel_id"] = self.textColumn(stmt, 1) ?? ""
                dict["ts"] = self.textColumn(stmt, 2) ?? ""
                if let v = self.textColumn(stmt, 3) { dict["thread_ts"] = v }
                if let v = self.textColumn(stmt, 4) { dict["user_id"] = v }
                dict["text"] = self.textColumn(stmt, 5) ?? ""
                dict["reply_count"] = Int(sqlite3_column_int(stmt, 6))
                if let v = self.textColumn(stmt, 7) { dict["subtype"] = v }
                rows.append(dict)
            })
            return rows
        }
    }

    func appendAudit(actor: String, action: String, detail: String?) {
        queue.sync {
            exec("INSERT INTO audit_log(at, actor, action, detail) VALUES (?,?,?,?)", bind: { stmt in
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
                self.bindText(stmt, 2, actor)
                self.bindText(stmt, 3, action)
                self.bindText(stmt, 4, detail)
            })
        }
    }

    // MARK: - SQLite helpers

    private func messageFromRow(_ stmt: OpaquePointer?) -> SlackMessage? {
        guard let workspaceID = self.textColumn(stmt, 0),
              let channelID = self.textColumn(stmt, 1),
              let ts = self.textColumn(stmt, 2) else { return nil }
        return SlackMessage(
            workspaceID: workspaceID,
            channelID: channelID,
            ts: ts,
            threadTs: self.textColumn(stmt, 3),
            userID: self.textColumn(stmt, 4),
            text: self.textColumn(stmt, 5) ?? "",
            replyCount: Int(sqlite3_column_int(stmt, 6)),
            subtype: self.textColumn(stmt, 7)
        )
    }

    private func exec(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.debug("SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.debug("SQL step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            // SQLITE_TRANSIENT (-1): SQLite copies the bytes immediately.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = value.withCString { cstr in
                sqlite3_bind_text(stmt, index, cstr, -1, transient)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func textColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
