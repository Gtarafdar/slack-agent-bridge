import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settings = Settings.shared
    private var bridge: BridgeController!
    private var cancellables = Set<AnyCancellable>()

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SAB_SELFTEST"] == "1" {
            let ok = SetupWizardValidation.runSelfTest()
            exit(ok ? 0 : 1)
        }

        if !SingleInstanceGuard.enforce() {
            exit(0)
        }

        if let text = ProcessInfo.processInfo.environment["SAB_SEND_TEXT"], !text.isEmpty {
            NSApp.setActivationPolicy(.accessory)
            DeliveryNotifier.configureMainApp()
            bridge = BridgeController(settings: settings)
            Task {
                let ok = await self.sendHeadlessMessage(text)
                exit(ok ? 0 : 1)
            }
            return
        }

        NSApp.setActivationPolicy(.accessory)

        AppBranding.applyApplicationIcon()

        bridge = BridgeController(settings: settings)
        bridge.bootstrap()
        DeliveryNotifier.configureMainApp()
        DeliveryNotifier.requestPermissionIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            applyMenuBarIcon(status: bridge.status, to: button)
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        bridge.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, let button = self.statusItem.button else { return }
                self.applyMenuBarIcon(status: status, to: button)
            }
            .store(in: &cancellables)
    }

    private func applyMenuBarIcon(status: BridgeStatus, to button: NSStatusBarButton) {
        let variant: AppBranding.MenuBarVariant = switch status {
        case .disconnected: .default
        case .connected: .connected
        case .syncing: .syncing
        case .error: .error
        }
        if let image = AppBranding.menuBarIcon(variant: variant) {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.image?.isTemplate = true
        }
        button.alphaValue = status == .disconnected ? 0.5 : 1.0
        button.toolTip = "\(AppBranding.appDisplayName) — \(status.label)"
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.shutdown()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            showSettings()
            return
        }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            showSettings()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if let icon = AppBranding.menuBarIcon() {
            let titleItem = NSMenuItem(title: AppBranding.appDisplayName, action: nil, keyEquivalent: "")
            titleItem.image = icon
            titleItem.isEnabled = false
            menu.addItem(titleItem)
            menu.addItem(NSMenuItem.separator())
        }
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettingsAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let mcpState = bridge.mcpRunning ? "MCP: Running on \(settings.mcpPort)" : "MCP: Stopped"
        menu.addItem(NSMenuItem(title: mcpState, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Slack Agent Bridge", action: #selector(quitAction), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func sendHeadlessMessage(_ text: String) async -> Bool {
        guard settings.allowHeadlessCLI else {
            fputs(
                "Headless send (SAB_SEND_TEXT) is disabled. Enable it in Slack Agent Bridge → Privacy & Advanced → Allow CLI send.\n",
                stderr
            )
            return false
        }
        if !bridge.isConnected {
            guard await bridge.useLocalSession() else {
                fputs("Slack session not available: \(bridge.lastError ?? "unknown")\n", stderr)
                return false
            }
        }
        guard let workspace = bridge.workspaces.first(where: { settings.config(for: $0.id).enabled })
            ?? bridge.workspaces.first else {
            fputs("No Slack workspace found.\n", stderr)
            return false
        }
        do {
            let toSelfDM = ProcessInfo.processInfo.environment["SAB_SEND_SELF"] == "1"
            if toSelfDM {
                let config = settings.config(for: workspace.id)
                guard config.capabilities.postToMyDM else {
                    fputs(
                        "postToMyDM is not enabled for workspace \(workspace.id). Enable it in workspace capabilities.\n",
                        stderr
                    )
                    return false
                }
                try await bridge.automations.sendToSelfDM(
                    workspaceID: workspace.id,
                    text: text,
                    bridge: bridge
                )
                let selfChannel = bridge.settings.identities[workspace.id]?.selfDMChannelID
                await bridge.automations.notifyAutomationDelivery(
                    workspaceID: workspace.id,
                    text: text,
                    bridge: bridge,
                    channelIDOverride: selfChannel,
                    labelOverride: "Personal DM"
                )
            } else {
                try await bridge.automations.deliverAutomation(
                    workspaceID: workspace.id,
                    text: text,
                    bridge: bridge
                )
            }
            return true
        } catch {
            fputs("Send failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsRootView(
            settings: settings,
            bridge: bridge,
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppBranding.appDisplayName
        if let icon = AppBranding.appIcon {
            window.representedURL = nil
            NSApplication.shared.applicationIconImage = icon
        }
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
