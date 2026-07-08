import Foundation
import Network

/// Minimal Streamable HTTP MCP server bound to 127.0.0.1 only.
/// Implements initialize / tools/list / tools/call for Cursor and Claude.
final class MCPHTTPServer {
    private let port: NWEndpoint.Port
    private weak var bridge: BridgeController?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.slackagentbridge.mcp", qos: .userInitiated)

    private(set) var isListening = false

    init(port: Int, bridge: BridgeController) {
        self.port = NWEndpoint.Port(rawValue: UInt16(port)) ?? 47821
        self.bridge = bridge
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback only — never expose the MCP port on the LAN.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isListening = true
            case .failed(let error):
                Log.error("MCP listener failed: \(error.localizedDescription)")
                self?.isListening = false
            case .cancelled:
                self?.isListening = false
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            if let request = Self.parseHTTPRequest(buf) {
                self.respond(to: request, on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            // Wait for more data (incomplete headers)
            if buf.count < 1024 * 1024 {
                self.receive(on: connection, buffer: buf)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        // Preflight
        if request.method == "OPTIONS" {
            send(connection: connection, status: 204, headers: corsHeaders(), body: Data())
            return
        }

        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            let body = Data("Not Found".utf8)
            send(connection: connection, status: 404, headers: ["Content-Type": "text/plain"], body: body)
            return
        }

        // Auth
        let auth = request.headers["authorization"] ?? ""
        let bearer: String
        if auth.lowercased().hasPrefix("bearer ") {
            bearer = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else {
            bearer = ""
        }
        guard let tokenRecord = AgentTokenManager.authenticate(bearer: bearer) else {
            let err = mcpError(id: nil, code: -32001, message: MCPAgentErrors.unauthorizedHTTP)
            sendJSON(connection: connection, status: 401, object: err)
            return
        }

        if request.method == "GET" {
            // Simple health / server info for browsers
            let info: [String: Any] = [
                "name": "slack-agent-bridge",
                "version": "1.0.0",
                "protocol": "mcp"
            ]
            sendJSON(connection: connection, status: 200, object: info)
            return
        }

        guard request.method == "POST" else {
            send(connection: connection, status: 405, headers: ["Content-Type": "text/plain"], body: Data("Method Not Allowed".utf8))
            return
        }

        guard let root = try? JSONSerialization.jsonObject(with: request.body) else {
            sendJSON(connection: connection, status: 400, object: mcpError(id: nil, code: -32700, message: "Parse error"))
            return
        }

        if let batch = root as? [[String: Any]] {
            guard batch.count <= 25 else {
                sendJSON(connection: connection, status: 400, object: mcpError(id: nil, code: -32600, message: "Batch size exceeds limit of 25"))
                return
            }
            var responses: [[String: Any]] = []
            for item in batch {
                if let r = handleRPC(item, token: tokenRecord) {
                    responses.append(r)
                }
            }
            sendJSON(connection: connection, status: 200, object: responses)
            return
        }

        guard let json = root as? [String: Any] else {
            sendJSON(connection: connection, status: 400, object: mcpError(id: nil, code: -32700, message: "Parse error"))
            return
        }

        if let response = handleRPC(json, token: tokenRecord) {
            sendJSON(connection: connection, status: 200, object: response)
        } else {
            // Notification — empty accepted
            send(connection: connection, status: 202, headers: corsHeaders(), body: Data())
        }
    }

    private func handleRPC(_ json: [String: Any], token: AgentTokenRecord) -> [String: Any]? {
        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return rpcResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": [
                    "name": "slack-agent-bridge",
                    "version": "1.0.0"
                ]
            ])
        case "notifications/initialized", "initialized":
            return nil
        case "ping":
            return rpcResult(id: id, result: [:])
        case "tools/list":
            return rpcResult(id: id, result: ["tools": Self.toolDefinitions()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = callTool(name: name, arguments: args, token: token)
            return rpcResult(id: id, result: result)
        default:
            return mcpError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(name: String, arguments: [String: Any], token: AgentTokenRecord) -> [String: Any] {
        MessageArchive.shared.appendAudit(
            actor: token.name,
            action: "mcp.\(name)",
            detail: Self.auditDetail(arguments: arguments)
        )

        let sem = DispatchSemaphore(value: 0)
        var payload: [String: Any] = [:]

        Task { @MainActor in
            do {
                payload = try await self.executeTool(name: name, arguments: arguments, token: token)
            } catch {
                let message = MCPAgentErrors.describe(error)
                payload = [
                    "content": [["type": "text", "text": message]],
                    "isError": true
                ]
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
        return payload
    }

    @MainActor
    private func executeTool(name: String, arguments: [String: Any], token: AgentTokenRecord) async throws -> [String: Any] {
        guard let bridge else {
            throw SlackError.notConnected
        }

        func requireWorkspace(_ id: String?) throws -> String {
            guard let id, !id.isEmpty else { throw SlackError.api("workspace_id_required") }
            guard token.workspaceIDs.contains(id) else { throw SlackError.api("workspace_not_allowed") }
            let config = bridge.settings.config(for: id)
            guard config.enabled else { throw SlackError.api("workspace_disabled") }
            return id
        }

        func requireCap(_ workspaceID: String, _ flag: CapabilityFlag) throws {
            let config = bridge.settings.config(for: workspaceID)
            guard token.capabilities.allows(flag), config.capabilities.allows(flag) else {
                throw SlackError.api("capability_denied")
            }
        }

        /// Agents may only read channels on the per-workspace agent allow-list.
        func requireAgentChannel(_ workspaceID: String, _ channelID: String?) throws -> String {
            guard let channelID, !channelID.isEmpty else { throw SlackError.api("channel_id_required") }
            let allowed = bridge.settings.config(for: workspaceID).agentReadableChannelIDs()
            guard allowed.contains(channelID) else {
                throw SlackError.api("channel_not_allowed_for_agents")
            }
            return channelID
        }

        func requireAutomationDeliveryCap(_ workspaceID: String) throws {
            let config = bridge.settings.config(for: workspaceID)
            switch config.automationDeliveryMode {
            case .localOnly:
                return
            case .selfDM:
                try requireCap(workspaceID, .postToMyDM)
            case .privateChannel:
                try requireCap(workspaceID, .postToChannels)
            case .groupDM:
                try requireCap(workspaceID, .postToGroupDMs)
            }
        }

        func agentChannelList(_ wid: String) async -> [[String: Any]] {
            let allowed = Set(bridge.settings.config(for: wid).agentReadableChannelIDs())
            if bridge.channelCache[wid] == nil {
                await bridge.loadChannels(for: wid)
            }
            let channels = (bridge.channelCache[wid] ?? [])
                .filter { allowed.contains($0.id) }
                .map { ["id": $0.id, "name": $0.displayName, "is_im": $0.isIM, "is_private": $0.isPrivate, "is_self_dm": $0.isSelfDM] as [String: Any] }
            let known = Set(channels.compactMap { $0["id"] as? String })
            var result = channels
            for id in allowed where !known.contains(id) {
                result.append(["id": id, "name": id, "is_im": false, "is_private": false])
            }
            return result
        }

        func resolvePostAt(_ arguments: [String: Any]) throws -> Int {
            if let postAt = arguments["post_at"] as? Int { return postAt }
            if let postAt = arguments["post_at"] as? Double { return Int(postAt) }
            if let mins = arguments["post_in_minutes"] as? Int, mins > 0 {
                return Int(Date().timeIntervalSince1970) + mins * 60
            }
            throw SlackError.api("post_at_or_post_in_minutes_required")
        }

        /// Ensures the token/workspace may post (or schedule) to this channel type.
        func requirePostTarget(_ workspaceID: String, _ channelID: String, schedule: Bool) throws {
            if schedule {
                try requireCap(workspaceID, .scheduleMessages)
            }
            let selfChannelID = bridge.settings.identities[workspaceID]?.selfDMChannelID
            let cached = bridge.channelCache[workspaceID]?.first(where: { $0.id == channelID })
            if cached?.isSelfDM == true || channelID == selfChannelID {
                try requireCap(workspaceID, .postToMyDM)
                return
            }
            if cached?.isMPIM == true {
                try requireCap(workspaceID, .postToGroupDMs)
                return
            }
            if cached?.isIM == true || channelID.hasPrefix("D") {
                try requireCap(workspaceID, .postToDMs)
                return
            }
            try requireCap(workspaceID, .postToChannels)
            _ = try requireAgentChannel(workspaceID, channelID)
        }

        func filterToAgentChannels(_ messages: [SlackMessage], workspaceID: String?) -> [SlackMessage] {
            messages.filter { msg in
                if let workspaceID, msg.workspaceID != workspaceID { return false }
                guard token.workspaceIDs.contains(msg.workspaceID) else { return false }
                let allowed = bridge.settings.config(for: msg.workspaceID).agentReadableChannelIDs()
                return allowed.contains(msg.channelID)
            }
        }

        func requireSlackSession(_ workspaceID: String) throws {
            guard bridge.isConnected, bridge.credentials(for: workspaceID) != nil else {
                throw SlackError.api("slack_session_not_connected")
            }
        }

        func ensureChannelCache(_ workspaceID: String) async {
            if bridge.channelCache[workspaceID] == nil {
                await bridge.loadChannels(for: workspaceID)
            }
        }

        func channelDisplayName(workspaceID: String, channelID: String) -> String {
            if let ch = bridge.channelCache[workspaceID]?.first(where: { $0.id == channelID }) {
                return ch.displayName
            }
            if let archived = MessageArchive.shared.channelName(workspaceID: workspaceID, channelID: channelID),
               !archived.isEmpty {
                if archived.hasPrefix("#") || archived.hasPrefix("DM ") { return archived }
                if channelID.hasPrefix("C") || channelID.hasPrefix("G") { return "#\(archived)" }
                return archived
            }
            return channelID
        }

        func resolveUserID(workspaceID: String, arguments: [String: Any]) async throws -> String? {
            if let userID = arguments["user_id"] as? String, !userID.isEmpty { return userID }
            guard let fromUser = arguments["from_user"] as? String else { return nil }
            let trimmed = fromUser.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let cached = MessageArchive.shared.findUser(workspaceID: workspaceID, query: trimmed) {
                return cached.id
            }

            if bridge.isConnected, let creds = bridge.credentials(for: workspaceID),
               let users = try? await bridge.api.usersList(token: creds.token, cookie: creds.cookie) {
                for user in users {
                    MessageArchive.shared.upsertUser(user, workspaceID: workspaceID)
                }
                if let resolved = MessageArchive.shared.findUser(workspaceID: workspaceID, query: trimmed) {
                    return resolved.id
                }
            }

            throw SlackError.api("user_not_found: could not resolve from_user '\(trimmed)'. Try full name, @handle, or user_id.")
        }

        func resolveHighlightUserID(workspaceID: String, arguments: [String: Any]) async -> String? {
            if let userID = arguments["highlight_user_id"] as? String, !userID.isEmpty { return userID }
            guard let name = arguments["highlight_user"] as? String, !name.isEmpty else { return nil }
            if let cached = MessageArchive.shared.findUser(workspaceID: workspaceID, query: name) {
                return cached.id
            }
            if bridge.isConnected, let creds = bridge.credentials(for: workspaceID),
               let users = try? await bridge.api.usersList(token: creds.token, cookie: creds.cookie) {
                for user in users { MessageArchive.shared.upsertUser(user, workspaceID: workspaceID) }
                return MessageArchive.shared.findUser(workspaceID: workspaceID, query: name)?.id
            }
            return nil
        }

        func userDisplayName(workspaceID: String, userID: String?) -> String? {
            guard let userID else { return nil }
            if let user = MessageArchive.shared.user(workspaceID: workspaceID, userID: userID) {
                return user.label
            }
            return userID
        }

        func plainSlackText(_ text: String, workspaceID: String) -> String {
            var out = text
            let pattern = #"<@([A-Z0-9]+)>"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
            let ns = out as NSString
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard match.numberOfRanges > 1 else { continue }
                let uid = ns.substring(with: match.range(at: 1))
                let label = userDisplayName(workspaceID: workspaceID, userID: uid) ?? uid
                out = (out as NSString).replacingCharacters(in: match.range, with: "@\(label)")
            }
            return out
        }

        func enrichedMessageDict(_ m: SlackMessage) -> [String: Any] {
            let iso = ISO8601DateFormatter()
            return [
                "workspace_id": m.workspaceID,
                "channel_id": m.channelID,
                "channel_name": channelDisplayName(workspaceID: m.workspaceID, channelID: m.channelID),
                "ts": m.ts,
                "posted_at": iso.string(from: m.date),
                "thread_ts": m.threadTs as Any,
                "user_id": m.userID as Any,
                "user_display_name": userDisplayName(workspaceID: m.workspaceID, userID: m.userID) as Any,
                "text": m.text,
                "text_plain": plainSlackText(m.text, workspaceID: m.workspaceID),
                "reply_count": m.replyCount,
                "source": "archive"
            ]
        }

        func applyDateRange(_ messages: [SlackMessage], range: MCPDateRange?) -> [SlackMessage] {
            guard let range else { return messages }
            return messages.filter { range.contains($0.date) }
        }

        func filterMessages(
            _ messages: [SlackMessage],
            range: MCPDateRange?,
            channelID: String?,
            userID: String?
        ) -> [SlackMessage] {
            var filtered = applyDateRange(messages, range: range)
            if let channelID, !channelID.isEmpty {
                filtered = filtered.filter { $0.channelID == channelID }
            }
            if let userID, !userID.isEmpty {
                filtered = filtered.filter { $0.userID == userID }
            }
            return filtered
        }

        switch name {
        case "list_workspaces":
            let list = bridge.workspaces
                .filter { token.workspaceIDs.contains($0.id) && bridge.settings.config(for: $0.id).enabled }
                .map { ["id": $0.id, "name": $0.name, "url": $0.url as Any] }
            return textResult(json: list)

        case "list_channels", "list_agent_channels":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            return textResult(json: await agentChannelList(wid))

        case "search_messages":
            let query = arguments["query"] as? String ?? ""
            let wid = arguments["workspace_id"] as? String
            if wid == nil, query.isEmpty,
               arguments["from_user"] == nil, arguments["user_id"] == nil,
               MCPDateRange.parse(arguments) == nil {
                return textResult(json: [])
            }
            if let wid {
                _ = try requireWorkspace(wid)
                try requireCap(wid, .readChannels)
            }
            let limit = (arguments["limit"] as? Int) ?? 40
            let live = (arguments["live"] as? Bool) ?? false
            let range = MCPDateRange.parse(arguments)
            let channelFilter = arguments["channel_id"] as? String
            if let wid { await ensureChannelCache(wid) }
            var resolvedUserID: String?
            if let wid {
                resolvedUserID = try await resolveUserID(workspaceID: wid, arguments: arguments)
            }

            var results: [SlackMessage] = []
            if let wid, (resolvedUserID != nil || range != nil || channelFilter != nil), query.isEmpty {
                let since = range?.since ?? Date.distantPast
                let allowed = bridge.settings.config(for: wid).agentReadableChannelIDs()
                let channels = channelFilter.map { [$0] } ?? (allowed.isEmpty ? nil : allowed)
                results = MessageArchive.shared.messagesInRange(
                    workspaceID: wid,
                    since: since,
                    until: range?.until,
                    channelIDs: channels,
                    userID: resolvedUserID,
                    limit: limit * 3
                )
            } else if !query.isEmpty {
                var archiveHits = MessageArchive.shared.search(query: query, workspaceID: wid, limit: limit * 3)
                archiveHits = filterToAgentChannels(archiveHits, workspaceID: wid)
                results = filterMessages(archiveHits, range: range, channelID: channelFilter, userID: resolvedUserID)
            } else if let wid {
                let hours = (arguments["hours"] as? Int) ?? 168
                let since = range?.since ?? Date().addingTimeInterval(-Double(hours) * 3600)
                let allowed = bridge.settings.config(for: wid).agentReadableChannelIDs()
                let channels = channelFilter.map { [$0] } ?? (allowed.isEmpty ? nil : allowed)
                results = MessageArchive.shared.messagesInRange(
                    workspaceID: wid,
                    since: since,
                    until: range?.until,
                    channelIDs: channels,
                    userID: resolvedUserID,
                    limit: limit * 3
                )
            }
            results = Array(results.prefix(limit))
            var payload: [[String: Any]] = results.map(enrichedMessageDict)

            if live, let wid, let creds = bridge.credentials(for: wid) {
                try requireSlackSession(wid)
                let allowed = Set(bridge.settings.config(for: wid).agentReadableChannelIDs())
                let liveQuery = query.isEmpty ? "*" : query
                let liveHits = try await bridge.api.searchMessages(
                    query: liveQuery, token: creds.token, cookie: creds.cookie, count: min(limit, 20)
                )
                for raw in liveHits {
                    let channelObj = raw["channel"] as? [String: Any]
                    let channelID = (channelObj?["id"] as? String) ?? (raw["channel"] as? String)
                    guard let channelID, allowed.contains(channelID) else { continue }
                    if let channelFilter, channelID != channelFilter { continue }
                    let ts = (raw["ts"] as? String) ?? ""
                    let userID = raw["user"] as? String
                    if let resolvedUserID, userID != resolvedUserID { continue }
                    let text = (raw["text"] as? String) ?? ""
                    if let range, let date = Double(ts).map({ Date(timeIntervalSince1970: $0) }), !range.contains(date) {
                        continue
                    }
                    let iso = ISO8601DateFormatter()
                    let postedAt = Double(ts).map { iso.string(from: Date(timeIntervalSince1970: $0)) }
                    payload.append([
                        "source": "live",
                        "channel_id": channelID,
                        "channel_name": channelDisplayName(workspaceID: wid, channelID: channelID),
                        "text": text,
                        "text_plain": plainSlackText(text, workspaceID: wid),
                        "ts": ts,
                        "posted_at": postedAt as Any,
                        "user_id": userID as Any,
                        "user_display_name": userDisplayName(workspaceID: wid, userID: userID) as Any
                    ])
                }
            }
            return textResult(json: payload)

        case "get_channel_history":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            await ensureChannelCache(wid)
            let limit = (arguments["limit"] as? Int) ?? 50
            let range = MCPDateRange.parse(arguments)
            let fetchLimit = range != nil ? max(limit, 500) : limit
            let userFilter = try await resolveUserID(workspaceID: wid, arguments: arguments)

            var msgs: [SlackMessage]
            if let range {
                msgs = MessageArchive.shared.messagesInRange(
                    workspaceID: wid,
                    since: range.since,
                    until: range.until,
                    channelIDs: [channelID],
                    userID: userFilter,
                    limit: fetchLimit
                )
            } else if let days = arguments["days"] as? Int, days > 0 {
                let since = Date().addingTimeInterval(-Double(days) * 86_400)
                msgs = MessageArchive.shared.messagesInRange(
                    workspaceID: wid,
                    since: since,
                    until: nil,
                    channelIDs: [channelID],
                    userID: userFilter,
                    limit: fetchLimit
                )
            } else {
                msgs = MessageArchive.shared.history(workspaceID: wid, channelID: channelID, limit: fetchLimit)
                if let userFilter {
                    msgs = msgs.filter { $0.userID == userFilter }
                }
            }

            if msgs.count < min(limit, 10) {
                try requireSlackSession(wid)
                if let creds = bridge.credentials(for: wid) {
                    let live = try await bridge.api.history(channelID: channelID, token: creds.token, cookie: creds.cookie, limit: fetchLimit)
                    let parsed = live.messages.compactMap {
                        bridge.api.parseHistoryMessage($0, workspaceID: wid, channelID: channelID)
                    }
                    MessageArchive.shared.upsertMessages(parsed)
                    if let range {
                        msgs = MessageArchive.shared.messagesInRange(
                            workspaceID: wid,
                            since: range.since,
                            until: range.until,
                            channelIDs: [channelID],
                            userID: userFilter,
                            limit: fetchLimit
                        )
                    } else {
                        msgs = MessageArchive.shared.history(workspaceID: wid, channelID: channelID, limit: fetchLimit)
                        if let userFilter {
                            msgs = msgs.filter { $0.userID == userFilter }
                        }
                    }
                }
            }
            msgs = Array(msgs.prefix(limit))
            return textResult(json: msgs.map(enrichedMessageDict))

        case "get_thread":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let threadTs = arguments["thread_ts"] as? String else {
                throw SlackError.api("channel_id_and_thread_ts_required")
            }
            var msgs = MessageArchive.shared.thread(workspaceID: wid, channelID: channelID, threadTs: threadTs)
            if msgs.count <= 1, let creds = bridge.credentials(for: wid) {
                let live = try await bridge.api.replies(channelID: channelID, threadTs: threadTs, token: creds.token, cookie: creds.cookie)
                let parsed = live.messages.compactMap {
                    bridge.api.parseHistoryMessage($0, workspaceID: wid, channelID: channelID)
                }
                MessageArchive.shared.upsertMessages(parsed)
                msgs = MessageArchive.shared.thread(workspaceID: wid, channelID: channelID, threadTs: threadTs)
            }
            return textResult(json: msgs.map(enrichedMessageDict))

        case "get_user":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            guard let userID = arguments["user_id"] as? String else {
                throw SlackError.api("user_id_required")
            }
            if let cached = MessageArchive.shared.user(workspaceID: wid, userID: userID) {
                return textResult(json: userDict(cached))
            }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let user = try await bridge.api.userInfo(userID: userID, token: creds.token, cookie: creds.cookie)
            MessageArchive.shared.upsertUser(user, workspaceID: wid)
            return textResult(json: userDict(user))

        case "list_mentions":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            let hours = (arguments["hours"] as? Int) ?? 24
            let since = Date().addingTimeInterval(-Double(hours) * 3600)
            let identity = try await bridge.resolveSelfIdentity(workspaceID: wid, forceRefresh: false)
            let markers = ["<@\(identity.userID)>", "@\(identity.displayName ?? "")"].filter { !$0.isEmpty && $0 != "@" }
            let allowed = Set(bridge.settings.config(for: wid).agentReadableChannelIDs())
            let msgs = MessageArchive.shared.messagesSince(workspaceID: wid, since: since, channelIDs: Array(allowed))
                .filter { msg in
                    markers.contains { msg.text.localizedCaseInsensitiveContains($0) }
                }
            return textResult(json: msgs.prefix(80).map(enrichedMessageDict))

        case "summarize_channel":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            await ensureChannelCache(wid)
            let hours = (arguments["hours"] as? Int) ?? 168
            let range = MCPDateRange.parse(arguments)
            let since = range?.since ?? Date().addingTimeInterval(-Double(hours) * 3600)
            let highlightID = await resolveHighlightUserID(workspaceID: wid, arguments: arguments)
            let highlightLabel: String? = {
                if let highlightID { return userDisplayName(workspaceID: wid, userID: highlightID) }
                return nil
            }()
            let msgs = MessageArchive.shared.messagesInRange(
                workspaceID: wid,
                since: since,
                until: range?.until,
                channelIDs: [channelID],
                userID: nil,
                limit: 2000
            )
            let channelName = channelDisplayName(workspaceID: wid, channelID: channelID)
            let preview = bridge.automations.formatChannelDigest(
                messages: msgs,
                channelName: channelName,
                workspaceName: bridge.workspace(for: wid)?.name ?? wid,
                hours: hours,
                highlightUserID: highlightID,
                highlightLabel: highlightLabel,
                userLabel: { uid in userDisplayName(workspaceID: wid, userID: uid) ?? uid }
            )
            return textResult(text: preview)

        case "summarize_day":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .readChannels)
            if let channelID = arguments["channel_id"] as? String, !channelID.isEmpty {
                await ensureChannelCache(wid)
            }
            let hours = (arguments["hours"] as? Int) ?? 24
            let range = MCPDateRange.parse(arguments)
            let since = range?.since ?? Date().addingTimeInterval(-Double(hours) * 3600)
            var allowed = bridge.settings.config(for: wid).agentReadableChannelIDs()
            if let channelID = arguments["channel_id"] as? String, !channelID.isEmpty {
                _ = try requireAgentChannel(wid, channelID)
                allowed = [channelID]
            }
            let userFilter = try await resolveUserID(workspaceID: wid, arguments: arguments)
            let msgs = MessageArchive.shared.messagesInRange(
                workspaceID: wid,
                since: since,
                until: range?.until,
                channelIDs: allowed.isEmpty ? nil : allowed,
                userID: userFilter,
                limit: 2000
            )
            let tasks = bridge.automations.draftTasks(from: msgs, workspaceID: wid)
            let preview = bridge.automations.formatDigest(
                messages: msgs,
                tasks: tasks,
                workspaceName: bridge.workspace(for: wid)?.name ?? wid
            )
            return textResult(text: preview)

        case "create_reminder":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .setReminders)
            let text = arguments["text"] as? String ?? ""
            let time = arguments["time"] as? String ?? "in 1 hour"
            let id = try await bridge.automations.createSlackReminder(workspaceID: wid, text: text, time: time, bridge: bridge)
            return textResult(json: ["reminder_id": id])

        case "send_dm_to_self":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .postToMyDM)
            let text = arguments["text"] as? String ?? ""
            try await bridge.automations.sendToSelfDM(workspaceID: wid, text: text, bridge: bridge)
            let selfCh = bridge.settings.identities[wid]?.selfDMChannelID
            await bridge.automations.notifyAutomationDelivery(
                workspaceID: wid, text: text, bridge: bridge,
                channelIDOverride: selfCh, labelOverride: "Personal DM"
            )
            return textResult(text: "Message sent to your DM.")

        case "send_dm":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .postToDMs)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            let text = arguments["text"] as? String ?? ""
            guard !text.isEmpty else { throw SlackError.api("text_required") }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let cached = bridge.channelCache[wid]?.first(where: { $0.id == channelID })
            let selfChannelID = bridge.settings.identities[wid]?.selfDMChannelID
            if cached?.isSelfDM == true || channelID == selfChannelID {
                throw SlackError.api("use_send_dm_to_self_for_your_own_dm")
            }
            let isIM = cached?.isIM == true || channelID.hasPrefix("D")
            guard isIM else { throw SlackError.api("channel_not_a_dm") }
            let ts = try await bridge.withAuthRetry(wid) {
                try await bridge.api.postMessage(
                    channelID: channelID, text: text,
                    token: creds.token, cookie: creds.cookie
                )
            }
            await bridge.automations.notifyAutomationDelivery(
                workspaceID: wid, text: text, bridge: bridge,
                channelIDOverride: channelID, labelOverride: "Direct message"
            )
            return textResult(json: ["ok": true, "channel_id": channelID, "ts": ts])

        case "create_automation_group_dm":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .postToGroupDMs)
            let text = arguments["text"] as? String
                ?? "Slack Agent Bridge inbox is ready. Automations and agent notes will be delivered here."
            let channelID = try await bridge.createAutomationGroupDM(workspaceID: wid)
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let ts = try await bridge.api.postMessage(
                channelID: channelID, text: text,
                token: creds.token, cookie: creds.cookie
            )
            await bridge.automations.notifyAutomationDelivery(
                workspaceID: wid, text: text, bridge: bridge,
                channelIDOverride: channelID, labelOverride: bridge.settings.config(for: wid).automationInboxLabel
            )
            return textResult(json: [
                "ok": true,
                "channel_id": channelID,
                "ts": ts,
                "delivery_mode": "groupDM",
                "note": "Automation inbox is a DM with Slackbot (search Slackbot in DMs — there is no Slack user named Agent Bridge)."
            ])

        case "draft_task_list":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .archiveChannels)
            let hours = (arguments["hours"] as? Int) ?? 24
            let since = Date().addingTimeInterval(-Double(hours) * 3600)
            let allowed = bridge.settings.config(for: wid).agentReadableChannelIDs()
            let messages = MessageArchive.shared.messagesSince(
                workspaceID: wid,
                since: since,
                channelIDs: allowed.isEmpty ? nil : allowed
            ).filter { allowed.contains($0.channelID) }
            let tasks = bridge.automations.draftTasks(from: messages, workspaceID: wid)
            for task in tasks {
                if !bridge.settings.localTasks.contains(where: {
                    $0.sourceTs == task.sourceTs && $0.sourceChannelID == task.sourceChannelID
                }) {
                    bridge.settings.localTasks.insert(task, at: 0)
                }
            }
            return textResult(json: tasks.map {
                ["id": $0.id, "title": $0.title, "channel_id": $0.sourceChannelID as Any, "ts": $0.sourceTs as Any]
            })

        case "set_status":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .setStatus)
            let text = arguments["text"] as? String ?? ""
            let emoji = arguments["emoji"] as? String ?? ""
            let expiration = (arguments["expiration"] as? Int) ?? 0
            try await bridge.automations.setStatus(workspaceID: wid, text: text, emoji: emoji, expiration: expiration, bridge: bridge)
            return textResult(text: "Status updated.")

        case "add_reaction":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .addReactions)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let ts = arguments["ts"] as? String,
                  let nameEmoji = arguments["name"] as? String else {
                throw SlackError.api("channel_id_ts_and_name_required")
            }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let emojiName = nameEmoji.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            try await bridge.api.addReaction(channelID: channelID, timestamp: ts, name: emojiName, token: creds.token, cookie: creds.cookie)
            return textResult(text: "Reaction added.")

        case "pin_message":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .pinMessages)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let ts = arguments["ts"] as? String else {
                throw SlackError.api("channel_id_and_ts_required")
            }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            try await bridge.api.pinMessage(channelID: channelID, timestamp: ts, token: creds.token, cookie: creds.cookie)
            return textResult(text: "Message pinned.")

        case "send_channel":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            try requirePostTarget(wid, channelID, schedule: false)
            let text = arguments["text"] as? String ?? ""
            guard !text.isEmpty else { throw SlackError.api("text_required") }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let threadTs = arguments["thread_ts"] as? String
            let ts = try await bridge.withAuthRetry(wid) {
                try await bridge.api.postMessage(
                    channelID: channelID, text: text, token: creds.token, cookie: creds.cookie, threadTs: threadTs
                )
            }
            await bridge.automations.notifyAutomationDelivery(
                workspaceID: wid, text: text, bridge: bridge,
                channelIDOverride: channelID, labelOverride: "Channel"
            )
            return textResult(json: ["ok": true, "channel_id": channelID, "ts": ts])

        case "schedule_message":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            let channelID = arguments["channel_id"] as? String ?? ""
            guard !channelID.isEmpty else { throw SlackError.api("channel_id_required") }
            if bridge.channelCache[wid] == nil {
                await bridge.loadChannels(for: wid)
            }
            try requirePostTarget(wid, channelID, schedule: true)
            let text = arguments["text"] as? String ?? ""
            guard !text.isEmpty else { throw SlackError.api("text_required") }
            let postAt = try resolvePostAt(arguments)
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let threadTs = arguments["thread_ts"] as? String
            let scheduledID = try await bridge.withAuthRetry(wid) {
                try await bridge.api.scheduleMessage(
                    channelID: channelID, text: text, postAt: postAt,
                    token: creds.token, cookie: creds.cookie, threadTs: threadTs
                )
            }
            return textResult(json: [
                "ok": true,
                "channel_id": channelID,
                "scheduled_message_id": scheduledID,
                "post_at": postAt
            ])

        case "list_scheduled_messages":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .scheduleMessages)
            let channelID = arguments["channel_id"] as? String
            if let channelID, !channelID.isEmpty {
                try requirePostTarget(wid, channelID, schedule: false)
            }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let list = try await bridge.api.listScheduledMessages(
                channelID: channelID, token: creds.token, cookie: creds.cookie
            )
            return textResult(json: list)

        case "delete_scheduled_message":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .scheduleMessages)
            guard let channelID = arguments["channel_id"] as? String,
                  let scheduledID = arguments["scheduled_message_id"] as? String,
                  !channelID.isEmpty, !scheduledID.isEmpty else {
                throw SlackError.api("channel_id_and_scheduled_message_id_required")
            }
            try requirePostTarget(wid, channelID, schedule: false)
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            try await bridge.api.deleteScheduledMessage(
                channelID: channelID, scheduledMessageID: scheduledID,
                token: creds.token, cookie: creds.cookie
            )
            return textResult(text: "Scheduled message deleted.")

        case "update_message":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .editMessages)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let ts = arguments["ts"] as? String else { throw SlackError.api("channel_id_and_ts_required") }
            let text = arguments["text"] as? String ?? ""
            guard !text.isEmpty else { throw SlackError.api("text_required") }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let newTs = try await bridge.api.updateMessage(
                channelID: channelID, timestamp: ts, text: text,
                token: creds.token, cookie: creds.cookie
            )
            return textResult(json: ["ok": true, "channel_id": channelID, "ts": newTs])

        case "delete_message":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .deleteMessages)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let ts = arguments["ts"] as? String else { throw SlackError.api("channel_id_and_ts_required") }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            try await bridge.api.deleteMessage(
                channelID: channelID, timestamp: ts, token: creds.token, cookie: creds.cookie
            )
            return textResult(text: "Message deleted.")

        case "unpin_message":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .unpinMessages)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let ts = arguments["ts"] as? String else { throw SlackError.api("channel_id_and_ts_required") }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            try await bridge.api.unpinMessage(channelID: channelID, timestamp: ts, token: creds.token, cookie: creds.cookie)
            return textResult(text: "Message unpinned.")

        case "remove_reaction":
            let wid = try requireWorkspace(arguments["workspace_id"] as? String)
            try requireCap(wid, .removeReactions)
            let channelID = try requireAgentChannel(wid, arguments["channel_id"] as? String)
            guard let ts = arguments["ts"] as? String,
                  let nameEmoji = arguments["name"] as? String else {
                throw SlackError.api("channel_id_ts_and_name_required")
            }
            guard let creds = bridge.credentials(for: wid) else { throw SlackError.notConnected }
            let emojiName = nameEmoji.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            try await bridge.api.removeReaction(
                channelID: channelID, timestamp: ts, name: emojiName,
                token: creds.token, cookie: creds.cookie
            )
            return textResult(text: "Reaction removed.")

        case "list_automations":
            let list = bridge.settings.automations.map {
                [
                    "id": $0.id,
                    "name": $0.name,
                    "kind": $0.kind.rawValue,
                    "enabled": $0.enabled,
                    "workspace_id": $0.workspaceID
                ] as [String: Any]
            }
            return textResult(json: list)

        case "run_automation":
            guard let id = arguments["id"] as? String,
                  let rule = bridge.settings.automations.first(where: { $0.id == id }) else {
                throw SlackError.api("automation_not_found")
            }
            _ = try requireWorkspace(rule.workspaceID)
            try requireCap(rule.workspaceID, .readChannels)
            let willPost = bridge.settings.digestPostToDM
            if willPost {
                try requireAutomationDeliveryCap(rule.workspaceID)
            }
            switch rule.kind {
            case .dailyDigest:
                await bridge.automations.runDigest(rule: rule, settings: bridge.settings, bridge: bridge, post: willPost)
                return textResult(text: bridge.automations.lastDigestPreview)
            case .keywordWatch:
                await bridge.automations.runKeywordWatch(rule: rule, settings: bridge.settings, bridge: bridge)
                return textResult(text: "Keyword watch ran.")
            }

        default:
            throw SlackError.api("unknown_tool")
        }
    }

    private func userDict(_ u: SlackUser) -> [String: Any] {
        [
            "id": u.id,
            "name": u.name,
            "real_name": u.realName as Any,
            "display_name": u.displayName as Any,
            "tz": u.tz as Any,
            "is_bot": u.isBot
        ]
    }

    private func textResult(text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private func textResult(json: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "[]"
        return textResult(text: text)
    }

    private static func toolDefinitions() -> [[String: Any]] {
        let tools: [(String, String, [String: Any])] = [
            ("list_workspaces", "List Slack workspaces this agent token may access.", ["type": "object", "properties": [:]]),
            ("list_channels", "List agent-allowed channels for this workspace (same as list_agent_channels). Configure allow-list in app settings.", [
                "type": "object",
                "properties": ["workspace_id": ["type": "string"]],
                "required": ["workspace_id"]
            ]),
            ("list_agent_channels", "List only channels this installation allows agents to read.", [
                "type": "object",
                "properties": ["workspace_id": ["type": "string"]],
                "required": ["workspace_id"]
            ]),
            ("search_messages", "Search the local archive within agent-allowed channels (optional live Slack search).", [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text search (optional if using from_user / date filters)"],
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "user_id": ["type": "string", "description": "Only messages from this Slack user ID"],
                    "from_user": ["type": "string", "description": "Resolve by @handle or display name; messages FROM this user"],
                    "since": ["type": "string", "description": "ISO date or yyyy-MM-dd"],
                    "until": ["type": "string", "description": "ISO date or yyyy-MM-dd (inclusive end of day)"],
                    "days": ["type": "integer", "description": "Alternative to since: last N days"],
                    "hours": ["type": "integer", "description": "Default lookback when query empty (default 168)"],
                    "limit": ["type": "integer"],
                    "live": ["type": "boolean"]
                ],
                "required": []
            ]),
            ("get_channel_history", "Get messages for an agent-allowed channel from archive with live fallback.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "limit": ["type": "integer"],
                    "since": ["type": "string"],
                    "until": ["type": "string"],
                    "days": ["type": "integer"],
                    "user_id": ["type": "string"],
                    "from_user": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id"]
            ]),
            ("get_thread", "Get a thread's messages (agent-allowed channel).", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "thread_ts": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "thread_ts"]
            ]),
            ("get_user", "Get a Slack user profile (cached or live).", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "user_id": ["type": "string"]
                ],
                "required": ["workspace_id", "user_id"]
            ]),
            ("list_mentions", "List recent messages that mention you in agent-allowed channels.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "hours": ["type": "integer"]
                ],
                "required": ["workspace_id"]
            ]),
            ("summarize_day", "Build a local digest from agent-allowed channels (optional single channel / user filter).", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "hours": ["type": "integer"],
                    "channel_id": ["type": "string"],
                    "since": ["type": "string"],
                    "until": ["type": "string"],
                    "days": ["type": "integer"],
                    "user_id": ["type": "string"],
                    "from_user": ["type": "string"]
                ],
                "required": ["workspace_id"]
            ]),
            ("summarize_channel", "Summarize one agent-allowed channel over a time window; optional highlight user.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "hours": ["type": "integer", "description": "Default 168 (one week)"],
                    "since": ["type": "string"],
                    "until": ["type": "string"],
                    "days": ["type": "integer"],
                    "highlight_user_id": ["type": "string"],
                    "highlight_user": ["type": "string", "description": "Display name or @handle to highlight"]
                ],
                "required": ["workspace_id", "channel_id"]
            ]),
            ("create_reminder", "Create a Slack reminder for yourself.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "text": ["type": "string"],
                    "time": ["type": "string", "description": "e.g. in 20 minutes, tomorrow at 9am"]
                ],
                "required": ["workspace_id", "text", "time"]
            ]),
            ("send_dm_to_self", "Post a message to your own Slack DM.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "text": ["type": "string"]
                ],
                "required": ["workspace_id", "text"]
            ]),
            ("send_dm", "Post a message to a DM channel on your agent allow-list (IM only).", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "text": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "text"]
            ]),
            ("create_automation_group_dm", "Create a group DM inbox (you + Slackbot) and post a welcome message. Sets automation delivery to group DM.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "text": ["type": "string", "description": "Optional first message to post"]
                ],
                "required": ["workspace_id"]
            ]),
            ("draft_task_list", "Extract suggested tasks from recent archived messages in agent-allowed channels.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "hours": ["type": "integer"]
                ],
                "required": ["workspace_id"]
            ]),
            ("set_status", "Set your Slack status.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "text": ["type": "string"],
                    "emoji": ["type": "string"],
                    "expiration": ["type": "integer"]
                ],
                "required": ["workspace_id"]
            ]),
            ("add_reaction", "Add an emoji reaction to a message in an agent-allowed channel.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "ts": ["type": "string"],
                    "name": ["type": "string", "description": "Emoji short name without colons, e.g. thumbsup"]
                ],
                "required": ["workspace_id", "channel_id", "ts", "name"]
            ]),
            ("pin_message", "Pin a message in an agent-allowed channel.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "ts": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "ts"]
            ]),
            ("send_channel", "Post a message to an agent-allowed channel or private channel.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "text": ["type": "string"],
                    "thread_ts": ["type": "string", "description": "Optional thread parent timestamp"]
                ],
                "required": ["workspace_id", "channel_id", "text"]
            ]),
            ("schedule_message", "Schedule a message to a DM or agent-allowed channel (Slack chat.scheduleMessage).", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "text": ["type": "string"],
                    "post_at": ["type": "integer", "description": "Unix timestamp (seconds) when Slack should post"],
                    "post_in_minutes": ["type": "integer", "description": "Alternative: minutes from now"],
                    "thread_ts": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "text"]
            ]),
            ("list_scheduled_messages", "List scheduled messages (optional channel filter).", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"]
                ],
                "required": ["workspace_id"]
            ]),
            ("delete_scheduled_message", "Cancel a scheduled message.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "scheduled_message_id": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "scheduled_message_id"]
            ]),
            ("update_message", "Edit a message you posted in an agent-allowed channel.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "ts": ["type": "string"],
                    "text": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "ts", "text"]
            ]),
            ("delete_message", "Delete a message you posted in an agent-allowed channel.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "ts": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "ts"]
            ]),
            ("unpin_message", "Unpin a message in an agent-allowed channel.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "ts": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "ts"]
            ]),
            ("remove_reaction", "Remove your emoji reaction from a message.", [
                "type": "object",
                "properties": [
                    "workspace_id": ["type": "string"],
                    "channel_id": ["type": "string"],
                    "ts": ["type": "string"],
                    "name": ["type": "string"]
                ],
                "required": ["workspace_id", "channel_id", "ts", "name"]
            ]),
            ("list_automations", "List local automation rules.", ["type": "object", "properties": [:]]),
            ("run_automation", "Run a local automation by id.", [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"]
            ])
        ]
        return tools.map { name, desc, schema in
            [
                "name": name,
                "description": desc,
                "inputSchema": schema
            ]
        }
    }

    // MARK: - HTTP helpers

    private struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private static func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let available = data.count - bodyStart
        if contentLength > available { return nil }
        let body = contentLength > 0 ? data.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Headers": "Authorization, Content-Type",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
        ]
    }

    private static func auditDetail(arguments: [String: Any]) -> String? {
        var parts: [String] = []
        if let w = arguments["workspace_id"] as? String { parts.append("ws=\(w)") }
        if let c = arguments["channel_id"] as? String { parts.append("ch=\(c)") }
        if let id = arguments["id"] as? String { parts.append("id=\(id)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func sendJSON(connection: NWConnection, status: Int, object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        send(connection: connection, status: status, headers: headers, body: data)
    }

    private func send(connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "OK"
        }
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        for (k, v) in headers {
            response += "\(k): \(v)\r\n"
        }
        response += "\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func rpcResult(id: Any?, result: [String: Any]) -> [String: Any] {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { obj["id"] = id }
        return obj
    }

    private func mcpError(id: Any?, code: Int, message: String) -> [String: Any] {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { obj["id"] = id } else { obj["id"] = NSNull() }
        return obj
    }
}
