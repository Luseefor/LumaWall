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
    /// The peer's signature, as a check of a requirement written in the
    /// code signing requirement language: `errSecSuccess` when it's met.
    case signed(check: (String) -> OSStatus)
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
        case let .signed(check):
            var failures: [OSStatus] = []
            for host in hosts {
                let status = check(host.requirement)
                if status == errSecSuccess { return .accepted(host.name) }
                if !failures.contains(status) { failures.append(status) }
            }
            // errSecCSReqFailed is an ordinary mismatch; anything else means
            // the signature itself couldn't be checked.
            let statuses = failures.map(String.init).joined(separator: ", ")
            return .rejected("signature matches no wallpaper host (status \(statuses))")
        }
    }

    /// The peer behind a guest lookup (`SecCodeCopyGuestWithAttributes`),
    /// checked with `SecCodeCheckValidity`. A failed lookup leaves it
    /// unidentified.
    static func peer(guestLookup: () -> (OSStatus, SecCode?)) -> CallerPeer {
        let (lookup, code) = guestLookup()
        guard lookup == errSecSuccess, let code else {
            return .unidentified("could not derive peer SecCode (status \(lookup))")
        }
        return .signed { text in
            status(ofRequirement: text) { SecCodeCheckValidity(code, [], $0) }
        }
    }

    /// The result of `check` for the requirement `text`, or the compile
    /// error when `text` isn't a valid requirement.
    static func status(ofRequirement text: String, check: (SecRequirement) -> OSStatus) -> OSStatus {
        var requirement: SecRequirement?
        let compiled = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard compiled == errSecSuccess, let requirement else {
            return compiled == errSecSuccess ? errSecCSReqInvalid : compiled
        }
        return check(requirement)
    }
}
