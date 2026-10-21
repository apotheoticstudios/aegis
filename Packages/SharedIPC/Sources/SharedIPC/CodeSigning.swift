import Foundation
import Security

/// Code-signing checks for XPC (ADR-0013). Both ends require the other to be signed by Apple's anchor,
/// Aegis's own team and the expected identifier, so an ad hoc impostor that copies an identifier is refused.
public enum CodeSigning {
    /// The team ID in this process's own signature; nil for ad hoc, linker-signed or unsigned code.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let fields = info as? [String: Any]
        else {
            return nil
        }
        return fields[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The requirement a peer must meet: Apple's anchor, `team` and one of `identifiers`. Nil without a team:
    /// only unsigned test builds lack one, and those are never registered with launchd (`BackgroundParts`).
    public static func requirement(identifiers: [String], team: String? = ownTeamID()) -> String? {
        guard let team, !identifiers.isEmpty else {
            return nil
        }
        let names = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(names))"
    }
}
