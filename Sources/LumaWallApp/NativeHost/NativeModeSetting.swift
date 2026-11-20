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

    static var standard: NativeModeSetting {
        NativeModeSetting(defaults: .standard) { NativeWallpaperAssignmentService.hasBackup }
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

    func disable() {
        defaults.set(false, forKey: Self.enabledKey)
    }

    func acknowledgeDisclosure() {
        defaults.set(true, forKey: Self.disclosureKey)
    }
}
