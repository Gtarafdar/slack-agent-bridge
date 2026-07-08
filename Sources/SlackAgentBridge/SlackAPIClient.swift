import Foundation

enum SlackError: LocalizedError {
    case notConnected
    case authExpired
    case rateLimited(retryAfter: TimeInterval?)
    case api(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Slack."
        case .authExpired: return "Slack session expired. Refresh the local session."
        case .rateLimited: return "Slack rate limit reached. Retrying shortly."
        case .api(let m): return "Slack error: \(m)"
        case .network(let m): return "Network error: \(m)"
        }
    }
}

struct SlackChannel: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var isChannel: Bool
    var isGroup: Bool
    var isIM: Bool
    var isMPIM: Bool
    var isPrivate: Bool
    var isMember: Bool
    var userID: String?
    /// Resolved human name for IM / MPIM peers (filled after users.list).
    var peerLabel: String?
    /// True when this IM is your DM with yourself (Slack "Jot something down").
    var isSelfDM: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, isChannel, isGroup, isIM, isMPIM, isPrivate, isMember, userID, peerLabel, isSelfDM
    }

    init(id: String, name: String, isChannel: Bool, isGroup: Bool, isIM: Bool, isMPIM: Bool,
         isPrivate: Bool, isMember: Bool, userID: String?, peerLabel: String? = nil, isSelfDM: Bool = false) {
        self.id = id
        self.name = name
        self.isChannel = isChannel
        self.isGroup = isGroup
        self.isIM = isIM
        self.isMPIM = isMPIM
        self.isPrivate = isPrivate
        self.isMember = isMember
        self.userID = userID
        self.peerLabel = peerLabel
        self.isSelfDM = isSelfDM
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isChannel = try c.decodeIfPresent(Bool.self, forKey: .isChannel) ?? false
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        isIM = try c.decodeIfPresent(Bool.self, forKey: .isIM) ?? false
        isMPIM = try c.decodeIfPresent(Bool.self, forKey: .isMPIM) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isMember = try c.decodeIfPresent(Bool.self, forKey: .isMember) ?? true
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        peerLabel = try c.decodeIfPresent(String.self, forKey: .peerLabel)
        isSelfDM = try c.decodeIfPresent(Bool.self, forKey: .isSelfDM) ?? false
    }

    var displayName: String {
        if isIM {
            if isSelfDM { return "DM — Me (notes to self)" }
            if let peer = peerLabel, peer == "Agent Bridge inbox" {
                return "DM — Agent Bridge inbox (Slackbot)"
            }
            if isIM, userID == Self.slackbotUserID, let peer = peerLabel, !peer.isEmpty {
                return "DM — \(peer) (Slackbot)"
            }
            if let peer = peerLabel, !peer.isEmpty { return "DM — \(peer)" }
            if !name.isEmpty, !name.hasPrefix("U"), name != id { return "DM — \(name)" }
            return "Direct message"
        }
        if isMPIM {
            if let peer = peerLabel, !peer.isEmpty { return peer }
            if !name.isEmpty { return name.replacingOccurrences(of: ",", with: ", ") }
            return "Group DM"
        }
        return name.hasPrefix("#") ? name : "#\(name)"
    }

    static let slackbotUserID = "USLACKBOT"

    /// True MPIM, or the Slackbot DM Slack opens for you + Slackbot automation inboxes.
    var isAutomationInboxEligible: Bool {
        isMPIM || (isIM && userID == Self.slackbotUserID)
    }

    /// Placeholder row when the inbox id is configured but not yet in the channel list.
    static func syntheticAutomationInbox(id: String, label: String = "Agent Bridge inbox") -> SlackChannel {
        SlackChannel(
            id: id,
            name: "slackbot",
            isChannel: false,
            isGroup: false,
            isIM: true,
            isMPIM: false,
            isPrivate: true,
            isMember: true,
            userID: Self.slackbotUserID,
            peerLabel: label,
            isSelfDM: false
        )
    }

    /// Secondary line for UI.
    var subtitle: String? {
        if isIM, isSelfDM {
            if let peer = peerLabel, !peer.isEmpty {
                return "\(peer) · your DM with yourself (digests & automations)"
            }
            return "Your DM with yourself — not a conversation with someone else"
        }
        if isIM, peerLabel != nil, let userID, !userID.isEmpty { return userID }
        return nil
    }
}

struct SlackMessage: Identifiable, Equatable, Codable {
    var id: String { "\(channelID):\(ts)" }
    var workspaceID: String
    var channelID: String
    var ts: String
    var threadTs: String?
    var userID: String?
    var text: String
    var replyCount: Int
    var subtype: String?

    var date: Date {
        Date(timeIntervalSince1970: Double(ts) ?? 0)
    }
}

struct SlackUser: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var realName: String?
    var displayName: String?
    var tz: String?
    var isBot: Bool

    var label: String {
        displayName?.isEmpty == false ? displayName! : (realName ?? name)
    }

    /// Human-friendly label for DM lists (name + @handle when they differ).
    var dmLabel: String {
        let primary = label
        if !name.isEmpty, name != primary, !primary.contains("@\(name)") {
            return "\(primary) (@\(name))"
        }
        return primary
    }
}

final class SlackAPIClient {
    private let session: URLSession
    private var lastRequestAt: Date = .distantPast
    private let minInterval: TimeInterval = 0.35

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Auth / identity

    func authTest(token: String, cookie: String) async throws
        -> (userID: String, teamID: String, team: String, url: String?) {
        let json = try await post(endpoint: "auth.test", body: "", token: token, cookie: cookie)
        let userID = (json["user_id"] as? String) ?? ""
        let teamID = (json["team_id"] as? String) ?? (json["team"] as? String) ?? ""
        let team = (json["team"] as? String) ?? "Slack"
        let url = json["url"] as? String
        return (userID, teamID, team, url)
    }

    // MARK: - Channels

    func listConversations(token: String, cookie: String, types: String = "public_channel,private_channel,mpim,im") async throws -> [SlackChannel] {
        var channels: [SlackChannel] = []
        var cursor: String?
        repeat {
            var body = "limit=200&exclude_archived=true&types=\(types.formEncoded)"
            if let cursor, !cursor.isEmpty {
                body += "&cursor=\(cursor.formEncoded)"
            }
            let json = try await post(endpoint: "conversations.list", body: body, token: token, cookie: cookie)
            if let list = json["channels"] as? [[String: Any]] {
                for raw in list {
                    if let ch = parseChannel(raw) { channels.append(ch) }
                }
            }
            cursor = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String)
            if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        return channels
    }

    func openIM(userID: String, token: String, cookie: String) async throws -> String {
        let body = "users=\(userID.formEncoded)"
        let json = try await post(endpoint: "conversations.open", body: body, token: token, cookie: cookie)
        let channel = json["channel"] as? [String: Any]
        guard let id = channel?["id"] as? String else {
            throw SlackError.api("im_open_failed")
        }
        return id
    }

    /// Opens or returns a multiparty DM. Used for discreet automation inboxes.
    func openMPIM(userIDs: [String], token: String, cookie: String) async throws -> String {
        let unique = Array(Set(userIDs)).filter { !$0.isEmpty }
        guard unique.count >= 2 else { throw SlackError.api("mpim_needs_two_users") }
        let body = "users=\(unique.joined(separator: ",").formEncoded)"
        let json = try await post(endpoint: "conversations.open", body: body, token: token, cookie: cookie)
        let channel = json["channel"] as? [String: Any]
        guard let id = channel?["id"] as? String else {
            throw SlackError.api("mpim_open_failed")
        }
        return id
    }

    /// Stars a conversation for the signed-in user (appears under Starred in Slack).
    func starChannel(channelID: String, token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)"
        _ = try await post(endpoint: "stars.add", body: body, token: token, cookie: cookie)
    }

    /// Sets conversation topic (works on channels/MPIMs; best-effort on IM).
    func setConversationTopic(channelID: String, topic: String, token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&topic=\(topic.formEncoded)"
        _ = try await post(endpoint: "conversations.setTopic", body: body, token: token, cookie: cookie)
    }

    // MARK: - History

    func history(channelID: String, token: String, cookie: String,
                 latest: String? = nil, oldest: String? = nil,
                 cursor: String? = nil, limit: Int = 200) async throws
        -> (messages: [[String: Any]], nextCursor: String?) {
        var body = "channel=\(channelID.formEncoded)&limit=\(limit)&inclusive=true"
        if let latest { body += "&latest=\(latest.formEncoded)" }
        if let oldest { body += "&oldest=\(oldest.formEncoded)" }
        if let cursor, !cursor.isEmpty { body += "&cursor=\(cursor.formEncoded)" }
        let json = try await post(endpoint: "conversations.history", body: body, token: token, cookie: cookie)
        let messages = (json["messages"] as? [[String: Any]]) ?? []
        let next = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String)
        return (messages, (next?.isEmpty == false) ? next : nil)
    }

    func replies(channelID: String, threadTs: String, token: String, cookie: String,
                 cursor: String? = nil, limit: Int = 200) async throws
        -> (messages: [[String: Any]], nextCursor: String?) {
        var body = "channel=\(channelID.formEncoded)&ts=\(threadTs.formEncoded)&limit=\(limit)"
        if let cursor, !cursor.isEmpty { body += "&cursor=\(cursor.formEncoded)" }
        let json = try await post(endpoint: "conversations.replies", body: body, token: token, cookie: cookie)
        let messages = (json["messages"] as? [[String: Any]]) ?? []
        let next = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String)
        return (messages, (next?.isEmpty == false) ? next : nil)
    }

    // MARK: - Users

    func userInfo(userID: String, token: String, cookie: String) async throws -> SlackUser {
        let body = "user=\(userID.formEncoded)"
        let json = try await post(endpoint: "users.info", body: body, token: token, cookie: cookie)
        guard let user = json["user"] as? [String: Any],
              let parsed = parseUser(user) else {
            throw SlackError.api("user_not_found")
        }
        return parsed
    }

    func usersList(token: String, cookie: String) async throws -> [SlackUser] {
        var users: [SlackUser] = []
        var cursor: String?
        repeat {
            var body = "limit=200"
            if let cursor, !cursor.isEmpty { body += "&cursor=\(cursor.formEncoded)" }
            let json = try await post(endpoint: "users.list", body: body, token: token, cookie: cookie)
            if let list = json["members"] as? [[String: Any]] {
                for raw in list {
                    if let u = parseUser(raw) { users.append(u) }
                }
            }
            cursor = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String)
            if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        return users
    }

    // MARK: - Search (live; subject to Slack Free limits)

    func searchMessages(query: String, token: String, cookie: String, count: Int = 20) async throws -> [[String: Any]] {
        let body = "query=\(query.formEncoded)&count=\(count)&sort=timestamp&sort_dir=desc"
        let json = try await post(endpoint: "search.messages", body: body, token: token, cookie: cookie)
        let messages = json["messages"] as? [String: Any]
        return (messages?["matches"] as? [[String: Any]]) ?? []
    }

    // MARK: - Writes

    func postMessage(channelID: String, text: String, token: String, cookie: String,
                     threadTs: String? = nil) async throws -> String {
        var body = "channel=\(channelID.formEncoded)&text=\(text.formEncoded)&as_user=true"
        if let threadTs { body += "&thread_ts=\(threadTs.formEncoded)" }
        let json = try await post(endpoint: "chat.postMessage", body: body, token: token, cookie: cookie)
        return (json["ts"] as? String) ?? ""
    }

    /// Creates a private channel using the signed-in user's session (no Slack app admin approval).
    func createPrivateChannel(name: String, token: String, cookie: String) async throws -> SlackChannel {
        let sanitized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !sanitized.isEmpty else { throw SlackError.api("invalid_channel_name") }
        let body = "name=\(sanitized.formEncoded)&is_private=true"
        let json = try await post(endpoint: "conversations.create", body: body, token: token, cookie: cookie)
        guard let raw = json["channel"] as? [String: Any],
              let channel = parseChannel(raw) else {
            throw SlackError.api("channel_create_failed")
        }
        return channel
    }

    func addReminder(text: String, time: String, token: String, cookie: String) async throws -> String {
        let body = "text=\(text.formEncoded)&time=\(time.formEncoded)"
        let json = try await post(endpoint: "reminders.add", body: body, token: token, cookie: cookie)
        let reminder = json["reminder"] as? [String: Any]
        return (reminder?["id"] as? String) ?? ""
    }

    func setStatus(text: String, emoji: String, expiration: Int,
                   token: String, cookie: String) async throws {
        let profile: [String: Any] = [
            "status_text": text,
            "status_emoji": emoji,
            "status_expiration": expiration
        ]
        guard let profileData = try? JSONSerialization.data(withJSONObject: profile),
              let profileJSON = String(data: profileData, encoding: .utf8) else {
            throw SlackError.api("encode_failed")
        }
        let body = "profile=" + profileJSON.formEncoded
        _ = try await post(endpoint: "users.profile.set", body: body, token: token, cookie: cookie)
    }

    func addReaction(channelID: String, timestamp: String, name: String,
                     token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&timestamp=\(timestamp.formEncoded)&name=\(name.formEncoded)"
        _ = try await post(endpoint: "reactions.add", body: body, token: token, cookie: cookie)
    }

    func pinMessage(channelID: String, timestamp: String,
                    token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&timestamp=\(timestamp.formEncoded)"
        _ = try await post(endpoint: "pins.add", body: body, token: token, cookie: cookie)
    }

    func unpinMessage(channelID: String, timestamp: String,
                      token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&timestamp=\(timestamp.formEncoded)"
        _ = try await post(endpoint: "pins.remove", body: body, token: token, cookie: cookie)
    }

    func removeReaction(channelID: String, timestamp: String, name: String,
                        token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&timestamp=\(timestamp.formEncoded)&name=\(name.formEncoded)"
        _ = try await post(endpoint: "reactions.remove", body: body, token: token, cookie: cookie)
    }

    func updateMessage(channelID: String, timestamp: String, text: String,
                       token: String, cookie: String) async throws -> String {
        let body = "channel=\(channelID.formEncoded)&ts=\(timestamp.formEncoded)&text=\(text.formEncoded)"
        let json = try await post(endpoint: "chat.update", body: body, token: token, cookie: cookie)
        return (json["ts"] as? String) ?? timestamp
    }

    func deleteMessage(channelID: String, timestamp: String,
                       token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&ts=\(timestamp.formEncoded)"
        _ = try await post(endpoint: "chat.delete", body: body, token: token, cookie: cookie)
    }

    /// Schedules a message (Slack `chat.scheduleMessage`). `postAt` is Unix seconds.
    func scheduleMessage(channelID: String, text: String, postAt: Int,
                         token: String, cookie: String, threadTs: String? = nil) async throws -> String {
        var body = "channel=\(channelID.formEncoded)&text=\(text.formEncoded)&post_at=\(postAt)&as_user=true"
        if let threadTs { body += "&thread_ts=\(threadTs.formEncoded)" }
        let json = try await post(endpoint: "chat.scheduleMessage", body: body, token: token, cookie: cookie)
        let scheduled = json["scheduled_message_id"] as? String
        return scheduled ?? (json["message"] as? [String: Any])?["scheduled_message_id"] as? String ?? ""
    }

    func listScheduledMessages(channelID: String?, token: String, cookie: String) async throws -> [[String: Any]] {
        var body = ""
        if let channelID, !channelID.isEmpty {
            body = "channel=\(channelID.formEncoded)"
        }
        let json = try await post(endpoint: "chat.scheduledMessages.list", body: body, token: token, cookie: cookie)
        return (json["scheduled_messages"] as? [[String: Any]]) ?? []
    }

    func deleteScheduledMessage(channelID: String, scheduledMessageID: String,
                              token: String, cookie: String) async throws {
        let body = "channel=\(channelID.formEncoded)&scheduled_message_id=\(scheduledMessageID.formEncoded)"
        _ = try await post(endpoint: "chat.deleteScheduledMessage", body: body, token: token, cookie: cookie)
    }

    // MARK: - Parsing helpers

    func parseHistoryMessage(_ raw: [String: Any], workspaceID: String, channelID: String) -> SlackMessage? {
        guard let ts = raw["ts"] as? String else { return nil }
        let text = (raw["text"] as? String) ?? ""
        let userID = raw["user"] as? String
        let threadTs = raw["thread_ts"] as? String
        let replyCount = (raw["reply_count"] as? Int) ?? 0
        let subtype = raw["subtype"] as? String
        return SlackMessage(
            workspaceID: workspaceID,
            channelID: channelID,
            ts: ts,
            threadTs: threadTs,
            userID: userID,
            text: text,
            replyCount: replyCount,
            subtype: subtype
        )
    }

    private func parseChannel(_ raw: [String: Any]) -> SlackChannel? {
        guard let id = raw["id"] as? String else { return nil }
        let name = (raw["name"] as? String) ?? ""
        return SlackChannel(
            id: id,
            name: name,
            isChannel: (raw["is_channel"] as? Bool) ?? false,
            isGroup: (raw["is_group"] as? Bool) ?? false,
            isIM: (raw["is_im"] as? Bool) ?? false,
            isMPIM: (raw["is_mpim"] as? Bool) ?? false,
            isPrivate: (raw["is_private"] as? Bool) ?? false,
            isMember: (raw["is_member"] as? Bool) ?? true,
            userID: raw["user"] as? String,
            peerLabel: nil,
            isSelfDM: false
        )
    }

    private func parseUser(_ raw: [String: Any]) -> SlackUser? {
        guard let id = raw["id"] as? String else { return nil }
        let profile = raw["profile"] as? [String: Any]
        return SlackUser(
            id: id,
            name: (raw["name"] as? String) ?? id,
            realName: raw["real_name"] as? String,
            displayName: profile?["display_name"] as? String,
            tz: raw["tz"] as? String,
            isBot: (raw["is_bot"] as? Bool) ?? false
        )
    }

    // MARK: - HTTP

    @discardableResult
    private func post(endpoint: String, body: String,
                      token: String, cookie: String) async throws -> [String: Any] {
        try await throttle()
        guard let url = URL(string: "https://slack.com/api/\(endpoint)") else {
            throw SlackError.api("invalid_url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SlackError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw SlackError.rateLimited(retryAfter: retry)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.api("invalid_response")
        }

        let ok = (json["ok"] as? Bool) ?? false
        if !ok {
            let err = (json["error"] as? String) ?? "unknown"
            if err == "invalid_auth" || err == "token_expired"
                || err == "not_authed" || err == "token_revoked" {
                throw SlackError.authExpired
            }
            if err == "ratelimited" {
                throw SlackError.rateLimited(retryAfter: nil)
            }
            throw SlackError.api(err)
        }
        return json
    }

    private func throttle() async throws {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minInterval {
            let delay = UInt64((minInterval - elapsed) * 1_000_000_000)
            try await Task.sleep(nanoseconds: delay)
        }
        lastRequestAt = Date()
    }
}

extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?/")
        return set
    }()
}
