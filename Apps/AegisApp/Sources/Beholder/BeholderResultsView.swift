import SwiftUI

/// What the owner can do next with a finding. Grouping only: it never changes a finding or its evidence.
enum BeholderResultGroup: CaseIterable {
    /// Display order: found accounts, then what is still running, then what the owner can act on.
    case found, checking, manual, unresolved, noResult, notChecked

    static func of(_ finding: BeholderFinding) -> Self {
        if finding.status == .queued || finding.status == .checking {
            return .checking
        }
        return switch BeholderEvidence.outcome(finding) {
        case .candidate: .found
        case .manual: .manual
        case .unresolved: .unresolved
        case .noResult: .noResult
        case .notChecked: .notChecked
        }
    }

    var title: String {
        switch self {
        case .found: "Found"
        case .manual: "Check by hand"
        case .checking: "Checking"
        case .unresolved: "Couldn't check"
        case .noResult: "No public result"
        case .notChecked: "Not checked"
        }
    }

    var hint: String {
        switch self {
        case .found: "A public profile uses this handle. Review it before linking it to a person."
        case .manual: "Beholder doesn't contact these sites. Open a link to look in your browser."
        case .checking: "Waiting for these sources to answer."
        case .unresolved: "The source refused, limited or broke the check. This is not evidence either way."
        case .noResult: "No public profile came back. That doesn't prove there is no account."
        case .notChecked: "Stopped, or the handle doesn't fit this site's rules."
        }
    }

    /// Long, quiet groups start folded so found accounts stay in view.
    var folded: Bool {
        self == .noResult || self == .notChecked
    }
}

/// Username results grouped by what to do next, found accounts first.
struct BeholderResultsView: View {
    let findings: [BeholderFinding]
    let username: String
    let searching: Bool
    var research: BeholderModel?
    let onLink: (BeholderFinding) -> Void
    @State private var unfolded: Set<BeholderResultGroup> = []
    @State private var savingPerson: UUID?
    @State private var saveProblem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                HStack(spacing: HUD.space2) {
                    Text("Results for @" + username).hudType(.label).foregroundStyle(HUD.ink)
                    if searching {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if !searching {
                    BeholderEvidenceSummaryView(findings: findings)
                }
                if let research {
                    BeholderMenuPicker(
                        label: "Save possible accounts for",
                        placeholder: "Choose a person",
                        options: research.people.people.map { ($0.id, $0.name) },
                        selection: $savingPerson
                    )
                    if research.people.people.isEmpty {
                        Text("Create a person in People to collect possible accounts for that investigation.").hudType(.caption)
                    }
                }
                if let saveProblem {
                    Text(saveProblem).hudType(.caption).foregroundStyle(HUD.warn)
                }
                ForEach(BeholderResultGroup.allCases, id: \.self) { group in
                    let members = findings.filter { BeholderResultGroup.of($0) == group }
                    if !members.isEmpty {
                        section(group, members)
                    }
                }
            }
            .padding(.trailing, HUD.space2)
        }
        .onAppear {
            if research?.people.people.count == 1 {
                savingPerson = research?.people.people.first?.id
            }
        }
        .onChange(of: research?.people.people.map(\.id)) { _, ids in
            if let savingPerson, ids?.contains(savingPerson) != true {
                self.savingPerson = nil
            }
        }
    }

    private func section(_ group: BeholderResultGroup, _ members: [BeholderFinding]) -> some View {
        let open = !group.folded || unfolded.contains(group)
        return VStack(alignment: .leading, spacing: HUD.space2) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                Text(group.title).hudCaps(10, tracking: 0.2).foregroundStyle(group == .found ? HUD.ok : HUD.primary)
                Text("\(members.count)").font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
                Text(group.hint).hudType(.caption).foregroundStyle(HUD.inkMuted).lineLimit(1)
                Spacer(minLength: HUD.space2)
                if group.folded {
                    Button(open ? "Hide" : "Show") {
                        if open {
                            unfolded.remove(group)
                        } else {
                            unfolded.insert(group)
                        }
                    }
                    .buttonStyle(HUDChipStyle(muted: true))
                }
            }
            .padding(.top, HUD.space2)
            .overlay(alignment: .top) { HUDRule() }
            if open {
                if group == .found {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: HUD.space3, alignment: .top)],
                        alignment: .leading,
                        spacing: HUD.space3
                    ) {
                        ForEach(members) { found($0) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: HUD.space6)], alignment: .leading, spacing: 0) {
                        ForEach(members) { row($0, group) }
                    }
                }
            }
        }
    }

    private func found(_ finding: BeholderFinding) -> some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            HStack {
                Text(finding.provider.title).hudType(.label).foregroundStyle(HUD.ink)
                Spacer()
                HUDTag(word: "Found", tone: HUD.ok)
            }
            ForEach(finding.fields.keys.sorted(), id: \.self) { label in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).hudCaps(9).foregroundStyle(HUD.inkMuted)
                    Text(verbatim: finding.fields[label] ?? "").hudType(.body).foregroundStyle(HUD.ink).textSelection(.enabled)
                }
            }
            BeholderEvidenceExplanationView(finding: finding)
            HStack(spacing: HUD.space2) {
                if let url = finding.provider.profileURL(username) {
                    Link("Open profile ↗", destination: url).buttonStyle(HUDChipStyle())
                        .help("Opens your browser; the website receives the visit under your browser's settings.")
                }
                Button("Link to person…") { onLink(finding) }.buttonStyle(HUDChipStyle(muted: true))
            }
            saveButton(finding)
        }
        .padding(HUD.space3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background { HUDGlass(tone: HUD.ok, cut: HUD.chamferSm, arm: 10) }
    }

    private func row(_ finding: BeholderFinding, _ group: BeholderResultGroup) -> some View {
        let explanation = BeholderEvidence.explain(finding)
        return VStack(alignment: .leading, spacing: HUD.space1) {
            HStack(spacing: HUD.space2) {
                Text(finding.provider.title).hudType(.label).foregroundStyle(HUD.ink).lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                Text(verbatim: detail(finding, group, explanation)).hudType(.caption).foregroundStyle(HUD.inkMuted).lineLimit(1)
                Spacer(minLength: HUD.space1)
                if group == .manual {
                    if let url = finding.preparedProfileURL {
                        Link("Open ↗", destination: url).buttonStyle(HUDChipStyle()).fixedSize()
                            .help("This link has not been checked. Opens using your browser's privacy and sign-in settings.")
                    }
                    if finding.status == .manual {
                        Button("Link…") { onLink(finding) }.buttonStyle(HUDChipStyle(muted: true)).fixedSize()
                            .accessibilityLabel("Link \(finding.provider.title) to a person")
                    }
                }
            }
            .frame(minHeight: 30)
            if group == .manual, finding.status == .manual {
                saveButton(finding)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
        .help(([explanation.reason] + explanation.provenance).joined(separator: "\n"))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func saveButton(_ finding: BeholderFinding) -> some View {
        if let research, let person = research.people.people.first(where: { $0.id == savingPerson }) {
            let key = BeholderCorrelation.key(finding.provider, username)
            let supportKey = BeholderPeople.supportKey(provider: finding.provider, username: username)
            if let link = person.links.first(where: { $0.accountKey == key || $0.supportKey == supportKey }) {
                Text(link.assessment.title + " for " + person.name).hudType(.caption).foregroundStyle(HUD.inkMuted)
            } else if let other = research.people.people.first(where: {
                $0.id != person.id && $0.links.contains { $0.supportKey == supportKey && $0.assessment == .supported }
            }) {
                Text("Supported under " + other.name + ". Use Link to person to review the conflict.")
                    .hudType(.caption).foregroundStyle(HUD.warn)
            } else {
                Button("Save as possible for " + person.name) {
                    do { try research.savePossible(personID: person.id, username: username, finding: finding); saveProblem = nil }
                    catch { saveProblem = (error as? BeholderPeople.Problem)?.message ?? "The account could not be saved." }
                }.buttonStyle(HUDChipStyle(muted: true))
            }
        }
    }

    private func detail(_ finding: BeholderFinding, _ group: BeholderResultGroup, _ explanation: BeholderEvidence.Explanation) -> String {
        switch group {
        case .manual: finding.preparedProfileURL.map { $0.host() ?? "" } ?? "Handle doesn't fit this site"
        case .checking: finding.status.title
        case .unresolved: explanation.reason
        case .found, .noResult, .notChecked: finding.provider.host
        }
    }
}

/// A text field in the design system's field box, with the focus ring while typing.
struct BeholderField: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(HUDFace.mono(12)).focused($focused).hudField(focused: focused)
    }
}

extension View {
    /// The design system's look for a Beholder sub-view: Kode Mono text and chip buttons and links.
    func beholderStyle() -> some View {
        font(HUDType.body.font).buttonStyle(HUDChipStyle())
    }
}

/// A choice from a longer list (people, accounts, services) as a design-system chip that opens a menu.
struct BeholderMenuPicker<Value: Hashable>: View {
    let label: String
    let placeholder: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value?

    var body: some View {
        HStack(spacing: HUD.space2) {
            Text(label).hudType(.label).foregroundStyle(HUD.inkMuted)
            Menu {
                Button(placeholder) { selection = nil }
                ForEach(options, id: \.value) { option in
                    Button(option.title) { selection = option.value }
                }
            } label: {
                Text((options.first { $0.value == selection }?.title ?? placeholder) + "  ▾")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(HUDChipStyle())
            .fixedSize()
            .accessibilityLabel(label)
        }
    }
}
