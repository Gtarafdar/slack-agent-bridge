import Foundation

/// Agent-facing error text for MCP tool failures (Cursor, Claude, etc.).
enum MCPAgentErrors {
    static func describe(_ error: Error) -> String {
        if let slack = error as? SlackError {
            return describeSlack(slack)
        }
        return error.localizedDescription
    }

    private static func describeSlack(_ error: SlackError) -> String {
        switch error {
        case .notConnected:
            return """
            slack_session_not_connected: Slack is not connected in Slack Agent Bridge. \
            Open the menu-bar app → Connection → Connect Slack session (Slack desktop must be signed in).
            """
        case .authExpired:
            return """
            slack_session_expired: Your Slack desktop session expired. \
            Open Slack Agent Bridge → Connection → Refresh local session.
            """
        case .rateLimited:
            return "slack_rate_limited: Slack rate limit reached. Retry in a few seconds."
        case .network(let m):
            return "network_error: \(m)"
        case .api(let code):
            if code.hasPrefix("user_not_found") {
                return """
                user_not_found: Could not match that person in the workspace. \
                Try full name (e.g. \"First Last\"), @handle, or user_id from get_user.
                """
            }
            return describeAPICode(code)
        }
    }

    private static func describeAPICode(_ code: String) -> String {
        switch code {
        case "workspace_id_required":
            return "workspace_id_required: Pass workspace_id from list_workspaces."
        case "workspace_not_allowed":
            return """
            agent_token_workspace_denied: This agent token cannot access that workspace. \
            Create or rotate a token in Slack Agent Bridge → Agent Access with the workspace enabled.
            """
        case "workspace_disabled":
            return """
            workspace_not_enabled: Enable the workspace in Slack Agent Bridge → Workspaces before using MCP tools.
            """
        case "capability_denied":
            return "capability_denied: This agent token or workspace does not allow that action. Check capability toggles in Workspaces."
        case "channel_not_allowed_for_agents":
            return "channel_not_allowed: Add the channel to the agent allow-list in Slack Agent Bridge → Workspaces."
        case "slack_session_not_connected":
            return describeSlack(.notConnected)
        case "user_not_found":
            return """
            user_not_found: Could not match that person in the workspace. \
            Try full name (e.g. \"First Last\"), @handle, or user_id from get_user.
            """
        default:
            return "slack_api_error: \(code)"
        }
    }

    static let unauthorizedHTTP = """
    agent_token_unauthorized: Invalid or revoked agent token. \
    Open Slack Agent Bridge → Agent Access → Rotate & copy, then update your agent MCP config \
    (Cursor: Settings → MCP — replace the Bearer token in mcp.json and reload MCP servers).
    """
}
