import Foundation

/// Whether the user opted in to native wallpaper mode. Native mode edits the
/// macOS wallpaper store through undocumented interfaces, so it is off unless
/// the user turned it on after reading the warning. Off means overlay
/// playback only.
struct NativeModeSetting {
    static let enabledKey = "lumawall.nativeMode"
    static let disclosureKey = "lumawall.nativeModeDisclosureSeen"

    private let defaults: UserDefaults
    private let usedNativeBefore: () -> Bool

    /// - Parameter usedNativeBefore: true when this Mac already ran native
    ///   mode before the setting existed. Asked once, on the first launch
    ///   with this setting.
    init(defaults: UserDefaults, usedNativeBefore: @escaping () -> Bool) {
        self.defaults = defaults
        self.usedNativeBefore = usedNativeBefore
    }

    /// The stored choice, readable from any thread. Code that writes into
    /// the extension's container checks it right before writing, so work
    /// queued while native mode was on stops once it is off.
    static var isEnabledNow: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var standard: NativeModeSetting {
        NativeModeSetting(defaults: .standard) {
            showsNativeUse(
                backupExists: NativeWallpaperAssignmentService.hasBackup,
                store: try? Data(contentsOf: LiveSystemWallpaperFiles.storeURL)
            )
        }
    }

    /// True when the app wrote the wallpaper store before (it backs it up
    /// first) and a display still shows the LumaWall extension. A backup
    /// alone isn't enough: the old app saved it even when the write failed.
    static func showsNativeUse(backupExists: Bool, store: Data?) -> Bool {
        guard backupExists, let store,
            let root = try? PropertyListSerialization.propertyList(from: store, format: nil) as? NSDictionary
        else { return false }
        return NativeWallpaperAssignmentStore.surfacePaths(in: root).contains { path in
            var node: Any? = root
            for key in path { node = (node as? NSDictionary)?[key] }
            return (node as? NSDictionary).map { NativeWallpaperAssignmentStore.isOurs($0) } ?? false
        }
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// True for someone moved onto the setting with native mode already on
    /// who hasn't seen the warning yet.
    var needsDisclosure: Bool { isEnabled && !defaults.bool(forKey: Self.disclosureKey) }

    /// Records the starting value the first time this runs. New installs
    /// start off; a Mac that already used native mode keeps it.
    func migrateIfNeeded() {
        guard defaults.object(forKey: Self.enabledKey) == nil else { return }
        defaults.set(usedNativeBefore(), forKey: Self.enabledKey)
    }

    /// Turns native mode on. Call only after the user confirmed the warning.
    func enable() {
        defaults.set(true, forKey: Self.enabledKey)
        defaults.set(true, forKey: Self.disclosureKey)
    }

    /// Turns native mode off immediately. A write already underway can finish.
    func disable() {
        defaults.set(false, forKey: Self.enabledKey)
    }

    func acknowledgeDisclosure() {
        defaults.set(true, forKey: Self.disclosureKey)
    }
}
