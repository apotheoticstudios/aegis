import AegisKit
import Foundation

/// Anonymous, read-only public search (#37). Only a Core-approved phrase leaves the Mac.
struct PublicLookupClient: Sendable {
    enum Problem: Error { case unavailable, tooLarge, noResults, expired }
    static func shouldSearch(_ question: String) -> Bool {
        question.range(
            of: #"\b(?:search|look up|google|browse|latest|current|currently|news|weather|forecast|prices?|scores?|right now)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static let maximumBytes = 2 * 1024 * 1024
    private let session: URLSession // privacy-guard: allow-network #37

    init(session: URLSession? = nil) { // privacy-guard: allow-network #37
        if let session {
            self.session = session; return
        }
        let configuration = URLSessionConfiguration.ephemeral // privacy-guard: allow-network #37
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self
            .session = URLSession( // privacy-guard: allow-network #37
                configuration: configuration,
                delegate: PublicLookupNetworkPolicy(),
                delegateQueue: nil
            )
    }

    func search(_ plan: PublicLookupPlan) async throws -> [PublicSource] {
        defer { session.finishTasksAndInvalidate() }
        let request = try Self.request(plan)
        let (bytes, response) = try await session
            .bytes(for: request) // privacy-guard: allow-network #37
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              ["text/xml", "application/xml", "application/rss+xml"].contains(http.mimeType ?? "")
        else {
            throw Problem.unavailable
        }
        guard response.expectedContentLength <= Self.maximumBytes else { throw Problem.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw Problem.tooLarge }
            data.append(byte)
        }
        let sources = try Self.parse(data)
        guard !sources.isEmpty else { throw Problem.noResults }
        return sources
    }

    static func request(_ plan: PublicLookupPlan) throws -> URLRequest { // privacy-guard: allow-network #37
        guard Date() < plan.expiresAt, (4 ... 300).contains(plan.query.unicodeScalars.count) else { throw Problem.expired }
        var components = URLComponents(string: "https://www.bing.com/search")! // privacy-guard: allow-network #37
        components.queryItems = [.init(name: "format", value: "rss"), .init(name: "q", value: plan.query)]
        var request = URLRequest( // privacy-guard: allow-network #37
            url: components.url!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("application/rss+xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("AegisPublicLookup/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parse(_ data: Data) throws -> [PublicSource] {
        guard data.count <= maximumBytes else { throw Problem.tooLarge }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw Problem.unavailable }
        let reader = PublicSearchRSS()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.isRSS else { throw Problem.unavailable }
        return reader.sources
    }
}

/// Search replies cannot redirect to another host, challenge for credentials, or link any account.
final class PublicLookupNetworkPolicy: NSObject,
    URLSessionTaskDelegate, // privacy-guard: allow-network #37
    @unchecked Sendable
{
    func urlSession(
        _: URLSession, // privacy-guard: allow-network #37
        task _: URLSessionTask, // privacy-guard: allow-network #37
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void // privacy-guard: allow-network #37
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, // privacy-guard: allow-network #37
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) // privacy-guard: allow-network #37
            -> Void
    ) {
        completionHandler(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .rejectProtectionSpace,
            nil
        )
    }
}

private final class PublicSearchRSS: NSObject, XMLParserDelegate {
    var sources: [PublicSource] = []
    var isRSS = false
    private var inItem = false
    private var field = ""
    private var title = ""
    private var excerpt = ""

    func parser(
        _: XMLParser,
        didStartElement name: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes _: [String: String]
    ) {
        if name == "rss" {
            isRSS = true
        }
        if name == "item" {
            inItem = true; title = ""; excerpt = ""
        }
        field = name
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        if field == "title" {
            title += string
        }
        if field == "description" {
            excerpt += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
    }

    func parser(_: XMLParser, didEndElement name: String, namespaceURI _: String?, qualifiedName _: String?) {
        if name == "item" {
            inItem = false
            let title = Self.plain(title, limit: 200), excerpt = Self.plain(excerpt, limit: 1200)
            if sources.count < 5, !title.isEmpty, !excerpt.isEmpty {
                sources.append(PublicSource(title: title, excerpt: excerpt))
            }
        }
        field = ""
    }

    private static func plain(_ value: String, limit: Int) -> String {
        let stripped = value.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let scalars = stripped.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format ? " " : String(scalar)
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(String.UnicodeScalarView(scalars.unicodeScalars.prefix(limit)))
    }
}
