import AppKit
import Foundation
import UserNotifications

/// macOS alerts when automations deliver — Slack won't notify you for messages you post yourself.
enum DeliveryNotifier {
    private static var categoriesRegistered = false

    /// Call once from the long-running menu-bar app (never from short-lived headless sends).
    static func configureMainApp() {
        registerCategories()
        UNUserNotificationCenter.current().delegate = DeliveryNotificationDelegate.shared
    }

    static func requestPermissionIfNeeded() {
        Task {
            await requestAuthorizationIfNeeded()
        }
    }

    private static func registerCategories() {
        guard !categoriesRegistered else { return }
        categoriesRegistered = true
        let open = UNNotificationAction(
            identifier: "open_slack",
            title: "Open in Slack",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "sab.automation",
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Waits until the notification is queued (and briefly after) so short-lived processes still show it.
    static func notifyAutomationDelivered(
        workspaceName: String,
        preview: String,
        inboxLabel: String,
        teamID: String?,
        channelID: String?
    ) async {
        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "\(inboxLabel) — \(workspaceName)"
        let line = preview
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? preview
        content.body = String(line.prefix(180))
        content.sound = .default
        if teamID != nil, channelID != nil {
            content.categoryIdentifier = "sab.automation"
        }
        if let teamID, let channelID {
            content.userInfo = [
                "teamID": teamID,
                "channelID": channelID,
                "slackURL": "slack://channel?team=\(teamID)&id=\(channelID)"
            ]
        }

        let id = "sab-delivery-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        Log.info("Mac notification enqueue failed: \(error.localizedDescription)")
                    }
                    continuation.resume()
                }
            }
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    private static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                continuation.resume()
            }
        }
    }

    @discardableResult
    static func openInbox(teamID: String, channelID: String) -> Bool {
        let deepLink = URL(string: "slack://channel?team=\(teamID)&id=\(channelID)")
        let webLink = URL(string: "https://app.slack.com/client/\(teamID)/\(channelID)")
        let urls = [deepLink, webLink].compactMap { $0 }

        if let slackApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap"),
           let url = urls.first {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: slackApp, configuration: config) { _, error in
                if error != nil, let fallback = urls.last {
                    NSWorkspace.shared.open(fallback)
                }
            }
            return true
        }

        for url in urls where NSWorkspace.shared.open(url) {
            return true
        }
        return false
    }
}

// MARK: - Click handler (owned by the menu-bar app process only)

final class DeliveryNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DeliveryNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let openActions: Set<String> = [
            UNNotificationDefaultActionIdentifier,
            "open_slack"
        ]
        guard openActions.contains(response.actionIdentifier) else { return }

        let info = response.notification.request.content.userInfo
        guard let teamID = info["teamID"] as? String,
              let channelID = info["channelID"] as? String else { return }

        DispatchQueue.main.async {
            _ = DeliveryNotifier.openInbox(teamID: teamID, channelID: channelID)
        }
    }
}
