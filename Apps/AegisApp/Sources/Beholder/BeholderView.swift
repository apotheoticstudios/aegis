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
        case planner, people, sources, evidence, link(BeholderPeopleView.Target)
        var id: String {
            switch self {
            case .planner: "planner"
            case .people: "people"
            case .sources: "sources"
            case .evidence: "evidence"
            case let .link(target): target.id.uuidString
            }
        }
    }

    @State private var research: BeholderModel
    @State private var discovery: BeholderDiscovery
    var followsPanel = false
    @State private var exporting = false
    @State private var document = BeholderDocument()
    @State private var exportProblem: String?
    @State private var sheet: Sheet?
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
        self.followsPanel = followsPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space4) {
            HStack(spacing: HUD.space4) {
                BeholderEmblem().frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text("BEHOLDER").font(.system(size: 28, weight: .light, design: .monospaced))
                    Text("Follow the evidence.").foregroundStyle(HUD.inkMuted)
                }
                Spacer()
                Text(discovery.kind == .username ? "\(research.candidates) CANDIDATES" : "\(discovery.report?.total ?? 0) CASE MATCHES")
                    .hudType(.data).foregroundStyle(HUD.primary)
            }
            HStack {
                Picker("Find by", selection: $discovery.kind) {
                    ForEach(BeholderCaseSearch.Kind.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
                TextField(discovery.kind.rawValue, text: $discovery.query)
                    .textFieldStyle(.roundedBorder).onSubmit { discovery.search() }
                    .accessibilityLabel("Research " + discovery.kind.rawValue.lowercased())
                Button(discovery.actionTitle) { discovery.search() }.disabled(!discovery.canSearch)
                if research.searching {
                    Button("Stop") { research.cancel() }
                }
                Button("Clear case") {
                    if research.people.people.isEmpty, research.correlation.accounts.isEmpty {
                        discovery.clearCase()
                    } else {
                        clearing = true
                    }
                }
            }
            if discovery.kind == .phone {
                Picker("Phone format", selection: $discovery.region) {
                    ForEach(BeholderQueryPlanner.PhoneRegion.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 370)
            }
            HStack(spacing: HUD.space4) {
                if discovery.kind == .username {
                    Button { sheet = .sources } label: {
                        Label(BeholderSources.summary(research.selected), systemImage: "line.3.horizontal.decrease.circle")
                    }.accessibilityLabel("Choose public sources").accessibilityValue(BeholderSources.summary(research.selected))
                }
                Button("Research planner…") { sheet = .planner }
                Button("People (\(research.people.people.count))…") { sheet = .people }
                Button("Evidence…") { sheet = .evidence }
                Spacer()
                if reading {
                    ProgressView().controlSize(.small)
                    Button("Cancel opening") { cancelImport() }
                }
                Button("Open case…") { opening = true }.disabled(research.searching || reading)
                Button("Export case…") { prepareExport() }
                    .disabled((research.findings.isEmpty && research.people.people.isEmpty && research.correlation.accounts.isEmpty) ||
                        research.searching)
            }
            Text(preview).font(.caption).foregroundStyle(HUD.inkMuted).textSelection(.enabled)
            if discovery.kind != .ip {
                BeholderPublicSearchView(
                    input: .init(value: discovery.query, kind: discovery.kind, region: discovery.region),
                    ownerTyped: discovery.ownerTypedInput
                )
            }
            if let problem = discovery.problem ?? (discovery.kind == .username ? research.problem : nil) ?? exportProblem {
                Text(problem).foregroundStyle(HUD.warn)
            }
            if research.includesImportedObservations {
                Text((research.importDescription ?? "") + " " + BeholderCaseFile.provenanceNote).font(.caption).foregroundStyle(HUD.warn)
            }
            Divider()
            if discovery.kind != .username {
                BeholderCaseSearchView(discovery: discovery) { sheet = .link($0) }
            } else if research.findings.isEmpty {
                VStack(spacing: HUD.space4) {
                    BeholderEmblem().frame(width: 150, height: 150).opacity(0.6)
                    Text("One handle. Several public sources.").font(.title3)
                    Text("Choose sources and start a search. Link accounts to a person using evidence you have reviewed.")
                        .foregroundStyle(HUD.inkMuted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("RESULTS FOR @" + research.username).hudType(.data)
                    Spacer()
                    if research.searching {
                        ProgressView().controlSize(.small)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: HUD.space3) {
                        if research.searching {
                            Text("Search in progress. Results appear as checks finish.")
                                .font(.caption).foregroundStyle(HUD.inkMuted).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            BeholderEvidenceSummaryView(findings: research.findings)
                        }
                        LazyVGrid(
                            columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                            alignment: .leading,
                            spacing: HUD.space4
                        ) {
                            ForEach(research.findings) { finding in card(finding) }
                        }
                    }
                }
            }
            Text("Case stays in memory until you export it.")
                .font(.caption).foregroundStyle(HUD.inkMuted)
        }
        .foregroundStyle(HUD.ink).padding(HUD.space4)
        .environment(\.hudTheme, theme)
        .sheet(item: $sheet) { presented in
            Group {
                switch presented {
                case .planner: BeholderQueryPlannerView()
                case .people: BeholderPeopleView(research: research)
                case .evidence: BeholderCorrelationView(research: research) { sheet = .link($0) }
                case .sources:
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Button("Original four") { research.selected = BeholderProvider.originalSources }
                            Spacer()
                            Button("Done") { sheet = nil }.keyboardShortcut(.cancelAction)
                        }.padding(.horizontal, HUD.space4).padding(.top, HUD.space3)
                        BeholderSourceGuideView(selected: $research.selected)
                    }.frame(width: 440).background(HUD.void)
                case let .link(target): BeholderPeopleView(research: research, target: target)
                }
            }.environment(\.hudTheme, theme)
        }
        .confirmationDialog("Clear this case?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Export case…") { prepareExport() }.disabled(research.searching)
            Button("Clear case", role: .destructive) { discovery.clearCase() }
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
        .onDisappear { research.cancel(); cancelImport() }
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

    private var preview: String {
        if discovery
            .kind !=
            .username
        {
            return discovery.kind == .ip ? "IP inspection runs locally, without DNS or service requests." : "Search this case runs locally. Public web lookups require a service choice and a separate browser-opening click."
        }
        guard let name = BeholderProvider.username(discovery.query) else { return "Enter a username to preview where it will be sent." }
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

    private func card(_ finding: BeholderFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(finding.provider.title).font(.headline)
                Spacer()
                if finding.status.title != BeholderEvidence.outcome(finding).title {
                    Text(finding.status.title).font(.caption).foregroundStyle(HUD.inkMuted)
                }
            }
            ForEach(finding.fields.keys.sorted(), id: \.self) { label in
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased()).font(.caption2).foregroundStyle(HUD.inkMuted)
                    Text(verbatim: finding.fields[label] ?? "").textSelection(.enabled)
                }
            }
            BeholderEvidenceExplanationView(finding: finding)
            if finding.status == .manual, let url = finding.preparedProfileURL {
                Link("Open unchecked profile ↗", destination: url).font(.caption)
                    .help("This link has not been checked. Opens using your browser's privacy and sign-in settings.")
            } else if finding.status == .candidate, let url = finding.provider.profileURL(research.username) {
                Link("Open public profile ↗", destination: url).font(.caption)
                    .help("Opens your browser; the website receives the visit under your browser's settings.")
            }
            if finding.status == .candidate || finding.status == .manual {
                Button("Link to person…") { sheet = .link(.init(username: research.username, finding: finding)) }.font(.caption)
            }
        }
        .padding(HUD.space4).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HUD.surface).overlay(Rectangle().stroke(HUD.line, lineWidth: 1))
    }

    private func prepareExport() {
        do {
            document = try BeholderDocument(data: research.export())
            exportProblem = nil
            exporting = true
        } catch { exportProblem = (error as? BeholderCaseFile.Problem)?.message ?? "The case could not be prepared for export." }
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

/// Original vector artwork: a central eye, toothed orb and ten eye stalks. No external artwork or network assets.
struct BeholderEmblem: View {
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let ink = theme.color(.primary)
            let scale = min(size.width, size.height) / 100
            context.scaleBy(x: scale, y: scale)
            for index in 0 ..< 10 {
                let angle = Double(index) * .pi / 9 + .pi
                let tip = CGPoint(x: 50 + cos(angle) * 43, y: 49 + sin(angle) * 40)
                var stalk = Path()
                stalk.move(to: CGPoint(x: 50 + cos(angle) * 22, y: 48 + sin(angle) * 19))
                stalk.addQuadCurve(to: tip, control: CGPoint(x: tip.x, y: 42))
                context.stroke(stalk, with: .color(ink.opacity(0.75)), lineWidth: 1.5)
                context.stroke(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 3, width: 8, height: 6)), with: .color(ink), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: tip.x - 1, y: tip.y - 2, width: 2, height: 4)), with: .color(ink))
            }
            context.stroke(Path(ellipseIn: CGRect(x: 23, y: 29, width: 54, height: 57)), with: .color(ink), lineWidth: 1.5)
            context.stroke(Path(ellipseIn: CGRect(x: 31, y: 40, width: 38, height: 25)), with: .color(ink), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: 45, y: 42, width: 10, height: 21)), with: .color(ink))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 34, y: 72))
            for index in 0 ..< 9 {
                mouth.addLine(to: CGPoint(x: 34 + index * 4, y: index.isMultiple(of: 2) ? 72 : 78))
            }
            context.stroke(mouth, with: .color(ink), lineWidth: 1.2)
        }
        .accessibilityLabel("Beholder: a floating eye with ten eye stalks")
    }
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
