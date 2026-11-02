import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeholderScreen: View {
    let model: PanelModel
    let research: BeholderModel
    @Binding var screen: HUDScreen

    var body: some View {
        HUDShell {
            HUDTopBar(model: model, screen: $screen)
        } content: {
            BeholderDashboard(research: research, followsPanel: true)
        } bottom: {
            Text("PUBLIC SOURCES · LOCAL CASE · NO AUTOMATIC MEMORY").hudType(.data).foregroundStyle(HUD.inkMuted)
        }
    }
}

struct BeholderDashboard: View {
    private enum Sheet: Identifiable {
        case sources, link(BeholderPeopleView.Target)
        var id: String {
            switch self {
            case .sources: "sources"
            case let .link(target): target.id.uuidString
            }
        }
    }

    private enum CaseTab: Hashable {
        case github, results, people, evidence, planner
    }

    @State private var research: BeholderModel
    @State private var discovery: BeholderDiscovery
    @State private var github: BeholderGitHubResearch
    var followsPanel = false
    @State private var exporting = false
    @State private var document = BeholderDocument()
    @State private var exportProblem: String?
    @State private var sheet: Sheet?
    @State private var tab = CaseTab.results
    @State private var showingDetails = false
    @State private var clearing = false
    @State private var opening = false
    @State private var reviewingImport = false
    @State private var pendingImport: Data?
    @State private var importPreview = ""
    @State private var reading = false
    @State private var importJob: Task<Void, Never>?
    @State private var importGeneration = UUID()
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    init(research: BeholderModel, followsPanel: Bool = false) {
        _research = State(initialValue: research)
        _discovery = State(initialValue: BeholderDiscovery(research))
        _github = State(initialValue: research.githubDiscovery)
        _tab = State(initialValue: research.hasCase ? .results : .github)
        self.followsPanel = followsPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            header
            if tab != .github {
                searchBar
            }
            if let problem = discovery.problem ?? (discovery.kind == .username ? research.problem : nil) ?? exportProblem {
                Text(problem).hudType(.caption).foregroundStyle(HUD.warn)
            }
            if research.includesImportedObservations {
                Text((research.importDescription ?? "") + " " + BeholderCaseFile.provenanceNote).hudType(.caption).foregroundStyle(HUD.warn)
            }
            caseBar
            tabContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("Case stays in memory until you export it. A matching handle is not proof of who owns it.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
        }
        .foregroundStyle(HUD.ink).padding(HUD.space4)
        .environment(\.hudTheme, theme)
        .sheet(item: $sheet) { presented in
            Group {
                switch presented {
                case .sources:
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Button("Original four") { research.selected = BeholderProvider.originalSources }
                                .buttonStyle(HUDChipStyle(muted: true))
                            Spacer()
                            Button("Done") { sheet = nil }.keyboardShortcut(.cancelAction).buttonStyle(HUDChipStyle())
                        }.padding(.horizontal, HUD.space4).padding(.top, HUD.space3)
                        BeholderSourceGuideView(selected: $research.selected)
                    }.frame(width: 440).background(HUD.void)
                case let .link(target): BeholderPeopleView(research: research, target: target)
                }
            }.environment(\.hudTheme, theme)
        }
        .confirmationDialog("Clear this case?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Export case…") { prepareExport() }.disabled(research.searching)
            Button("Clear case", role: .destructive) { clearCase() }
            Button("Keep case", role: .cancel) {}
        } message: {
            Text("People, account links and evidence will be removed from this session. Export first to keep a copy.")
        }
        .confirmationDialog("Open imported case?", isPresented: $reviewingImport, titleVisibility: .visible) {
            Button("Open and replace current case") {
                do {
                    if let data = pendingImport {
                        try research.importCase(data)
                        discovery.resetAfterImport()
                        github.reset()
                        tab = .results
                    }
                    exportProblem = nil
                } catch { exportProblem = "The case could not be opened. The current case was kept." }
                pendingImport = nil
            }
            Button("Export current case first…") {
                pendingImport = nil
                Task { @MainActor in
                    await Task.yield()
                    if !followsPanel || HUDPresence.shared.open {
                        prepareExport()
                    }
                }
            }
            .disabled(!research.hasCase)
            Button("Keep current case", role: .cancel) { pendingImport = nil }
        } message: {
            Text(importPreview +
                " Imported claims are unverified. This replaces the current session; export first to keep it, then reopen the import.")
        }
        .onDisappear { research.cancel(); cancelImport(); github.reset() }
        .onChange(of: research.cancellationID) { _, _ in cancelImport() }
        .onChange(of: HUDPresence.shared.open) { _, open in
            if followsPanel, !open {
                research.cancel()
                sheet = nil
                clearing = false
                exporting = false
                opening = false
                reviewingImport = false
                pendingImport = nil
                cancelImport()
                github.reset()
            }
        }
        .fileImporter(isPresented: $opening, allowedContentTypes: [.json]) { result in
            guard !followsPanel || HUDPresence.shared.open else { return }
            switch result {
            case let .success(url): prepareImport(url)
            case .failure: exportProblem = "The case could not be opened. The current case was kept."
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Beholder-case") { result in
            if case .failure = result {
                exportProblem = "The case could not be exported. Choose another destination and try again."
            }
        }
    }

    private func prepareExport() {
        do {
            document = try BeholderDocument(data: research.export())
            exportProblem = nil
            exporting = true
        } catch { exportProblem = (error as? BeholderCaseFile.Problem)?.message ?? "The case could not be prepared for export." }
    }

    private func clearCase() {
        discovery.clearCase()
        github.reset()
        tab = .github
    }

    /// Starts a bounded background read. Old or cancelled completions cannot replace a later preview.
    private func prepareImport(_ url: URL) {
        cancelImport()
        let generation = importGeneration
        let lookupGeneration = research.cancellationID
        reading = true
        importJob = Task { @MainActor in
            defer {
                if generation == importGeneration {
                    reading = false; importJob = nil
                }
            }
            let reader = Task.detached(priority: .userInitiated) { try BeholderCaseInput.read(url) }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                try Task.checkCancellation()
                guard generation == importGeneration, lookupGeneration == research.cancellationID,
                      !followsPanel || HUDPresence.shared.open else { return }
                let snapshot = try BeholderCaseFile.decode(data)
                let name = snapshot.username.isEmpty ? "No username" : "@" + snapshot.username
                importPreview = "\(name) · exported \(snapshot.exportedAt.formatted()). "
                    + (snapshot.importedFrom == nil ? "" : "Previously imported. ")
                    + "\(snapshot.findings.count) findings, \(snapshot.people.people.count) people, "
                    + "\(snapshot.correlation.accounts.count) accounts and \(snapshot.correlation.evidence.count) identifier observations."
                pendingImport = data
                exportProblem = nil
                reviewingImport = true
            } catch is CancellationError {
                // Closing the panel or cancelling a read keeps the active case unchanged.
            } catch {
                guard generation == importGeneration else { return }
                pendingImport = nil
                exportProblem = (error as? BeholderCaseFile.Problem)?.message ?? "The case could not be opened. The current case was kept."
            }
        }
    }

    private func cancelImport() {
        importGeneration = UUID()
        importJob?.cancel(); importJob = nil
        reading = false
    }
}

/// The dashboard's parts: header, search line, case bar and tab content.
extension BeholderDashboard {
    private var counter: String {
        if tab == .github {
            return "GITHUB DISCOVERY"
        }
        if discovery.kind == .username {
            return "\(research.candidates) " + (research.candidates == 1 ? "CANDIDATE" : "CANDIDATES")
        }
        if discovery.kind == .ip {
            return "IP CONTEXT"
        }
        guard let report = discovery.report else { return "CASE SEARCH" }
        return "\(report.total) " + (report.total == 1 ? "CASE MATCH" : "CASE MATCHES")
    }

    private var preview: String {
        if discovery
            .kind !=
            .username
        {
            if discovery.kind == .ip {
                return "IP inspection runs locally, without DNS or service requests."
            }
            return "Search this case runs locally. Public web lookups require a service choice and a separate browser-opening click."
        }
        guard let name = BeholderCaseSearch.username(discovery.query) else {
            return BeholderCaseSearch.usernameProblem(discovery.query) ?? "Enter a username to preview where it will be sent."
        }
        let eligible = research.providers.filter { $0.supports(name) }
        let hosts = eligible.filter { !$0.isManual && $0 != .bluesky }.map(\.host).joined(separator: ", ")
        let manualCount = eligible.filter(\.isManual).count
        let manualTotal = research.providers.filter(\.isManual).count
        var targets: [String] = []
        if !hosts.isEmpty {
            targets.append("“\(name)” to \(hosts) (case may be normalised)")
        }
        if eligible.contains(.bluesky) {
            targets.append("“\(BeholderProvider.bluesky.lookupHandle(name))” to \(BeholderProvider.bluesky.host)")
        }
        let destination = targets.isEmpty ? "Search sends no automatic requests." : "Search sends " + targets.joined(separator: "; ") + "."
        let automatic = targets.isEmpty ? "" : " Automatic sources receive your IP address and the Aegis-Beholder/1.0 app identifier."
        let manual = manualTotal == 0 ? "" : " \(manualCount) of \(manualTotal) manual sources have prepared links. "
            + "Search does not contact manual sources. Open a prepared link in your browser to inspect it."
        return destination + automatic + manual
    }

    private var header: some View {
        HStack(spacing: HUD.space3) {
            BeholderEmblem().frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beholder").hudType(.title).foregroundStyle(HUD.ink).hudBloom()
                Text("Follow the evidence.").hudType(.caption).foregroundStyle(HUD.inkMuted)
            }
            Spacer()
            HUDTag(word: counter, tone: research.searching ? HUD.primary : research.candidates > 0 ? HUD.ok : HUD.inkMuted)
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            HStack(spacing: HUD.space3) {
                Text("Find by").hudType(.label).foregroundStyle(HUD.inkMuted)
                HUDSegmented(
                    label: "Find by",
                    options: BeholderCaseSearch.Kind.allCases.map { HUDOption(value: $0, label: $0 == .ip ? "IP" : $0.rawValue) },
                    value: $discovery.kind
                )
                if discovery.kind == .phone {
                    HUDSegmented(
                        label: "Phone format",
                        options: BeholderQueryPlanner.PhoneRegion.allCases.map {
                            HUDOption(value: $0, label: $0 == .international ? "International +" : "Australia")
                        },
                        value: $discovery.region,
                        small: true
                    )
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: HUD.space3) {
                HUDTermInput(
                    prompt: (discovery.kind == .ip ? "ip" : discovery.kind.rawValue.lowercased()) + " >",
                    text: $discovery.query,
                    placeholder: placeholder,
                    hint: "⏎ " + (discovery.kind == .username ? "search" : discovery.kind == .ip ? "inspect" : "search case")
                )
                .onSubmit { runSearch() }
                .accessibilityLabel("Research " + discovery.kind.rawValue.lowercased())
                Button(discovery.actionTitle) { runSearch() }
                    .buttonStyle(HUDPlateStyle(kind: .primary)).fixedSize().disabled(!discovery.canSearch)
                if research.searching {
                    Button("Stop") { research.stopLookup() }.buttonStyle(HUDPlateStyle(kind: .critical)).fixedSize()
                }
            }
            if discovery.kind == .username {
                HStack(spacing: HUD.space2) {
                    Button("Sources · " + BeholderSources.summary(research.selected)) { sheet = .sources }
                        .buttonStyle(HUDChipStyle())
                        .accessibilityLabel("Choose public sources").accessibilityValue(BeholderSources.summary(research.selected))
                    if research.selected.count < BeholderProvider.allCases.count {
                        // Selecting never searches: the owner still presses Search after seeing the summary.
                        Button("Use all sources") { research.selected = Set(BeholderProvider.allCases) }
                            .buttonStyle(HUDChipStyle(muted: true))
                    }
                    Text(requestSummary).hudType(.caption).foregroundStyle(HUD.inkMuted).lineLimit(1)
                    Button(showingDetails ? "Hide details" : "What is sent") { showingDetails.toggle() }
                        .buttonStyle(HUDChipStyle(muted: true))
                    Spacer()
                }
                if showingDetails {
                    Text(preview).hudType(.caption).foregroundStyle(HUD.inkMuted).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(preview).hudType(.caption).foregroundStyle(HUD.inkMuted)
            }
            if research.searching, discovery.kind != .username {
                Text("Public sources are still checking @" + research.username + ". Use Stop to cancel that search.")
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
            }
            if discovery.kind != .ip, tab == .results {
                BeholderPublicSearchView(
                    input: .init(value: discovery.query, kind: discovery.kind, region: discovery.region),
                    ownerTyped: discovery.ownerTypedInput
                )
                .hudType(.caption)
            }
        }
    }

    private var caseBar: some View {
        HStack(spacing: HUD.space2) {
            HUDSegmented(
                label: "Case",
                options: [
                    HUDOption(value: CaseTab.github, label: "Discover"),
                    HUDOption(value: CaseTab.results, label: "Search tools", meta: resultsMeta),
                    HUDOption(value: CaseTab.people, label: "People", meta: "\(research.people.people.count)"),
                    HUDOption(value: CaseTab.evidence, label: "Evidence", meta: "\(research.correlation.accounts.count)"),
                    HUDOption(value: CaseTab.planner, label: "Planner"),
                ],
                value: $tab
            )
            Spacer()
            if reading {
                ProgressView().controlSize(.small)
                Button("Cancel opening") { cancelImport() }.buttonStyle(HUDChipStyle(muted: true))
            }
            Button("Open case…") { opening = true }.buttonStyle(HUDChipStyle()).disabled(research.searching || reading)
            Button("Export case…") { prepareExport() }.buttonStyle(HUDChipStyle())
                .disabled((research.findings.isEmpty && research.people.people.isEmpty && research.correlation.accounts.isEmpty) ||
                    research.searching)
            Button("Clear case") {
                if research.people.people.isEmpty, research.correlation.accounts.isEmpty {
                    clearCase()
                } else {
                    clearing = true
                }
            }
            .buttonStyle(HUDChipStyle(muted: true))
        }
        .padding(.top, HUD.space3)
        .overlay(alignment: .top) { HUDRule() }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .github:
            BeholderGitHubDiscoveryView(discovery: github, research: research) { sheet = .link($0) }
        case .results:
            if discovery.kind != .username {
                BeholderCaseSearchView(discovery: discovery) { sheet = .link($0) }
            } else if research.findings.isEmpty {
                emptyState
            } else {
                BeholderResultsView(
                    findings: research.findings,
                    username: research.username,
                    searching: research.searching,
                    research: research
                ) {
                    sheet = .link(.init(username: research.username, finding: $0))
                }
            }
        case .people: BeholderPeopleView(research: research, embedded: true)
        case .evidence: BeholderCorrelationView(research: research, embedded: true) { sheet = .link($0) }
        case .planner: ScrollView { BeholderQueryPlannerView(embedded: true).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: HUD.space4) {
            // Shrinks in a short window so the steps below stay in view.
            BeholderEmblem().aspectRatio(1, contentMode: .fit).frame(minWidth: 96, maxWidth: 240, minHeight: 96, maxHeight: 240)
            Text("Start with what you know.").hudType(.bodyStrong).foregroundStyle(HUD.ink)
            Button("Start a person investigation") { tab = .people }.buttonStyle(HUDChipStyle())
            HStack(alignment: .top, spacing: HUD.space6) {
                step(
                    "01",
                    "Find",
                    "Choose Username, Name, Email or Phone above. Public browser searches and saved-case matches are separate."
                )
                step("02", "Collect", "Create a person in People. Save promising accounts as possible without committing to an identity.")
                step("03", "Verify", "Compare sources and dates on the person page, then support or rule out each account.")
            }
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: HUD.space1) {
            HStack(spacing: HUD.space2) {
                Text(number).hudType(.data).foregroundStyle(HUD.primary)
                Text(title).hudType(.label).foregroundStyle(HUD.ink)
            }
            Text(text).hudType(.caption).foregroundStyle(HUD.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runSearch() {
        tab = .results
        discovery.search()
    }

    private var placeholder: String {
        switch discovery.kind {
        case .username: "Handle, e.g. ExampleAlex"
        case .name: "Name to research, e.g. Example Alex"
        case .email: "Email to research, e.g. example@example.com"
        case .phone: "Phone to research, including its country code"
        case .ip: "One IPv4 or IPv6 address"
        }
    }

    private var resultsMeta: String? {
        if discovery.kind == .username {
            return research.findings.isEmpty ? nil : "\(research.findings.count)"
        }
        return discovery.report.map { "\($0.total)" }
    }

    /// The short form of `preview`: how many sources are asked automatically and how many are browser links.
    private var requestSummary: String {
        guard let name = BeholderCaseSearch.username(discovery.query) else {
            return "Asks \(research.providers.filter { !$0.isManual }.count) sites automatically · "
                + "\(research.providers.filter(\.isManual).count) to check by hand"
        }
        let eligible = research.providers.filter { $0.supports(name) }
        return "Sends “\(name)” to \(eligible.filter { !$0.isManual }.count) sites · "
            + "\(eligible.filter(\.isManual).count) to check by hand"
    }
}

/// Reads only a selected local file, away from the main actor; no URL from file contents is followed.
enum BeholderCaseInput {
    static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL else { throw BeholderCaseFile.Problem.malformed }
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: BeholderCaseFile.byteLimit + 1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= BeholderCaseFile.byteLimit else { throw BeholderCaseFile.Problem.capacity }
        return data
    }
}

struct BeholderDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json]
    }

    var data = Data()
    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The Beholder mark in density-ramp characters, like the design system's other character art: an original floating
/// eye creature with ten eyestalks, mirrored left to right. Baked from Aegis's own drawing; no external artwork.
struct BeholderEmblem: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lines = side < 90 ? Self.small : Self.large
            HUDAsciiText(
                lines: lines,
                cols: lines.count * 2,
                size: side / CGFloat(lines.count),
                tone: HUD.primary,
                aspect: HUDAscii.artAspect
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("Beholder: a floating eye creature with ten eyestalks")
        .accessibilityAddTraits(.isImage)
    }

    /// 24 rows of 48 characters, for the empty state and larger.
    static let large = [
        "",
        "",
        "                  .*%#=  =#%*.",
        "                  .*%#=  =#%*.",
        "         .    .==:  *=    =*  :==.    .",
        "       =#%*.  #*#%  +*    *+  %#*#  .*%#=",
        "       -#@#.  .=@-  :%    %:  -@=.  .#@#-",
        "         :#=.   :#=.:%*++*%:.=#:   .=#:",
        "      .+*= :+*=:-*@@@@@@@@@@@@*-:=*+: =*+.",
        "      +*@@*+-.+@@@@@@@@@@@@@@@@@@+.-+*@@*+",
        "  --::.--. .=@@@@@@@@#*++*#@@@@@@@@=. .--.::--",
        " **%%+=+++++%@@@@@*-.=#++#=.-*@@@@@%+++++=+%%**",
        " .++=      +@@@@*.  *@@::@@*  .*@@@@+      =++.",
        "           %@@@@*:  +@@::@@+  :*@@@@%",
        "           #@@@@@@#-.=#++#=.-#@@@@@@#",
        "           +@@@@@@@@@%****%@@@@@@@@@+",
        "            #@@@%#%@@@@@@@@@@%#%@@@#",
        "            .*@@@#- .:----:. -#@@@*.",
        "              -#@@@%+-.  .-+%@@@#-",
        "                :+#@@@@@@@@@@#+:",
        "                    :--==--:",
        "",
        "",
        "",
    ]

    /// 16 rows of 32 characters, for the header and smaller.
    static let small = [
        "",
        "            :+=  =+:",
        "            :#+  +#:",
        "    .++: =#* =-  -= *#= :++.",
        "     =#: .=* .*  *. *=. :#=",
        "    :=:==-:+%#@@@@#%+:-==:=:",
        "    =#*==*@@@@@@@@@@@@*==*#=",
        ".*#+-==-#@@@#=+==+=#@@@#-==-+#*.",
        " --.   =@@%: =@==@= :%@@=   .--",
        "       +@@@#=:*++*:=#@@@+",
        "       -@@@@@@%##%@@@@@@-",
        "        =@@#===++===#@@=",
        "         .*@@#=--=#@@*.",
        "            :=++++=:",
        "",
        "",
    ]
}

@MainActor
final class BeholderWindow: NSObject, NSWindowDelegate {
    private static let shared = BeholderWindow()
    private var window: NSWindow?
    private let research = BeholderModel()

    static func show() {
        shared.present()
    }

    private func present() {
        if let window {
            NSApp.activate(); window.makeKeyAndOrderFront(nil); return
        }
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: false
        )
        created.title = "Beholder · Public research"
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.contentView = NSHostingView(rootView: BeholderDashboard(research: research).background(HUD.void).environment(
            \.colorScheme,
            .dark
        ))
        created.minSize = NSSize(width: 900, height: 650)
        created.center()
        window = created
        NSApp.activate()
        created.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        research.cancel()
    }
}
