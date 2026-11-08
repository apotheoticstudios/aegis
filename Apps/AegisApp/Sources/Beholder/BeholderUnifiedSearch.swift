import Foundation
import Observation

/// Recognises only the owner's current input. Recognition never authorises a request.
@MainActor @Observable
final class BeholderUnifiedSearch {
    typealias Kind = BeholderCaseSearch.Kind
    private var text = ""
    private var chosenKind: Kind?
    private var phoneRegion = BeholderQueryPlanner.PhoneRegion.international
    private let github: BeholderGitHubResearch
    @ObservationIgnored var edited: () -> Void = {}
    @ObservationIgnored private var cachedReports: [Kind: BeholderCaseSearch.Report] = [:]
    @ObservationIgnored private var cachedRevision: UInt64?
    private(set) var prepared: BeholderPublicSearch.Input?
    private(set) var profileQuery: String?
    private(set) var problem: String?

    init(github: BeholderGitHubResearch) {
        self.github = github
    }

    var query: String {
        get { text }
        set {
            guard text != newValue else { return }
            text = newValue
            chosenKind = nil
            invalidate()
        }
    }

    var region: BeholderQueryPlanner.PhoneRegion {
        get { phoneRegion }
        set {
            guard phoneRegion != newValue else { return }
            phoneRegion = newValue
            invalidate()
        }
    }

    var kind: Kind? {
        chosenKind ?? Self.detect(text)
    }

    var automatic: Bool {
        chosenKind == nil
    }

    var ambiguous: Bool {
        automatic && kind == .username && Self.validName(text)
    }

    var inputHint: String? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !canPrepare else { return nil }
        if text.contains("://") {
            return "Enter the handle, name or address rather than a profile link."
        }
        switch kind {
        case .phone: return "Add a +country code, or choose Australia for a national number."
        case .email: return "Enter one complete email address, such as example@example.com."
        case .ip: return "Enter a numeric IPv4 or IPv6 address without a port or prefix."
        case .username: return "Enter one handle using letters, numbers, dots, dashes or underscores."
        case .name: return "Enter a name using letters, spaces, periods, apostrophes or hyphens."
        case nil: return "Enter one name, username, email, phone number or numeric IP address."
        }
    }

    var canPrepare: Bool {
        guard let kind else { return false }
        switch kind {
        case .username: return BeholderCaseSearch.username(text) != nil
        case .name: return Self.validName(text)
        case .email, .phone:
            return BeholderIdentifier(input: text, kind: kind == .email ? .email : .phone, region: region) != nil
        case .ip: return BeholderIPContext.inspect(text) != nil
        }
    }

    func interpret(as kind: Kind?) {
        chosenKind = kind
        invalidate()
    }

    func reset() {
        text = ""
        chosenKind = nil
        phoneRegion = .international
        clear()
    }

    private func clear() {
        prepared = nil
        cachedReports.removeAll()
        cachedRevision = nil
        problem = nil
        stopPublicWork()
    }

    /// Closing the panel stops requests but keeps the owner's local search in memory.
    func stopPublicWork() {
        profileQuery = nil
        github.reset()
    }

    private func invalidate() {
        clear()
        edited()
    }

    func prepare() {
        invalidate()
        guard canPrepare, let kind else {
            problem = inputHint ?? "Check the input or change its interpretation below."
            return
        }
        prepared = .init(value: text, kind: kind, region: region)
    }

    /// A deliberate Search submits only the current owner-typed input to its supported sources.
    func run(in model: BeholderModel) {
        prepare()
        guard let prepared else { return }
        switch prepared.kind {
        case .username:
            model.query = prepared.value
            model.start(providers: BeholderProvider.automaticSources)
            profileQuery = BeholderCaseSearch.username(prepared.value)
        case .name, .email:
            chooseGitHub()
            github.search(into: model)
        case .phone, .ip: break
        }
    }

    var requestSummary: String {
        guard canPrepare, let kind else { return "Enter an identifier to see automatic search coverage." }
        switch kind {
        case .username:
            let name = BeholderCaseSearch.username(text) ?? ""
            let count = BeholderProvider.automaticSources.filter { $0.supports(name) }.count
            return "Search retrieves public profiles from the supported automatic sources using this username (up to \(count) checks)."
        case .name, .email:
            return "Search sends this \(kind.rawValue.lowercased()) to GitHub and retrieves up to 20 matching public profiles."
        case .phone: return "Phone search checks the saved references and account evidence in this case."
        case .ip: return "IP search shows local address context."
        }
    }

    /// The alternate interpretation only reads the case. Public actions still use the prepared input.
    func report(in model: BeholderModel, alternate: Bool = false) -> BeholderCaseSearch.Report? {
        guard let prepared, prepared.kind != .ip, !alternate || ambiguous else { return nil }
        let kind = alternate ? Kind.name : prepared.kind
        if cachedRevision != model.caseRevision {
            cachedReports.removeAll()
            cachedRevision = model.caseRevision
        }
        if let report = cachedReports[kind] {
            return report
        }
        let report = try? BeholderCaseSearch.compute(
            input: prepared.value, kind: kind, region: prepared.region,
            store: model.correlation, people: model.people
        )
        cachedReports[kind] = report
        return report
    }

    var ip: BeholderIPContext.Info? {
        guard let prepared, prepared.kind == .ip else { return nil }
        return BeholderIPContext.inspect(prepared.value)
    }

    func chooseGitHub() {
        guard let prepared, [.name, .email].contains(prepared.kind) else { return }
        github.kind = prepared.kind == .name ? .name : .email
        github.value = prepared.value
        github.chooseGitHub()
    }

    func searchProfiles(in model: BeholderModel) {
        guard let prepared, prepared.kind == .username,
              let username = BeholderCaseSearch.username(prepared.value) else { return }
        model.query = prepared.value
        model.start()
        profileQuery = username
    }

    /// Existing per-kind validators remain the final authority after shape recognition.
    static func detect(_ raw: String) -> Kind? {
        guard raw.utf8.count <= 512, raw.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.contains("://") else { return nil }
        if value.hasPrefix("@"), !value.dropFirst().contains("@") {
            return .username
        }
        if value.contains("@") || value.lowercased().hasPrefix("mailto:") {
            return .email
        }
        if value.lowercased().hasPrefix("tel:") || value.hasPrefix("+") {
            return .phone
        }
        if value.contains(":") {
            return .ip
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) {
            return .ip
        }
        let phoneCharacters = CharacterSet(charactersIn: "0123456789 ().-")
        if value.filter({ $0.isASCII && $0.isNumber }).count >= 7,
           value.unicodeScalars.allSatisfy(phoneCharacters.contains)
        {
            return .phone
        }
        if value.contains(where: \.isWhitespace), Self.validName(value) {
            return .name
        }
        if BeholderCaseSearch.username(value) != nil {
            return .username
        }
        return Self.validName(value) ? .name : nil
    }

    private static func validName(_ value: String) -> Bool {
        if case .success = BeholderQueryPlanner.build(input: value, kind: .name) {
            return true
        }
        return false
    }
}
