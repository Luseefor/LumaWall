// Reads a connecting process's code signature and admits it only if it's one
// of Apple's wallpaper hosts (see CallerAdmission). The signature comes from
// the peer's audit token, never the PID alone, which can be reused. Every
// failure to read it rejects the connection.

import Foundation
import Security

enum CallerValidation {
    static func isAcceptable(_ connection: NSXPCConnection) -> Bool {
        switch CallerAdmission.verdict(for: peer(of: connection)) {
        case let .accepted(host):
            traceLog("  [Caller] Accepted \(host) (pid \(connection.processIdentifier))")
            return true
        case let .rejected(reason):
            extensionLog("  [Caller] REJECTED pid \(connection.processIdentifier): \(reason)")
            return false
        }
    }

    private static func peer(of connection: NSXPCConnection) -> CallerPeer {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else {
            return .unidentified("auditToken SPI unavailable")
        }

        var token = connection.auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard status == errSecSuccess, let code else {
            return .unidentified("could not derive peer SecCode (status \(status))")
        }
        return .signed { text in
            CallerAdmission.satisfies(requirement: text) { SecCodeCheckValidity(code, [], $0) }
        }
    }
}
