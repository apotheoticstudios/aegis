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
        automatic && Self.detect(text) == .username && !text.hasPrefix("@") && Self.validName(text)
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
        profileQuery = nil
        problem = nil
        github.reset()
    }

    private func invalidate() {
        clear()
        edited()
    }

    func prepare() {
        invalidate()
        guard canPrepare, let kind else {
            problem = kind == .phone ? "Add a country code starting with +, or choose Australia for a national number."
                : "Check the input or change its interpretation below."
            return
        }
        prepared = .init(value: text, kind: kind, region: region)
    }

    func report(in model: BeholderModel) -> BeholderCaseSearch.Report? {
        guard let prepared, prepared.kind != .ip else { return nil }
        return try? BeholderCaseSearch.compute(
            input: prepared.value, kind: prepared.kind, region: prepared.region,
            store: model.correlation, people: model.people
        )
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
        guard !value.isEmpty else { return nil }
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
