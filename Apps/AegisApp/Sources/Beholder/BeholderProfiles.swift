import Foundation

/// Positive, provider-specific identity evidence. HTTP success or a matching display name alone never suffices.
enum BeholderProfiles {
    static func expanded(_ json: Any, provider: BeholderProvider, username: String, now: Date) -> BeholderFinding {
        var result = BeholderFinding(provider: provider, status: .unavailable, checkedAt: now, sourceURL: provider.endpoint(username))
        guard var object = json as? [String: Any] else { return result }
        if provider == .keybase {
            guard let status = object["status"] as? [String: Any], status["code"] as? Int == 0,
                  let people = object["them"] as? [Any] else { return result }
            if people.isEmpty || (people.count == 1 && people[0] is NSNull) {
                result.status = .noResult; return result
            }
            guard people.count == 1, let person = people[0] as? [String: Any],
                  let basics = person["basics"] as? [String: Any] else { return result }
            object = basics.merging(person["profile"] as? [String: Any] ?? [:]) { original, _ in original }
        }
        let key = switch provider {
        case .codeberg: "login"
        case .bluesky: "handle"
        default: "username"
        }
        guard let handle = object[key] as? String, handle.lowercased() == provider.lookupHandle(username) else { return result }
        if provider.mastodonHost != nil {
            guard let acct = object["acct"] as? String, acct.lowercased() == provider.lookupHandle(username) else { return result }
        }
        result.status = .candidate
        result.fields["Handle"] = handle
        var fields = object
        if provider == .scratch {
            fields = object["profile"] as? [String: Any] ?? [:]
        }
        for (label, key) in [
            ("Display name", "full_name"), ("Display name", "name"), ("Display name", "displayName"),
            ("Display name", "display_name"), ("Bio", "bio"), ("Bio", "description"), ("Bio", "note"), ("Account state", "status"),
        ] {
            if let raw = fields[key] as? String {
                let value = BeholderClient.clean(raw)
                if !value.isEmpty {
                    result.fields[provider == .scratch && key == "status" ? "Working on" : label] = value
                }
            }
        }
        return result
    }
}
