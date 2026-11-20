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
            // App-private, so only the folder itself must not be a symlink.
            if let staging = try? TrustedDirectory(url: stagingFolderURL) {
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
    /// on disk, so a quit or a failed delete is finished at the next launch.
    /// `AppModel.remove` records one before it removes the library row,
    /// marks it once the row is gone, and drops it once `removeDeployment`
    /// succeeds.
    struct PendingRemovals: Sendable {
        enum Stage: String, Codable, Sendable {
            /// The library row may or may not be gone.
            case requested
            /// The library row is gone.
            case rowRemoved
        }

        let fileURL: URL?

        private static let lock = OSAllocatedUnfairLock()

        var stages: [String: Stage] { Self.lock.withLockUnchecked { read() } }

        /// Records `id` as requested. Throws when the record can't be
        /// written, and then the removal must not go ahead.
        func add(_ id: String) throws { try edit { $0[id] = .requested } }

        func markRowRemoved(_ id: String) { try? edit { $0[id] = $0[id].map { _ in .rowRemoved } } }

        func remove(_ id: String) { try? edit { $0[id] = nil } }

        private func edit(_ change: (inout [String: Stage]) -> Void) throws {
            // No app support folder: nothing can be recorded.
            guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
            try Self.lock.withLockUnchecked {
                var stages = read()
                let before = stages
                change(&stages)
                guard stages != before else { return }
                if stages.isEmpty {
                    try? FileManager.default.removeItem(at: fileURL)
                } else {
                    try JSONEncoder().encode(stages).write(to: fileURL, options: .atomic)
                }
            }
        }

        private func read() -> [String: Stage] {
            guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
            return (try? JSONDecoder().decode([String: Stage].self, from: data)) ?? [:]
        }
    }

    static let pendingRemovals = PendingRemovals(
        fileURL: (try? StorePaths.appSupportBase())?.appendingPathComponent("pending-removals.json"))

    /// Finishes the removals a previous run left pending.
    ///
    /// - An ID in `removedThisRun` belongs to a removal running now, which
    ///   recorded it again; it's left alone.
    /// - An ID the library still lists was never removed, so it's dropped
    ///   without touching the deployment.
    /// - A `requested` ID waits until `libraryLoaded`: a library whose
    ///   index couldn't be read loads empty, and its row may still exist.
    /// - Anything else is deleted. One whose delete fails again stays.
    @MainActor
    static func finishPendingRemovals(
        libraryIDs: Set<String>,
        libraryLoaded: Bool,
        pending: PendingRemovals = pendingRemovals,
        removedThisRun: @MainActor () -> Set<String> = { removedEntries },
        remove: @MainActor (String) async throws -> Void = { try await removeDeployment(entryID: $0) }
    ) async {
        for (id, stage) in pending.stages.sorted(by: { $0.key < $1.key }) {
            // Checked after each delete's suspension, not once up front.
            guard !removedThisRun().contains(id) else { continue }
            if libraryIDs.contains(id) {
                pending.remove(id)
                continue
            }
            if stage == .requested && !libraryLoaded { continue }
            do {
                try await remove(id)
                pending.remove(id)
            } catch {
                nativeHostLog.error("removal: pending delete failed again: \(LogRedaction.code(of: error), privacy: .public)")
            }
        }
    }
}
