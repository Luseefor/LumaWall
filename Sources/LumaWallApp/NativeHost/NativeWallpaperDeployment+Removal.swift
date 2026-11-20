import Foundation
import LumaWallCore
import os

/// Takes a removed wallpaper out of the extension's library.
///
/// Removing a wallpaper used to delete only the library copy. Its deployed
/// video, thumbnail and copies stayed in the container, so System Settings
/// kept offering it, and its queued copy encodes kept running.
extension NativeWallpaperDeployment {
    /// Marks the entry removed, so no new deploy or assignment of it starts.
    /// Call before the first suspension of a removal; see `removedEntries`.
    @MainActor
    static func markRemoved(entryID: String) {
        removedEntries.insert(entryID)
    }

    /// Undoes `markRemoved` when the library kept the wallpaper after all.
    @MainActor
    static func unmarkRemoved(entryID: String) {
        removedEntries.remove(entryID)
    }

    /// Waits for a deploy of the entry still running, stops its copy
    /// encodes, deletes its deployed folder and staged exports, and tells
    /// the extension to rescan so the picker drops it. Throws when the
    /// deployed folder couldn't be deleted, so the caller can say so.
    @MainActor
    static func removeDeployment(entryID: String) async throws {
        guard PathSafety.isValidEntryID(entryID) else { return }
        markRemoved(entryID: entryID)
        // A deploy still running would publish the entry after the delete.
        await waitForDeployment(of: entryID)
        await forgetCopies(for: entryID)
        defer { notifyLibraryChanged() }
        try await Task.detached(priority: .utility) {
            try deleteDeployedFiles(entryID: entryID)
        }.value
    }

    /// Deletes `videos/<entryID>` and the entry's exports in copy staging,
    /// without following symlinks. Under `entryLock`, so a copy published
    /// at the same time either lands first and is deleted with the entry,
    /// or finds the entry gone and is discarded. A missing entry is fine;
    /// any other failure deleting it is thrown. Staged exports are best
    /// effort: startup cleanup removes any left.
    static func deleteDeployedFiles(
        entryID: String,
        videosFolderURL: URL = videosFolderURL,
        stagingFolderURL: URL = stagingFolderURL,
        trustedAncestor: URL = containerURL
    ) throws {
        guard PathSafety.isValidEntryID(entryID) else { throw DeploymentError.invalidEntry }
        try entryLock.withLock {
            if let staging = try? TrustedDirectory(url: stagingFolderURL, below: trustedAncestor) {
                for file in (try? staging.entries()) ?? [] where file.kind == .file && file.name.hasPrefix(entryID + ".") {
                    try? staging.removeFile(named: file.name)
                }
            }
            let videos: TrustedDirectory
            do {
                videos = try TrustedDirectory(url: videosFolderURL, below: trustedAncestor)
            } catch POSIXError.ENOENT {
                return
            }
            do { try videos.removeItem(named: entryID) } catch POSIXError.ENOENT {}
        }
    }

    /// Entries removed from the library whose deployed folder may still be
    /// on disk. `AppModel.remove` adds one before the library row goes and
    /// drops it once `removeDeployment` succeeds, so a quit or a failed
    /// delete in between is finished at the next launch.
    struct PendingRemovals: Sendable {
        let fileURL: URL?

        private static let lock = OSAllocatedUnfairLock()

        var ids: Set<String> { Self.lock.withLockUnchecked { read() } }

        func add(_ id: String) { edit { $0.insert(id) } }

        func remove(_ id: String) { edit { $0.remove(id) } }

        private func edit(_ change: (inout Set<String>) -> Void) {
            guard let fileURL else { return }
            Self.lock.withLockUnchecked {
                var ids = read()
                let before = ids
                change(&ids)
                guard ids != before else { return }
                if ids.isEmpty {
                    try? FileManager.default.removeItem(at: fileURL)
                } else if let data = try? JSONEncoder().encode(ids.sorted()) {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
        }

        private func read() -> Set<String> {
            guard let fileURL, let data = try? Data(contentsOf: fileURL),
                let ids = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(ids)
        }
    }

    static let pendingRemovals = PendingRemovals(
        fileURL: (try? StorePaths.appSupportBase())?.appendingPathComponent("pending-removals.json"))

    /// Finishes the removals a previous run left pending. An ID the library
    /// still lists was never removed (the app quit before the row went, or
    /// the row stayed), so it's dropped without touching the deployment.
    /// One whose delete fails again stays for the next launch.
    @MainActor
    static func finishPendingRemovals(
        libraryIDs: Set<String>,
        pending: PendingRemovals = pendingRemovals,
        remove: @MainActor (String) async throws -> Void = { try await removeDeployment(entryID: $0) }
    ) async {
        for id in pending.ids.sorted() {
            guard !libraryIDs.contains(id) else {
                pending.remove(id)
                continue
            }
            do {
                try await remove(id)
                pending.remove(id)
            } catch {
                nativeHostLog.error("removal: pending delete failed again: \(LogRedaction.code(of: error), privacy: .public)")
            }
        }
    }
}
