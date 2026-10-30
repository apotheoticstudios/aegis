import Foundation

struct BeholderPayload: Sendable {
    let data: Data
    let status: Int
    var rateLimited = false
}

protocol BeholderTransport: Sendable {
    func get(_ url: URL, accept: String) async throws -> BeholderPayload
}

/// Fresh ephemeral sessions; bounded public GETs only. No cookies, credentials, redirects, cache or page subresources.
struct BeholderWebTransport: BeholderTransport {
    static let byteLimit = 262_144
    /// Test-only protocol interception; production leaves this empty and never consults browser state.
    var protocolClasses: [AnyClass] = []

    static func configuration() -> URLSessionConfiguration { // privacy-guard: allow-network ephemeral Beholder requests, #98
        let config = URLSessionConfiguration.ephemeral // privacy-guard: allow-network owner-started Beholder lookup, #98 / ADR-0034
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return config
    }

    func get(_ url: URL, accept: String) async throws -> BeholderPayload {
        guard BeholderProvider.permits(url) else { throw URLError(.unsupportedURL) }
        let config = Self.configuration()
        if !protocolClasses.isEmpty {
            config.protocolClasses = protocolClasses
        }
        let session = URLSession(configuration: config) // privacy-guard: allow-network Beholder, #98
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url) // privacy-guard: allow-network owner-started Beholder lookup, #98 / ADR-0034
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Aegis-Beholder/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: BeholderNoRedirect())
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength <= Self.byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        guard http.statusCode == 200 else {
            return BeholderPayload(
                data: Data(),
                status: http.statusCode,
                rateLimited: http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            )
        }
        guard http.mimeType == "application/json" else { throw URLError(.cannotParseResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return BeholderPayload(data: data, status: http.statusCode)
    }
}

private final class BeholderNoRedirect: NSObject, URLSessionTaskDelegate { // privacy-guard: allow-network blocks Beholder redirects, #98
    func urlSession( // privacy-guard: allow-network blocks Beholder redirects, #98
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, // privacy-guard: allow-network #98
        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void // privacy-guard: allow-network #98
    ) {
        completionHandler(nil)
    }
}

protocol BeholderSearching: Sendable {
    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding
}

struct BeholderClient: BeholderSearching {
    var transport: any BeholderTransport = BeholderWebTransport()

    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        guard let endpoint = provider.endpoint(username) else { return BeholderFinding(provider: provider, status: .unsupported) }
        do {
            try Task.checkCancellation()
            let accept = provider == .dev ? "application/vnd.forem.api-v1+json" : "application/json"
            let payload = try await transport.get(endpoint, accept: accept)
            try Task.checkCancellation()
            return Self.parse(payload, provider: provider, username: username, now: Date())
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
            return BeholderFinding(
                provider: provider,
                status: cancelled ? .cancelled : .unavailable,
                checkedAt: Date(),
                sourceURL: endpoint
            )
        }
    }

    static func parse(_ payload: BeholderPayload, provider: BeholderProvider, username: String, now: Date) -> BeholderFinding {
        var result = BeholderFinding(provider: provider, status: .unavailable, checkedAt: now, sourceURL: provider.endpoint(username))
        if payload.status == 429 || payload.rateLimited {
            result.status = .limited; return result
        }
        if payload.status == 404 {
            result.status = .noResult; return result
        }
        guard payload.status == 200, payload.data.count <= BeholderWebTransport.byteLimit,
              let json = try? JSONSerialization.jsonObject(with: payload.data, options: .fragmentsAllowed) else { return result }
        if provider == .hackerNews, json is NSNull {
            result.status = .noResult; return result
        }
        let object: [String: Any]?
        if provider == .gitlab {
            guard let list = json as? [[String: Any]] else { return result }
            if list.isEmpty {
                result.status = .noResult; return result
            }
            guard list.count == 1 else { return result }
            object = list.first
        } else {
            object = json as? [String: Any]
        }
        let handleKey = provider == .github ? "login" : provider == .hackerNews ? "id" : "username"
        guard let object, let handle = object[handleKey] as? String,
              provider == .hackerNews ? handle == username : handle.lowercased() == username.lowercased() else { return result }
        result.status = .candidate
        result.fields["Handle"] = handle
        for (label, key) in [("Display name", "name"), ("Bio", "bio"), ("Bio", "summary"), ("About", "about")] {
            if let raw = object[key] as? String {
                let text = clean(raw)
                if !text.isEmpty {
                    result.fields[label] = text
                }
            }
        }
        return result
    }

    /// Render untrusted biographies only as bounded plain text, never HTML, Markdown, links or model instructions.
    static func clean(_ raw: String) -> String {
        let text = String(raw.prefix(4096)).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
                && $0.properties.generalCategory != .format
        }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(600)
            .description
    }
}
