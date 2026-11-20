import Foundation
import LumaWallCore

/// Builds a deployment in the app's own folder and moves it into the
/// extension's container whole.
///
/// The old deploy created `videos/<id>/` first and copied gigabytes into it,
/// so a library scan could find the entry empty or half-written, and it
/// hashed the library file before copying it, so a file swapped in between
/// was deployed under the old file's hash. Now the copy is made with
/// `VerifiedFileCopy` in `DeployStaging` under Application Support, hashed
/// as it is written, probed and given its metadata and thumbnail there, then
/// published with one rename under `entryLock`. The sandboxed extension
/// can't reach Application Support, so nothing it does can change a staged
/// entry between the checks and the rename. Both folders sit in the user's
/// home, so the rename stays on one volume.
extension NativeWallpaperDeployment {
    struct StagedDeployment: Sendable {
        /// The staged entry folder, named "<entryID>.<UUID>".
        var directoryURL: URL
        var filename: String
        /// SHA-256 of the bytes staged, which are the bytes deployed.
        var hash: String

        var videoURL: URL { directoryURL.appendingPathComponent(filename) }
    }

    static var deployStagingFolderURL: URL {
        let base =
            (try? StorePaths.appSupportBase())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaWall", isDirectory: true)
        return base.appendingPathComponent("DeployStaging", isDirectory: true)
    }

    /// Copies `source` into a fresh staging folder for `entryID`. Staging
    /// folders an interrupted deploy of the same entry left behind are
    /// deleted first; one entry deploys at a time (see `ensureDeployed`).
    static func stageDeployment(
        source: URL, entryID: String, filename: String,
        stagingFolderURL: URL = deployStagingFolderURL,
        videosFolderURL: URL = videosFolderURL
    ) throws -> StagedDeployment {
        guard PathSafety.isValidEntryID(entryID), PathSafety.isSafeComponent(filename) else {
            throw DeploymentError.invalidEntry
        }
        let fm = FileManager.default
        try fm.createDirectory(at: videosFolderURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingFolderURL, withIntermediateDirectories: true)
        let staging = try TrustedDirectory(url: stagingFolderURL)
        for leftover in try staging.entries() where leftover.name.hasPrefix(entryID + ".") {
            try? staging.removeItem(named: leftover.name)
        }
        let name = "\(entryID).\(UUID().uuidString)"
        let dir = stagingFolderURL.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        do {
            let copy = try VerifiedFileCopy.copy(from: source, to: dir.appendingPathComponent(filename))
            return StagedDeployment(directoryURL: dir, filename: filename, hash: copy.sha256)
        } catch {
            try? staging.removeItem(named: name)
            throw error
        }
    }

    /// Moves a staged entry to `videos/<entryID>`, replacing any entry there
    /// in the same rename. Held under `entryLock`, so a copy of the previous
    /// source being published finishes first and can't land afterwards.
    static func publishDeployment(
        _ staged: StagedDeployment,
        stagingFolderURL: URL = deployStagingFolderURL,
        videosFolderURL: URL = videosFolderURL,
        trustedAncestor: URL = containerURL
    ) throws {
        let entryID = String(staged.directoryURL.lastPathComponent.prefix(while: { $0 != "." }))
        guard PathSafety.isValidEntryID(entryID) else { throw DeploymentError.invalidEntry }
        try entryLock.withLock {
            let staging = try TrustedDirectory(url: stagingFolderURL)
            let videos = try TrustedDirectory(url: videosFolderURL, below: trustedAncestor)
            try staging.publishItem(named: staged.directoryURL.lastPathComponent, into: videos, as: entryID)
        }
    }

    /// Deletes a staged entry that won't be published.
    static func discardStaged(_ staged: StagedDeployment, stagingFolderURL: URL = deployStagingFolderURL) {
        try? TrustedDirectory(url: stagingFolderURL).removeItem(named: staged.directoryURL.lastPathComponent)
    }

    /// True when `name` is a regular file directly inside the entry folder,
    /// with no symlink on the way. Folders outside the extension's container
    /// (tests) are opened from `videosFolderURL` itself.
    static func isRegularFile(_ name: String, inEntry id: String, videosFolderURL: URL = videosFolderURL) -> Bool {
        guard PathSafety.isValidEntryID(id), PathSafety.isSafeComponent(name) else { return false }
        let container = containerURL.standardizedFileURL.pathComponents
        let ancestor =
            videosFolderURL.standardizedFileURL.pathComponents.starts(with: container) ? containerURL : videosFolderURL
        let videos = try? TrustedDirectory(url: videosFolderURL, below: ancestor)
        return (try? videos?.subdirectory(id).kind(ofItemNamed: name)) == .file
    }
}
