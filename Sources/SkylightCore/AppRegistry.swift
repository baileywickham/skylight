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

    /// The wire description of one running app.
    public func info(for app: NSRunningApplication) -> AppInfo {
        AppInfo(name: app.localizedName ?? "(unnamed)",
                bundle_id: app.bundleIdentifier,
                pid: app.processIdentifier,
                is_frontmost: app.isActive,
                launch_date: app.launchDate.map(iso8601.string(from:)),
                menu_bar_only: app.activationPolicy == .accessory ? true : nil)
    }

    /// Where installed apps live, searched in order by `locateApplication`.
    public static let applicationDirectories: [URL] = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices",
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// The bundle of an installed (not necessarily running) app: an .app path
    /// as given, else the bundle id via Launch Services, else an app of that
    /// name (case-insensitive) in `directories`.
    public func locateApplication(_ identifier: String,
                                  directories: [URL] = AppRegistry.applicationDirectories) -> URL? {
        let fm = FileManager.default
        if identifier.hasSuffix(".app"), identifier.contains("/") {
            let url = URL(fileURLWithPath: (identifier as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        if identifier.contains("."), !identifier.contains(" "),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        let wanted = identifier.lowercased().hasSuffix(".app") ? identifier.lowercased() : identifier.lowercased() + ".app"
        for dir in directories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let match = entries.first(where: { $0.lowercased() == wanted }) {
                return dir.appendingPathComponent(match)
            }
        }
        return nil
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
