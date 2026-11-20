import Foundation
import LumaWallCore
import os

/// Deletes entry folders nothing uses and deploy staging a crash left.
///
/// Library scans don't delete anything since #81, so an entry folder an
/// older version or an interrupted deploy left without a usable video stays
/// on disk, unlisted. The app publishes entries, so the app sweeps them: at
/// launch and after each deploy.
///
/// Like removal, the sweep runs with native mode off. It only deletes
/// LumaWall's own files; it never writes Apple's `Index.plist` or restarts
/// WallpaperAgent.
extension NativeWallpaperDeployment {
    struct SweepResult: Equatable, Sendable {
        /// Entry folders deleted from `videos/`.
        var entries: [String] = []
        /// Deploy staging folders deleted.
        var stagingFolders: [String] = []
    }

    /// How long a folder must go unchanged before the sweep counts it as
    /// left behind. A writer building one in place (the extension's legacy
    /// migration, a deploy staging a large file) keeps it fresher than this.
    static let sweepMinimumAge: TimeInterval = 3600

    /// Deletes, from `videosFolderURL`, each entry folder (named by a UUID)
    /// that is not in `referenced`, holds no valid published entry
    /// (metadata.json for its own ID naming a regular file beside it) and
    /// hasn't changed for `sweepMinimumAge`. Then deletes the deploy staging
    /// folders listed in the journal at `stagingJournalURL` that aren't in
    /// `activeStaging`, haven't changed for that long and hold only staged
    /// entries.
    ///
    /// Everything goes through `TrustedDirectory`, so a symlink is never
    /// followed: a symlinked entry or staging folder is skipped, and a
    /// symlink inside a deleted folder is unlinked, not entered. Each entry
    /// is checked and deleted under `entryLock`, so it can't race a publish.
    static func sweepAbandonedEntries(
        referenced: Set<String>,
        videosFolderURL: URL = videosFolderURL,
        trustedAncestor: URL = containerURL,
        stagingJournalURL: URL? = stagingJournalURL,
        activeStaging: Set<URL> = activeStagingFolders,
        now: Date = Date()
    ) -> SweepResult {
        var result = SweepResult()
        if let videos = try? TrustedDirectory(url: videosFolderURL, below: trustedAncestor) {
            for item in (try? videos.entries()) ?? []
            where item.kind == .directory && PathSafety.isValidEntryID(item.name) && !referenced.contains(item.name) {
                let removed = entryLock.withLock { () -> Bool in
                    guard isOld(videosFolderURL.appendingPathComponent(item.name), now: now),
                        let folder = try? videos.subdirectory(item.name),
                        !hasPublishedEntry(id: item.name, in: folder)
                    else { return false }
                    return (try? videos.removeItem(named: item.name)) != nil
                }
                if removed { result.entries.append(item.name) }
            }
        }
        if let stagingJournalURL {
            let journal = StagingJournal(fileURL: stagingJournalURL)
            let active = Set(activeStaging.map(\.standardizedFileURL.path))
            // Deleting runs outside the journal's lock, which deploys take on
            // the main actor.
            for folder in journal.folders where !active.contains(folder.standardizedFileURL.path) {
                switch removeStagingFolder(folder, now: now) {
                case .removed:
                    result.stagingFolders.append(folder.lastPathComponent)
                    journal.remove(folder)
                case .gone: journal.remove(folder)
                case .kept: break
                }
            }
        }
        return result
    }

    /// True when the entry in `folder` is one the extension lists from its
    /// metadata: metadata.json reads, names this ID and a safe filename,
    /// and that file is a regular file directly in the folder.
    private static func hasPublishedEntry(id: String, in folder: TrustedDirectory) -> Bool {
        guard let entry = entry(id: id, inEntry: folder) else { return false }
        return (try? folder.kind(ofItemNamed: entry.filename)) == .file
    }

    private enum StagingOutcome { case removed, gone, kept }

    /// Deletes a staging folder `makeStagingFolder` made, when it is old
    /// and holds nothing but staged entries. The folder above it (the
    /// system's TemporaryItems) can't be opened from the app, so the folder
    /// is emptied through its own descriptor and then removed with rmdir(2),
    /// which never follows a symlink. A missing folder, or a symlink in its
    /// place, is `.gone`: there is nothing of LumaWall's left to sweep.
    private static func removeStagingFolder(_ folder: URL, now: Date) -> StagingOutcome {
        // Only what `makeStagingFolder` names: "NSIRD_<process>_<random>".
        guard folder.lastPathComponent.hasPrefix("NSIRD_"),
            (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory,
            let handle = try? TrustedDirectory(url: folder)
        else { return .gone }
        guard let staged = try? handle.entries(),
            staged.allSatisfy({ $0.kind == .directory && isStagedEntryName($0.name) }),
            isOld(folder, now: now), staged.allSatisfy({ isOld(folder.appendingPathComponent($0.name), now: now) })
        else { return .kept }
        for item in staged { try? handle.removeItem(named: item.name) }
        return rmdir(folder.path) == 0 ? .removed : .kept
    }

    /// "<entryID>.<UUID>", the name `stageDeployment` gives a staged entry.
    private static func isStagedEntryName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { PathSafety.isValidEntryID(String($0)) }
    }

    /// Whether the item at `url` (not a symlink's target) was last changed
    /// at least `sweepMinimumAge` before `now`. Unknown counts as not old.
    private static func isOld(_ url: URL, now: Date) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) >= sweepMinimumAge
    }

    // MARK: Staging folders in use

    private static let activeStaging = OSAllocatedUnfairLock(initialState: Set<URL>())

    /// Staging folders of deploys running in this process.
    static var activeStagingFolders: Set<URL> { activeStaging.withLock { $0 } }

    /// Lists the deploy staging folders a crash could leave. They sit in
    /// the system's TemporaryItems, which the app can't list, so the sweep
    /// finds them here.
    static var stagingJournalURL: URL? {
        (try? StorePaths.appSupportBase())?.appendingPathComponent("deploy-staging.json")
    }

    /// Records a staging folder a deploy is about to fill.
    static func beginStaging(_ folder: URL, journalURL: URL? = stagingJournalURL) {
        _ = activeStaging.withLock { $0.insert(folder) }
        if let journalURL { StagingJournal(fileURL: journalURL).add(folder) }
    }

    /// The deploy is done with `folder` and has deleted it.
    static func endStaging(_ folder: URL, journalURL: URL? = stagingJournalURL) {
        _ = activeStaging.withLock { $0.remove(folder) }
        if let journalURL { StagingJournal(fileURL: journalURL).remove(folder) }
    }

    // MARK: Scheduling

    /// The entry IDs the app's library and display assignments use, or nil
    /// when they can't be trusted to be complete (an empty library, which
    /// is also what a lost or quarantined index looks like). Set by the app
    /// at launch; without it no sweep runs.
    @MainActor
    static var referencedEntryIDs: (@MainActor () async -> Set<String>?)?

    @MainActor private static var sweepRunning = false
    @MainActor private static var sweepRequested = false

    /// Runs a sweep, or one more after the one running now.
    @MainActor
    static func scheduleSweep() {
        guard let referencedEntryIDs else { return }
        sweepRequested = true
        guard !sweepRunning else { return }
        sweepRunning = true
        Task { @MainActor in
            defer { sweepRunning = false }
            while sweepRequested {
                sweepRequested = false
                guard let library = await referencedEntryIDs() else { continue }
                let referenced = library.union(deployingEntryIDs)
                let result = await Task.detached(priority: .utility) {
                    sweepAbandonedEntries(referenced: referenced)
                }.value
                if !result.entries.isEmpty || !result.stagingFolders.isEmpty {
                    nativeHostLog.info(
                        "sweep: removed \(result.entries.count, privacy: .public) entries, \(result.stagingFolders.count, privacy: .public) staging folders"
                    )
                }
                // The extension may list an entry recovered from a bare video.
                if !result.entries.isEmpty { notifyLibraryChanged() }
            }
        }
    }
}

/// A JSON list of staging folder paths in app support. Every change is a
/// read, edit and atomic write under one lock, so deploys and the sweep in
/// this process never lose each other's edits.
struct StagingJournal {
    let fileURL: URL

    private static let lock = OSAllocatedUnfairLock()

    func add(_ folder: URL) {
        edit { paths in if !paths.contains(folder.path) { paths.append(folder.path) } }
    }

    func remove(_ folder: URL) {
        edit { paths in paths.removeAll { $0 == folder.path } }
    }

    var folders: [URL] {
        Self.lock.withLockUnchecked { read().map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    private func edit(_ change: (inout [String]) -> Void) {
        Self.lock.withLockUnchecked {
            var paths = read()
            let before = paths
            change(&paths)
            guard paths != before else { return }
            if paths.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else if let data = try? JSONEncoder().encode(paths) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func read() -> [String] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
}
