import Foundation

/// Named servers only: a handle never supplies a destination or triggers federation resolution.
extension BeholderProvider {
    var mastodonHost: String? {
        switch self {
        case .mastodon: "mastodon.social"
        case .mastodonOnline: "mastodon.online"
        case .mstdnSocial: "mstdn.social"
        case .fosstodon: "fosstodon.org"
        case .hachyderm: "hachyderm.io"
        case .infosecExchange: "infosec.exchange"
        case .masTo: "mas.to"
        case .socialVivaldi: "social.vivaldi.net"
        default: nil
        }
    }

    var socialAPIHost: String? {
        if let mastodonHost {
            return mastodonHost
        }
        return switch self {
        case .writeAs: "write.as"
        case .framaTube: "framatube.org"
        case .mixcloud: "api.mixcloud.com"
        default: nil
        }
    }

    var socialAPITitle: String? {
        if let mastodonHost {
            return "Mastodon (\(mastodonHost))"
        }
        return switch self {
        case .writeAs: "Write.as"
        case .framaTube: "PeerTube (Framatube)"
        case .mixcloud: "Mixcloud"
        default: nil
        }
    }

    var socialAPIPattern: String? {
        if mastodonHost != nil {
            return #"[A-Za-z0-9_]{1,30}"#
        }
        switch self {
        case .writeAs: return #"[A-Za-z0-9][A-Za-z0-9-]{0,63}"#
        case .framaTube: return #"[A-Za-z0-9_][A-Za-z0-9_.]{0,49}"#
        case .mixcloud: return #"[A-Za-z0-9_-]{1,50}"#
        default: return nil
        }
    }
}

/// Public profile metadata only. Returned links, scripts, posts and discovered identifiers are discarded.
enum BeholderSocialAPIs {
    static func parse(_ json: Any, provider: BeholderProvider, username: String, now: Date) -> BeholderFinding {
        var result = BeholderFinding(provider: provider, status: .unavailable, checkedAt: now, sourceURL: provider.endpoint(username))
        guard let object = json as? [String: Any] else { return result }
        let profile: [String: Any]
        let nameKey: String
        let titleKey: String
        switch provider {
        case .writeAs:
            guard object["code"] as? Int == 200, let data = object["data"] as? [String: Any] else { return result }
            profile = data; nameKey = "alias"; titleKey = "title"
        case .framaTube:
            var expectedActor = URLComponents()
            expectedActor.scheme = "https"
            expectedActor.host = provider.host
            expectedActor.path = "/accounts/" + provider.lookupHandle(username)
            guard let host = object["host"] as? String, host.lowercased() == provider.host,
                  let actor = object["url"] as? String,
                  actor == expectedActor.url?.absoluteString else { return result }
            profile = object; nameKey = "name"; titleKey = "displayName"
        case .mixcloud:
            guard let key = object["key"] as? String, key.lowercased() == "/" + provider.lookupHandle(username) + "/" else { return result }
            if let returned = object["username"] {
                guard let handle = returned as? String, handle.lowercased() == provider.lookupHandle(username) else { return result }
            }
            profile = object.merging(["username": String(key.dropFirst().dropLast())]) { _, new in new }
            nameKey = "username"; titleKey = "name"
        default: return result
        }
        guard let handle = profile[nameKey] as? String, handle.lowercased() == provider.lookupHandle(username) else { return result }
        result.status = .candidate
        result.fields["Handle"] = handle
        for (label, key) in [("Display name", titleKey), ("Bio", provider == .mixcloud ? "biog" : "description")] {
            if let raw = profile[key] as? String {
                let text = BeholderClient.clean(raw)
                if !text.isEmpty {
                    result.fields[label] = text
                }
            }
        }
        if provider == .writeAs {
            result.fields["Profile type"] = "Blog"
        }
        return result
    }
}
