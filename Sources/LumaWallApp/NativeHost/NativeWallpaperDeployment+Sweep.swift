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
    /// that is not in `referenced`, hasn't changed for `sweepMinimumAge`
    /// and holds nothing but the bookkeeping an entry carries
    /// (`isBookkeepingOnly`). Anything else, a video in particular, keeps
    /// the folder: the extension lists a bare video, and its legacy
    /// migration moves the user's only copy into a new folder before it
    /// writes metadata. A folder holding only bookkeeping has no published
    /// entry, so the extension doesn't list it either.
    ///
    /// The folder is moved aside to `.sweep-<ID>` before the delete and
    /// checked again there. A writer that adds a file by path after the
    /// first check, such as that migration, then fails instead of adding it
    /// to a folder about to go; a folder that gained anything goes back. Then deletes the deploy staging
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
        // Folder names may be any case; the library's IDs are uppercase.
        let referenced = Set(referenced.compactMap(UUID.init(uuidString:)))
        if let videos = try? TrustedDirectory(url: videosFolderURL, below: trustedAncestor) {
            let items = (try? videos.entries()) ?? []
            // A sweep stopped between moving a folder aside and deciding.
            for item in items where item.kind == .directory && item.name.hasPrefix(asidePrefix) {
                let name = String(item.name.dropFirst(asidePrefix.count))
                guard let id = UUID(uuidString: name) else { continue }
                if entryLock.withLock({ finishSweep(of: name, in: videos, keep: referenced.contains(id)) }) {
                    result.entries.append(name)
                }
            }
            for item in items where item.kind == .directory {
                guard let id = UUID(uuidString: item.name), !referenced.contains(id) else { continue }
                let removed = entryLock.withLock { () -> Bool in
                    guard isOld(videosFolderURL.appendingPathComponent(item.name), now: now),
                        let folder = try? videos.subdirectory(item.name), isBookkeepingOnly(folder),
                        (try? videos.renameItem(named: item.name, to: asidePrefix + item.name)) != nil
                    else { return false }
                    return finishSweep(of: item.name, in: videos, keep: false)
                }
                if removed { result.entries.append(item.name) }
            }
        }
        if let stagingJournalURL {
            let journal = StagingJournal(fileURL: stagingJournalURL)
            let active = Set(activeStaging.map(\.standardizedFileURL.path))
            // Deleting runs outside the journal's lock, which deploys take on
            // the main actor.
            for (folder, identity) in journal.records where !active.contains(folder.standardizedFileURL.path) {
                switch removeStagingFolder(folder, identity: identity, now: now) {
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

    /// Where a folder waits while the sweep decides: hidden, and not a
    /// UUID, so the extension's scan skips it.
    private static let asidePrefix = ".sweep-"

    /// Deletes `.sweep-<name>` if it still holds only bookkeeping and
    /// `keep` is false; otherwise moves it back to `name`. True when
    /// deleted. A folder that can't go back (the name was taken meanwhile)
    /// stays aside for the next sweep.
    private static func finishSweep(of name: String, in videos: TrustedDirectory, keep: Bool) -> Bool {
        let aside = asidePrefix + name
        if !keep, let folder = try? videos.subdirectory(aside), isBookkeepingOnly(folder),
            (try? videos.removeItem(named: aside)) != nil
        {
            return true
        }
        try? videos.renameItem(named: aside, to: name)
        return false
    }

    /// True when `folder` lists cleanly and holds nothing but regular files
    /// named `metadata.json` or `thumbnail.jpg`, or nothing at all. A
    /// listing that fails, or an item whose type can't be read, counts as
    /// something to keep.
    private static func isBookkeepingOnly(_ folder: TrustedDirectory) -> Bool {
        guard let items = try? folder.entries() else { return false }
        return items.allSatisfy { $0.kind == .file && ["metadata.json", "thumbnail.jpg"].contains($0.name) }
    }

    private enum StagingOutcome { case removed, gone, kept }

    /// Deletes a staging folder `makeStagingFolder` made, when it is still
    /// the folder deploy recorded (`identity`), is old and holds nothing but
    /// staged entries. The folder above it (the system's TemporaryItems)
    /// can't be opened from the app, so the folder is emptied through its
    /// own descriptor and then removed with rmdir(2), which never follows a
    /// symlink and never removes a folder with anything in it.
    ///
    /// `.gone` means nothing of LumaWall's is left there: the folder is
    /// missing, a symlink, or another folder. Other errors keep the record
    /// for the next sweep.
    private static func removeStagingFolder(_ folder: URL, identity: TrustedDirectory.Identity?, now: Date) -> StagingOutcome {
        // Only what `makeStagingFolder` names: "NSIRD_<process>_<random>".
        guard folder.lastPathComponent.hasPrefix("NSIRD_"), let identity else { return .gone }
        let handle: TrustedDirectory
        do {
            handle = try TrustedDirectory(url: folder)
        } catch POSIXError.ENOENT, POSIXError.ELOOP, POSIXError.ENOTDIR {
            return .gone
        } catch {
            return .kept
        }
        guard let current = try? handle.identity() else { return .kept }
        guard current == identity else { return .gone }
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

    /// The deploy is done with `folder`. Its record stays in the journal
    /// unless the deploy deleted the folder, so the sweep can retry.
    static func endStaging(_ folder: URL, deleted: Bool, journalURL: URL? = stagingJournalURL) {
        _ = activeStaging.withLock { $0.remove(folder) }
        if deleted, let journalURL { StagingJournal(fileURL: journalURL).remove(folder) }
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
            }
        }
    }
}

/// A JSON list of staging folders in app support, each with the identity
/// it had when deploy made it, so a path that later names another folder
/// isn't swept. Every change is a read, edit and atomic write under one
/// lock, so deploys and the sweep in this process never lose each other's
/// edits.
struct StagingJournal {
    private struct Record: Codable, Equatable {
        var path: String
        var identity: TrustedDirectory.Identity?
    }

    let fileURL: URL

    private static let lock = OSAllocatedUnfairLock()

    /// Records `folder` as it is now. One that can't be opened is recorded
    /// without an identity, and the sweep only drops it.
    func add(_ folder: URL) {
        let identity = try? TrustedDirectory(url: folder).identity()
        edit { records in
            records.removeAll { $0.path == folder.path }
            records.append(Record(path: folder.path, identity: identity))
        }
    }

    func remove(_ folder: URL) {
        edit { records in records.removeAll { $0.path == folder.path } }
    }

    var records: [(folder: URL, identity: TrustedDirectory.Identity?)] {
        Self.lock.withLockUnchecked { read().map { (URL(fileURLWithPath: $0.path, isDirectory: true), $0.identity) } }
    }

    var folders: [URL] { records.map(\.folder) }

    private func edit(_ change: (inout [Record]) -> Void) {
        Self.lock.withLockUnchecked {
            var records = read()
            let before = records
            change(&records)
            guard records != before else { return }
            if records.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func read() -> [Record] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }
}
