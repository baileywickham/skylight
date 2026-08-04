import AppKit
import Foundation

public final class AppRegistry {
    private let iso8601 = ISO8601DateFormatter()

    public init() {}

    /// Targetable apps. Default: regular activation policy (visible in the
    /// Dock). `includeMenuBarApps` adds accessory-policy (LSUIElement) apps —
    /// menu bar extras like status-item utilities — tagged `menu_bar_only` so
    /// the model knows to expect a status item instead of windows. Off by
    /// default: the accessory list is dominated by system agents (Control
    /// Center, Spotlight, …) that would drown out the real targets.
    public func listApps(includeMenuBarApps: Bool = false) -> ListAppsResult {
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    || (includeMenuBarApps && $0.activationPolicy == .accessory)
            }
            .map { app in
                AppInfo(
                    name: app.localizedName ?? "(unnamed)",
                    bundle_id: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    is_frontmost: app.isActive,
                    launch_date: app.launchDate.map(iso8601.string(from:)),
                    menu_bar_only: app.activationPolicy == .accessory ? true : nil)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ListAppsResult(apps: apps)
    }

    /// Resolves an AppIdentifier: exact bundle id first, then display name
    /// (case-insensitive). Regular (Dock) apps win over accessory (menu bar)
    /// apps on a name collision; accessory apps are always resolvable even
    /// though list_apps hides them by default — the caller already knows the
    /// name of the menu bar app they want.
    public func resolve(_ identifier: String) throws -> NSRunningApplication {
        let running = NSWorkspace.shared.runningApplications
        for policy: NSApplication.ActivationPolicy in [.regular, .accessory] {
            let candidates = running.filter { $0.activationPolicy == policy }
            if let byBundle = candidates.first(where: { $0.bundleIdentifier == identifier }) {
                return byBundle
            }
            if let byName = candidates.first(where: {
                $0.localizedName?.caseInsensitiveCompare(identifier) == .orderedSame
            }) {
                return byName
            }
        }
        throw SkyServiceError(code: .appNotFound,
                              message: "no running app matches '\(identifier)'; call list_apps for targets")
    }
}
