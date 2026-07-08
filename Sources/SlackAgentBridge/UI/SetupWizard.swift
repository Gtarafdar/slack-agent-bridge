import SwiftUI
import AppKit

// MARK: - Steps

enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case connectSlack = 0
    case enableWorkspace = 1
    case chooseChannels = 2
    case createToken = 3
    case linkAgent = 4
    case finish = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .connectSlack: return "Connect Slack"
        case .enableWorkspace: return "Enable a workspace"
        case .chooseChannels: return "Choose channels"
        case .createToken: return "Create agent token"
        case .linkAgent: return "Link your AI agent"
        case .finish: return "You're all set"
        }
    }

    var instructions: String {
        switch self {
        case .connectSlack:
            return "Sign in to the Slack desktop app on this Mac, then connect your session below."
        case .enableWorkspace:
            return "Turn on at least one workspace. Leave write capabilities off until you need them."
        case .chooseChannels:
            return "Click Configure on a workspace, refresh channels, then mark Archive and Agent access."
        case .createToken:
            return "Create a token for Cursor or Claude. Copy the mcp.json snippet on the next step."
        case .linkAgent:
            return "Paste the mcp.json snippet into Cursor or Claude, then test the connection here."
        case .finish:
            return "Setup is complete. Agents can search archived Slack on this Mac."
        }
    }

    var settingsTab: Int {
        switch self {
        case .connectSlack: return 1
        case .enableWorkspace, .chooseChannels: return 2
        case .createToken, .linkAgent: return 5
        case .finish: return 0
        }
    }
}

struct SetupWizardSnapshot: Equatable {
    var isConnected = false
    var workspaceEnabled = false
    var hasArchiveChannels = false
    var hasAgentChannels = false
    var hasToken = false
    var mcpRunning = false
    var agentLinkVerified = false
    var agentLinkAcknowledged = false
    var tourCompleted = false

    @MainActor
    static func live(settings: Settings, bridge: BridgeController) -> SetupWizardSnapshot {
        SetupWizardSnapshot(
            isConnected: bridge.isConnected,
            workspaceEnabled: bridge.workspaces.contains { settings.config(for: $0.id).enabled },
            hasArchiveChannels: bridge.workspaces.contains { !settings.config(for: $0.id).archivedChannelIDs.isEmpty },
            hasAgentChannels: bridge.workspaces.contains { !settings.config(for: $0.id).agentChannelIDs.isEmpty },
            hasToken: !bridge.tokens.tokens.isEmpty,
            mcpRunning: bridge.mcpRunning,
            agentLinkVerified: settings.agentLinkVerified,
            agentLinkAcknowledged: settings.agentLinkAcknowledged,
            tourCompleted: settings.tourCompleted
        )
    }
}

enum SetupStepStatus: Equatable {
    case complete
    case pending(String)

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    var message: String? {
        if case .pending(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Validation

enum SetupWizardValidation {
    static func stepStatus(_ step: SetupWizardStep, snapshot: SetupWizardSnapshot) -> SetupStepStatus {
        switch step {
        case .connectSlack:
            return snapshot.isConnected ? .complete : .pending("Connect Slack session")
        case .enableWorkspace:
            return snapshot.workspaceEnabled ? .complete : .pending("Enable a workspace toggle")
        case .chooseChannels:
            if snapshot.hasArchiveChannels && snapshot.hasAgentChannels { return .complete }
            if !snapshot.hasArchiveChannels && !snapshot.hasAgentChannels {
                return .pending("Select Archive and Agent channels")
            }
            if !snapshot.hasArchiveChannels { return .pending("Mark at least one Archive channel") }
            return .pending("Mark at least one Agent channel")
        case .createToken:
            return snapshot.hasToken ? .complete : .pending("Create an agent token")
        case .linkAgent:
            if snapshot.agentLinkVerified { return .complete }
            if !snapshot.hasToken { return .pending("Create a token first") }
            if !snapshot.mcpRunning { return .pending("MCP server must be running") }
            if snapshot.agentLinkAcknowledged { return .complete }
            return .pending("Test connection or confirm you've added mcp.json to your agent")
        case .finish:
            return snapshot.tourCompleted ? .complete : .pending("Click Finish setup")
        }
    }

    static func isStepComplete(_ step: SetupWizardStep, snapshot: SetupWizardSnapshot) -> Bool {
        stepStatus(step, snapshot: snapshot).isComplete
    }

    static func runSelfTest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            if !cond {
                fputs("SetupWizard self-test failed: \(name)\n", stderr)
                ok = false
            }
        }

        var s = SetupWizardSnapshot()
        check("connect pending", !isStepComplete(.connectSlack, snapshot: s))
        s.isConnected = true
        check("connect complete", isStepComplete(.connectSlack, snapshot: s))

        s.workspaceEnabled = true
        check("workspace complete", isStepComplete(.enableWorkspace, snapshot: s))

        s.hasArchiveChannels = true
        s.hasAgentChannels = true
        check("channels complete", isStepComplete(.chooseChannels, snapshot: s))

        s.hasToken = true
        check("token complete", isStepComplete(.createToken, snapshot: s))

        s.mcpRunning = true
        check("link pending without ack", !isStepComplete(.linkAgent, snapshot: s))
        s.agentLinkAcknowledged = true
        check("link complete with ack", isStepComplete(.linkAgent, snapshot: s))
        s.agentLinkAcknowledged = false
        s.agentLinkVerified = true
        check("link complete with test", isStepComplete(.linkAgent, snapshot: s))

        return ok
    }
}

// MARK: - MCP probe

enum MCPConnectionProbe {
    static func test(port: Int, token: String) async -> (ok: Bool, detail: String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return (false, "Invalid MCP URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "setup-wizard", "version": "1.0"]
            ] as [String: Any]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "No HTTP response")
            }
            switch http.statusCode {
            case 200:
                return (true, "MCP responded OK — your agent can connect")
            case 401:
                return (false, MCPAgentErrors.unauthorizedHTTP)
            default:
                return (false, "Unexpected HTTP \(http.statusCode)")
            }
        } catch {
            return (false, "Could not reach MCP on port \(port). Connect Slack and enable MCP.")
        }
    }
}

// MARK: - Wizard bar

struct SetupWizardBar: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController

    @State private var connectBusy = false
    @State private var testBusy = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var manualTestToken = ""
    @State private var tick = 0

    private var step: SetupWizardStep {
        SetupWizardStep(rawValue: min(max(0, settings.tourStep), SetupWizardStep.finish.rawValue)) ?? .connectSlack
    }

    private var snapshot: SetupWizardSnapshot {
        _ = tick
        return SetupWizardSnapshot.live(settings: settings, bridge: bridge)
    }

    private var status: SetupStepStatus {
        SetupWizardValidation.stepStatus(step, snapshot: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Setup wizard")
                            .font(.headline)
                        Text("Step \(step.rawValue + 1) of \(SetupWizardStep.allCases.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                    Text(step.instructions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                progressDots
            }

            statusRow

            HStack(spacing: 10) {
                stepActions
                Spacer()
                if step.rawValue > 0 {
                    Button("Back") { goBack() }
                }
                if step == .finish {
                    Button("Finish setup") { settings.completeTour() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { goNext() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!status.isComplete)
                }
                Button("Exit wizard") { settings.dismissWizard() }
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { navigateToStepTab() }
        .onChange(of: settings.tourStep) { _ in
            navigateToStepTab()
            testMessage = nil
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            tick &+= 1
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(SetupWizardStep.allCases) { s in
                Circle()
                    .fill(dotColor(for: s))
                    .frame(width: 8, height: 8)
                    .help(s.title)
            }
        }
        .padding(.top, 4)
    }

    private func dotColor(for s: SetupWizardStep) -> Color {
        let snap = SetupWizardSnapshot.live(settings: settings, bridge: bridge)
        if s.rawValue < settings.tourStep { return .green }
        if s.rawValue == settings.tourStep { return .accentColor }
        if SetupWizardValidation.isStepComplete(s, snapshot: snap) { return .green.opacity(0.6) }
        return Color.secondary.opacity(0.35)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: status.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status.isComplete ? .green : .secondary)
            if status.isComplete {
                Text("Step complete")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if let msg = status.message {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let testMessage {
                Text(testMessage)
                    .font(.caption)
                    .foregroundStyle(testOK ? .green : .red)
            }
        }
    }

    @ViewBuilder
    private var stepActions: some View {
        switch step {
        case .connectSlack:
            Button(connectBusy ? "Connecting…" : (bridge.isConnected ? "Refresh session" : "Connect Slack")) {
                connectBusy = true
                Task {
                    _ = await bridge.useLocalSession()
                    connectBusy = false
                }
            }
            .disabled(connectBusy)
            if !bridge.isConnected {
                Text("Tip: if macOS asks about Keychain access, click Always Allow.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .enableWorkspace, .chooseChannels:
            if step == .chooseChannels, let ws = firstEnabledWorkspace() {
                Button("Load channels") {
                    Task { await bridge.loadChannels(for: ws.id) }
                }
            }

        case .createToken:
            Button("Create token") { settings.wizardRequestCreateToken = true }

        case .linkAgent:
            Button("Copy mcp.json") { copyMCPSnippet() }
            Button(testBusy ? "Testing…" : "Test connection") {
                testBusy = true
                Task {
                    await runConnectionTest()
                    testBusy = false
                }
            }
            .disabled(testBusy || bridge.tokens.tokens.isEmpty)
            if bridge.tokens.lastIssuedPlaintext == nil && !bridge.tokens.tokens.isEmpty {
                SecureField("Token for test (if dismissed)", text: $manualTestToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            Toggle("I've added mcp.json to my agent", isOn: $settings.agentLinkAcknowledged)
                .toggleStyle(.checkbox)
                .font(.caption)

        case .finish:
            EmptyView()
        }
    }

    private func goNext() {
        guard status.isComplete else { return }
        settings.tourStep = min(settings.tourStep + 1, SetupWizardStep.finish.rawValue)
        navigateToStepTab()
    }

    private func goBack() {
        settings.tourStep = max(0, settings.tourStep - 1)
        navigateToStepTab()
    }

    private func navigateToStepTab() {
        let s = SetupWizardStep(rawValue: settings.tourStep) ?? .connectSlack
        settings.selectedSettingsTab = s.settingsTab
        if s == .chooseChannels, let ws = firstEnabledWorkspace() {
            settings.wizardExpandWorkspaceID = ws.id
            if bridge.channelCache[ws.id] == nil {
                Task { await bridge.loadChannels(for: ws.id) }
            }
        }
    }

    private func firstEnabledWorkspace() -> SlackWorkspace? {
        bridge.workspaces.first { settings.config(for: $0.id).enabled }
    }

    private func copyMCPSnippet() {
        guard let token = tokenForTest() else {
            testOK = false
            testMessage = "Create an agent token first, or paste it in the test field."
            return
        }
        let snippet = bridge.tokens.mcpJSONSnippet(token: token, port: settings.mcpPort)
        if PasteboardHelper.copy(snippet) {
            testOK = true
            testMessage = "mcp.json copied to clipboard"
        } else {
            testOK = false
            testMessage = "Could not copy to clipboard"
        }
    }

    private func tokenForTest() -> String? {
        if let issued = bridge.tokens.lastIssuedPlaintext?.token { return issued }
        let trimmed = manualTestToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runConnectionTest() async {
        guard let token = tokenForTest() else {
            testOK = false
            testMessage = "Enter or create a token first"
            return
        }
        let result = await MCPConnectionProbe.test(port: settings.mcpPort, token: token)
        testOK = result.ok
        testMessage = result.detail
        if result.ok {
            settings.agentLinkVerified = true
        }
    }
}
