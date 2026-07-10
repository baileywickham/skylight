import AppKit
import Foundation

public final class AppRegistry {
    private let iso8601 = ISO8601DateFormatter()

    public init() {}

    /// Targetable apps: regular activation policy (visible in the Dock).
    public func listApps() -> ListAppsResult {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                AppInfo(
                    name: app.localizedName ?? "(unnamed)",
                    bundle_id: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    is_frontmost: app.isActive,
                    launch_date: app.launchDate.map(iso8601.string(from:)))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ListAppsResult(apps: apps)
    }

    /// Resolves an AppIdentifier: exact bundle id first, then display name (case-insensitive).
    public func resolve(_ identifier: String) throws -> NSRunningApplication {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let byBundle = running.first(where: { $0.bundleIdentifier == identifier }) {
            return byBundle
        }
        if let byName = running.first(where: {
            $0.localizedName?.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return byName
        }
        throw SkyServiceError(code: .appNotFound,
                              message: "no running app matches '\(identifier)'; call list_apps for targets")
    }
}
