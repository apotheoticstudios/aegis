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
        case results, people, evidence, planner
    }

    @State private var research: BeholderModel
    var followsPanel = false
    @State private var exporting = false
    @State private var document = BeholderDocument()
    @State private var exportProblem: String?
    @State private var sheet: Sheet?
    @State private var tab = CaseTab.results
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
        self.followsPanel = followsPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            header
            if let problem = exportProblem {
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

    private func prepareExport() {
        do {
            document = try BeholderDocument(data: research.export())
            exportProblem = nil
            exporting = true
        } catch { exportProblem = (error as? BeholderCaseFile.Problem)?.message ?? "The case could not be prepared for export." }
    }

    private func clearCase() {
        research.clear()
        tab = .results
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
        research.searching || research.githubDiscovery.searching ? "SEARCHING" : "UNIFIED SEARCH"
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

    private var caseBar: some View {
        HStack(spacing: HUD.space2) {
            HUDSegmented(
                label: "Case",
                options: [
                    HUDOption(value: CaseTab.results, label: "Search"),
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
        case .results:
            BeholderUnifiedSearchView(research: research, onSources: { sheet = .sources }) { sheet = .link($0) }
        case .people: BeholderPeopleView(research: research, embedded: true)
        case .evidence: BeholderCorrelationView(research: research, embedded: true) { sheet = .link($0) }
        case .planner: ScrollView { BeholderQueryPlannerView(embedded: true).frame(maxWidth: .infinity, alignment: .leading) }
        }
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
