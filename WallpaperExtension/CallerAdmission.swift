// Decides which processes may use the extension's XPC surface.
//
// The exported handler changes extension state, drives rendering and
// snapshots, and can delete library videos, so only Apple's wallpaper hosts
// get in. Each host is pinned by its designated requirement (signing
// identifier plus Apple's anchor), as `codesign -dr -` prints it. A peer whose
// signature can't be read, or that matches none of them, is turned away.
//
// Callers seen in extension.log, matched by PID against the unified log, are
// all WallpaperAgent, including the System Settings previews (the agent hosts
// those too). System Settings and its wallpaper pane stay allowed because
// they're the other Apple processes that host wallpaper choices.

import Foundation
import Security

/// What the extension could learn about a connecting process.
enum CallerPeer {
    /// The peer's code signature couldn't be read; the reason is logged.
    case unidentified(String)
    /// The peer's signature, as a test of whether it satisfies a
    /// requirement written in the code signing requirement language.
    case signed(satisfies: (String) -> Bool)
}

struct CallerHost {
    let name: String
    let requirement: String
}

enum CallerVerdict: Equatable {
    /// Accepted as the named host.
    case accepted(String)
    /// Rejected, with the reason to log.
    case rejected(String)
}

enum CallerAdmission {
    static let hosts = [
        CallerHost(name: "WallpaperAgent", requirement: "identifier \"com.apple.wallpaper.agent\" and anchor apple"),
        CallerHost(
            name: "Wallpaper settings", requirement: "identifier \"com.apple.Wallpaper-Settings.extension\" and anchor apple"),
        CallerHost(name: "System Settings", requirement: "identifier \"com.apple.systempreferences\" and anchor apple"),
    ]

    static func verdict(for peer: CallerPeer) -> CallerVerdict {
        switch peer {
        case let .unidentified(reason):
            return .rejected(reason)
        case let .signed(satisfies):
            if let host = hosts.first(where: { satisfies($0.requirement) }) {
                return .accepted(host.name)
            }
            return .rejected("signature matches no wallpaper host")
        }
    }

    /// Whether `check` passes for the requirement `text`. A requirement that
    /// doesn't compile matches nothing.
    static func satisfies(requirement text: String, check: (SecRequirement) -> OSStatus) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return check(requirement) == errSecSuccess
    }
}
