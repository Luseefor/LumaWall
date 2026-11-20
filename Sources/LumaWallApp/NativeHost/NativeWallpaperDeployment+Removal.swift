import Foundation
import LumaWallCore

/// Takes a removed wallpaper out of the extension's library.
///
/// Removing a wallpaper used to delete only the library copy. Its deployed
/// video, thumbnail and copies stayed in the container, so System Settings
/// kept offering it, and its queued copy encodes kept running.
extension NativeWallpaperDeployment {
    /// Waits for a deploy of the entry still running, stops its copy
    /// encodes, deletes its deployed folder and staged exports, and tells
    /// the extension to rescan so the picker drops it.
    @MainActor
    static func removeDeployment(entryID: String) async {
        guard PathSafety.isValidEntryID(entryID) else { return }
        // A deploy still running would publish the entry after the delete.
        await waitForDeployment(of: entryID)
        await forgetCopies(for: entryID)
        await Task.detached(priority: .utility) {
            deleteDeployedFiles(entryID: entryID)
        }.value
        notifyLibraryChanged()
    }

    /// Deletes `videos/<entryID>` and the entry's exports in copy staging,
    /// without following symlinks. Under `entryLock`, so a copy published
    /// at the same time either lands first and is deleted with the entry,
    /// or finds the entry gone and is discarded.
    static func deleteDeployedFiles(
        entryID: String,
        videosFolderURL: URL = videosFolderURL,
        stagingFolderURL: URL = stagingFolderURL,
        trustedAncestor: URL = containerURL
    ) {
        guard PathSafety.isValidEntryID(entryID) else { return }
        entryLock.withLock {
            try? TrustedDirectory(url: videosFolderURL, below: trustedAncestor).removeItem(named: entryID)
            guard let staging = try? TrustedDirectory(url: stagingFolderURL, below: trustedAncestor) else { return }
            for file in (try? staging.entries()) ?? [] where file.kind == .file && file.name.hasPrefix(entryID + ".") {
                try? staging.removeFile(named: file.name)
            }
        }
    }
}
