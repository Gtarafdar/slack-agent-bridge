import AppKit
import SwiftUI

/// Loads bundled app artwork (dock icon, menu bar, in-app branding).
enum AppBranding {
    static let appDisplayName = "Slack Agent Bridge"

    static var appIcon: NSImage? {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            return icon
        }
        return bundleImage(named: "AppIcon-128") ?? bundleImage(named: "AppIcon-64")
    }

    static var appIconSwiftUI: Image? {
        guard let appIcon else { return nil }
        return Image(nsImage: appIcon)
    }

    static func menuBarIcon(variant: MenuBarVariant = .default) -> NSImage? {
        let base = bundleImage(named: variant.resourceName) ?? bundleImage(named: "MenuBarIcon")
        base?.isTemplate = variant.usesTemplate
        return base
    }

    static func applyApplicationIcon() {
        if let icon = appIcon {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    enum MenuBarVariant {
        case `default`
        case connected
        case syncing
        case error

        var resourceName: String {
            switch self {
            case .default, .connected: return "MenuBarIcon"
            case .syncing: return "MenuBarIcon"
            case .error: return "MenuBarIcon"
            }
        }

        var usesTemplate: Bool { true }

        var accessibilityLabel: String { "Slack Agent Bridge" }
    }

    private static func bundleImage(named name: String) -> NSImage? {
        if let image = Bundle.main.image(forResource: name) { return image }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}

struct AppBrandHeader: View {
    var subtitle: String?
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 10 : 14) {
            if let icon = AppBranding.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: compact ? 36 : 52, height: compact ? 36 : 52)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: compact ? 4 : 8, y: 2)
            }
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(AppBranding.appDisplayName)
                    .font(compact ? .headline.weight(.semibold) : .title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
