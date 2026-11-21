import Foundation

/// What a native assignment writes where in `Index.plist` (ADR 0004).
/// `changes` is pure: given the store, LumaWall's backup of it, the layout
/// and each display's wallpaper, it lists the surface edits. `apply` makes
/// them on a mutable copy inside the coordinated transaction.
enum NativeSurfacePlan {
    /// A deployed video, as the extension's choice names it.
    struct Video: Equatable, Sendable {
        let choiceID: String
        let url: URL
    }

    /// What one display shows: its video and, when there is one, the video's
    /// first-frame still (the library poster).
    struct Target: Equatable, Sendable {
        var video: Video
        var still: URL?
    }

    enum Write: Equatable {
        /// The extension's choice for `Video`.
        case video(Video)
        /// An Apple image choice showing this file.
        case image(URL)
        /// The surface saved in LumaWall's backup: the user's own picture.
        case saved(NSDictionary)
    }

    struct Change: Equatable {
        let path: [String]
        let write: Write
    }

    struct Outcome: Equatable {
        var changes: [Change] = []
        /// Displays that got the video on the surface the layout plays it on
        /// (Desktop, or Idle for lock-screen-only).
        var assigned: Set<String> = []
        /// Lock-screen-only displays whose desktop still shows a LumaWall
        /// video: no saved picture and no still to put there instead.
        var desktopsLeftPlaying: Set<String> = []
    }

    static let imageProvider = "com.apple.wallpaper.choice.image"

    /// - Parameters:
    ///   - targets: keyed by stable display UUID.
    ///   - idleOverride: the Lock Screen pick, which goes on every lock
    ///     screen in place of each display's own video.
    static func changes(
        root: NSDictionary,
        backup: NSDictionary?,
        layout: NativeSurfaceLayout,
        targets: [String: Target],
        idleOverride: Video? = nil,
        ownedFolders: [URL]
    ) -> Outcome {
        var outcome = Outcome()
        let places = displayPlaces(in: root)
        for uuid in targets.keys.sorted() {
            guard let target = targets[uuid] else { continue }
            for place in places {
                let desktopPath = place + [uuid, "Desktop"]
                let idlePath = place + [uuid, "Idle"]
                let desktop = surface(at: desktopPath, in: root)
                switch layout.preset {
                case .everywhere:
                    guard desktop != nil else { continue }
                    outcome.changes.append(Change(path: desktopPath, write: .video(target.video)))
                    outcome.assigned.insert(uuid)
                case .lockScreenOnly:
                    if surface(at: idlePath, in: root) != nil {
                        outcome.changes.append(Change(path: idlePath, write: .video(idleOverride ?? target.video)))
                        outcome.assigned.insert(uuid)
                    }
                    guard let desktop else { continue }
                    if let write = desktopWrite(
                        desktop, saved: backup.flatMap { surface(at: desktopPath, in: $0) },
                        target: target, layout: layout, ownedFolders: ownedFolders)
                    {
                        outcome.changes.append(Change(path: desktopPath, write: write))
                    } else if NativeWallpaperAssignmentStore.isOurs(desktop, ownedFolders: ownedFolders),
                        !isImage(desktop)
                    {
                        outcome.desktopsLeftPlaying.insert(uuid)
                    }
                }
            }
        }
        return outcome
    }

    /// The desktop under lock-screen-only: the still when asked for; else
    /// the user's saved picture in place of LumaWall's; else the still, so
    /// the desktop never keeps playing. Nil leaves it as it is.
    private static func desktopWrite(
        _ desktop: NSDictionary, saved: NSDictionary?, target: Target, layout: NativeSurfaceLayout, ownedFolders: [URL]
    ) -> Write? {
        if layout.settlesOnStill, let still = target.still {
            return showsImage(desktop, still) ? nil : .image(still)
        }
        guard NativeWallpaperAssignmentStore.isOurs(desktop, ownedFolders: ownedFolders) else { return nil }
        if let saved, !NativeWallpaperAssignmentStore.isOurs(saved, ownedFolders: ownedFolders) {
            return .saved(saved)
        }
        if let still = target.still, !showsImage(desktop, still) { return .image(still) }
        return nil
    }

    /// Makes `changes` on `root`. `now` stamps the surfaces it sets.
    static func apply(_ changes: [Change], to root: NSMutableDictionary, now: Date = Date()) {
        for change in changes {
            switch change.write {
            case .video(let video):
                let surface = NativeWallpaperAssignmentStore.value(at: change.path, in: root) as? NSMutableDictionary
                NativeWallpaperAssignmentStore.updateSurface(surface, choiceID: video.choiceID, videoURL: video.url, now: now)
            case .image(let url):
                guard let surface = NativeWallpaperAssignmentStore.value(at: change.path, in: root) as? NSMutableDictionary,
                    let content = surface["Content"] as? NSMutableDictionary
                else { continue }
                content["Choices"] = [imageChoice(url)]
                content["Shuffle"] = "$null"
                content["EncodedOptionValues"] = cropPlacement
                surface["LastSet"] = now
                surface["LastUse"] = now
            case .saved(let saved):
                NativeWallpaperAssignmentStore.set(
                    NativeWallpaperAssignmentStore.deepMutableCopy(saved), at: change.path, in: root)
            }
        }
    }

    /// The choice `NSWorkspace.setDesktopImageURL` writes: no `Files`, and
    /// the file in a binary-plist `Configuration`.
    static func imageChoice(_ url: URL) -> NSDictionary {
        let configuration: [String: Any] = ["type": "imageFile", "url": ["relative": url.absoluteString]]
        let data = (try? PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)) ?? Data()
        return ["Provider": imageProvider, "Configuration": data, "Files": [] as [Any]]
    }

    /// The file an Apple image choice shows, from its `Configuration` or,
    /// in older stores, its `Files`.
    static func imageURL(of choice: NSDictionary) -> URL? {
        if let data = choice["Configuration"] as? Data,
            let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
            let relative = (configuration["url"] as? NSDictionary)?["relative"] as? String
        {
            return URL(string: relative)
        }
        let files = choice["Files"] as? [NSDictionary] ?? []
        return files.lazy.compactMap { ($0["relative"] as? String).flatMap(URL.init(string:)) }.first
    }

    /// Fills the display and crops the overflow, as the overlay's posters do,
    /// so a landscape still covers a portrait display like the video does.
    private static let cropPlacement: Data = {
        let values: [String: Any] = ["values": ["placement": ["picker": ["_0": ["id": "Crop"]]]]]
        return (try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)) ?? Data()
    }()

    /// `["Displays"]` and each Space's `["Spaces", id, "Displays"]`.
    private static func displayPlaces(in root: NSDictionary) -> [[String]] {
        var places: [[String]] = []
        if root["Displays"] is NSDictionary { places.append(["Displays"]) }
        let spaces = root["Spaces"] as? NSDictionary ?? [:]
        for case let key as String in spaces.allKeys.sorted(by: { "\($0)" < "\($1)" })
        where (spaces[key] as? NSDictionary)?["Displays"] is NSDictionary {
            places.append(["Spaces", key, "Displays"])
        }
        return places
    }

    /// A surface the writer can edit: a dictionary with a `Content` dictionary.
    private static func surface(at path: [String], in root: NSDictionary) -> NSDictionary? {
        guard let surface = NativeWallpaperAssignmentStore.value(at: path, in: root) as? NSDictionary,
            surface["Content"] is NSDictionary
        else { return nil }
        return surface
    }

    private static func choices(of surface: NSDictionary) -> [NSDictionary] {
        (surface["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary] ?? []
    }

    private static func isImage(_ surface: NSDictionary) -> Bool {
        choices(of: surface).contains { $0["Provider"] as? String == imageProvider }
    }

    private static func showsImage(_ surface: NSDictionary, _ url: URL) -> Bool {
        let shown = choices(of: surface)
        return shown.count == 1 && shown[0]["Provider"] as? String == imageProvider
            && imageURL(of: shown[0])?.standardizedFileURL == url.standardizedFileURL
    }
}
