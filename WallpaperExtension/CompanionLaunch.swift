// Finds the companion app for the "Add Video" and "Manage Library" menu
// actions. The extension used to open `lumawall://` URLs, a scheme the app
// never registers, so any app could claim it. Now it opens the app that
// contains the extension, and only after checking that the app is signed
// with the extension's own identifier family and team.

import AppKit
import Security

enum CompanionLaunch {
    static func launchesCompanion(_ action: String) -> Bool {
        action == "add-video" || action == "manage-library"
    }

    /// `…/X.app` for an extension at `…/X.app/Contents/Extensions/Y.appex`.
    static func containingApp(of extensionURL: URL) -> URL? {
        let extensions = extensionURL.standardizedFileURL.deletingLastPathComponent()
        let contents = extensions.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard extensionURL.pathExtension == "appex", extensions.lastPathComponent == "Extensions",
            contents.lastPathComponent == "Contents", app.pathExtension == "app"
        else { return nil }
        return app
    }

    /// `app.lumawall.personal` for `app.lumawall.personal.wallpaper`.
    static func companionIdentifier(forExtension identifier: String) -> String? {
        let suffix = ".wallpaper"
        guard identifier.hasSuffix(suffix), identifier.count > suffix.count else { return nil }
        return String(identifier.dropLast(suffix.count))
    }

    /// The code requirement the companion must meet: its identifier, signed
    /// through Apple by `teamID`. Nil without a plausible team ID (an ad hoc
    /// build), so nothing is launched.
    static func requirement(identifier: String, teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty, teamID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
            !identifier.contains("\"")
        else { return nil }
        return #"identifier "\#(identifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    static func isSigned(_ app: URL, satisfying requirementText: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        // Every slice, so a Rosetta launch can't pick an unchecked one.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Opens exactly the verified bundle: no activating a copy that's
    /// already running from another path.
    static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    /// The team that signed this process, or nil for an ad hoc signature.
    static func ownTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The companion app to open, or nil with the reason to log.
    static func verifiedCompanion(extensionBundle: Bundle = .main) -> Result<URL, CompanionError> {
        guard let app = containingApp(of: extensionBundle.bundleURL) else { return .failure(.notInsideAnApp) }
        guard let identifier = extensionBundle.bundleIdentifier.flatMap(companionIdentifier(forExtension:)),
            let requirement = requirement(identifier: identifier, teamID: ownTeamID())
        else { return .failure(.noSigningIdentity) }
        guard isSigned(app, satisfying: requirement) else { return .failure(.signatureMismatch) }
        return .success(app)
    }

    enum CompanionError: Error, Equatable {
        case notInsideAnApp
        case noSigningIdentity
        case signatureMismatch
    }
}
