import Foundation

/// Installs an app bundle over an existing one without the destination ever
/// being absent or half-written.
///
/// This exists because `rm -rf dst && cp -R src dst` — the obvious shell
/// version — loses TCC grants. macOS keys Accessibility/Screen Recording
/// approvals to the app's signature, bundle id, AND on-disk path; deleting the
/// bundle and recreating it over several seconds reads as the app going away,
/// so the grant is dropped and the user has to re-approve after every upgrade.
///
/// `FileManager.replaceItemAt` is the documented API for this: it stages the
/// replacement and swaps it in with a single rename, so the path is always
/// occupied by exactly one complete bundle.
public enum AtomicInstall {
    public enum Failure: Error, CustomStringConvertible {
        case sourceMissing(String)
        case notADirectory(String)
        case crossVolume(source: String, destination: String)
        case replaceFailed(String)

        public var description: String {
            switch self {
            case .sourceMissing(let path):
                return "source bundle does not exist: \(path)"
            case .notADirectory(let path):
                return "source is not an app bundle directory: \(path)"
            case .crossVolume(let source, let destination):
                return """
                    source and destination are on different volumes (\(source) -> \(destination)); \
                    stage the bundle beside the destination first so the swap is a rename
                    """
            case .replaceFailed(let message):
                return "atomic replace failed: \(message)"
            }
        }
    }

    /// True when both paths live on the same volume. A cross-volume "rename" is
    /// really a copy+delete, which reintroduces the window this type exists to
    /// eliminate — so it is rejected rather than silently degraded.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let idA = volumeIdentifier(of: a), let idB = volumeIdentifier(of: b) else { return false }
        return idA.isEqual(idB)
    }

    /// Volume of `url`, or of its nearest existing ancestor — the identifier is
    /// only readable for a path that exists, and a not-yet-created directory is
    /// on whatever volume will contain it.
    private static func volumeIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    /// Replaces `destination` with `source`.
    ///
    /// When nothing exists at `destination` this is a plain move — there is no
    /// prior grant to preserve and nothing to swap. Otherwise the bundle is
    /// staged next to the destination and swapped in.
    ///
    /// `source` is consumed (moved), not copied: callers stage a throwaway copy.
    public static func install(source: URL, destination: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw Failure.sourceMissing(source.path)
        }
        guard isDirectory.boolValue else { throw Failure.notADirectory(source.path) }

        let parent = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        guard sameVolume(source, parent) else {
            throw Failure.crossVolume(source: source.path, destination: parent.path)
        }

        guard fm.fileExists(atPath: destination.path) else {
            do {
                try fm.moveItem(at: source, to: destination)
                return
            } catch {
                throw Failure.replaceFailed("\(error)")
            }
        }

        do {
            // Nil result is fine: it only means the destination URL was reused
            // rather than a new one being minted.
            _ = try fm.replaceItemAt(destination, withItemAt: source,
                                     backupItemName: nil,
                                     options: [.usingNewMetadataOnly])
        } catch {
            throw Failure.replaceFailed("\(error)")
        }
    }
}
