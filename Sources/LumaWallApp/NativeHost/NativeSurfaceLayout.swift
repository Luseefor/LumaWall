import Foundation

/// Where native mode plays the video (ADR 0004). Read by the store writer
/// on every assignment, so it lives in `UserDefaults` rather than the model.
struct NativeSurfaceLayout: Equatable, Sendable {
    enum Preset: String, CaseIterable, Sendable {
        /// The video plays on the desktop. Lock screens keep what they had,
        /// unless the Lock Screen pick sets them.
        case everywhere
        /// The video plays on the lock screen; the desktop shows the user's
        /// own picture, or a still of the video with `settlesOnStill`.
        case lockScreenOnly
    }

    static let presetKey = "lumawall.nativeSurfacePreset"
    static let settlesOnStillKey = "lumawall.nativeSettlesOnStill"

    var preset: Preset
    /// Only used with `lockScreenOnly`.
    var settlesOnStill: Bool

    init(preset: Preset = .everywhere, settlesOnStill: Bool = false) {
        self.preset = preset
        self.settlesOnStill = settlesOnStill
    }

    init(defaults: UserDefaults) {
        self.init(
            preset: defaults.string(forKey: Self.presetKey).flatMap(Preset.init(rawValue:)) ?? .everywhere,
            settlesOnStill: defaults.bool(forKey: Self.settlesOnStillKey)
        )
    }

    static var current: NativeSurfaceLayout { NativeSurfaceLayout(defaults: .standard) }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        defaults.set(settlesOnStill, forKey: Self.settlesOnStillKey)
    }

    /// False when the extension draws no desktop, so the health check
    /// (ADR 0003) has nothing to watch while the screen is unlocked.
    var playsOnDesktop: Bool { preset == .everywhere }

    /// Changes whenever a store write would come out different, for the
    /// engine's skip-identical-rewrite check.
    var tag: String { "\(preset.rawValue)/\(preset == .lockScreenOnly && settlesOnStill ? "still" : "own")" }
}
