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
    @State private var research: BeholderModel
    var followsPanel = false
    @State private var exporting = false
    @State private var document = BeholderDocument()
    @State private var exportProblem: String?
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    init(research: BeholderModel, followsPanel: Bool = false) {
        _research = State(initialValue: research)
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
                Text("\(research.candidates) " + (research.candidates == 1 ? "CANDIDATE" : "CANDIDATES"))
                    .hudType(.data).foregroundStyle(HUD.primary)
            }
            HStack {
                TextField("Username", text: $research.query)
                    .textFieldStyle(.roundedBorder).onSubmit { research.start() }
                    .accessibilityLabel("Public username to research")
                Button("Search public sources") { research.start() }
                    .disabled(research.preparedUsername == nil || research.providers.isEmpty)
                if research.searching {
                    Button("Stop") { research.cancel() }
                }
                Button("Clear") { research.clear() }
            }
            HStack(spacing: HUD.space4) {
                BeholderSourcePicker(selected: $research.selected)
                Spacer()
                Button("Export case…") { prepareExport() }.disabled(research.findings.isEmpty || research.searching)
            }
            Text(preview).font(.caption).foregroundStyle(HUD.inkMuted).textSelection(.enabled)
            if let problem = research.problem ?? exportProblem {
                Text(problem).foregroundStyle(HUD.warn)
            }
            Divider()
            if research.findings.isEmpty {
                VStack(spacing: HUD.space4) {
                    BeholderEmblem().frame(width: 150, height: 150).opacity(0.6)
                    Text("One handle. Several public sources.").font(.title3)
                    Text("Choose sources and start a search. Accounts stay separate until you verify who owns them.")
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
                    LazyVGrid(
                        columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                        alignment: .leading,
                        spacing: HUD.space4
                    ) {
                        ForEach(research.findings) { finding in card(finding) }
                    }
                }
            }
            Text("A matching handle is not a verified identity. No public result does not prove an account is absent.")
                .font(.caption).foregroundStyle(HUD.inkMuted)
        }
        .foregroundStyle(HUD.ink).padding(HUD.space4)
        .environment(\.hudTheme, theme)
        .onDisappear { research.cancel() }
        .onChange(of: HUDPresence.shared.open) { _, open in
            if followsPanel, !open {
                research.cancel()
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Beholder-case") { result in
            if case .failure = result {
                exportProblem = "The case could not be exported. Choose another destination and try again."
            }
        }
    }

    private var preview: String {
        let name = research.preparedUsername.map { "“\($0)”" } ?? "the username you enter"
        let hosts = research.providers.filter { research.preparedUsername.map($0.supports) ?? true }.map(\.host).joined(separator: ", ")
        return "Search sends only \(name) to: \(hosts.isEmpty ? "no compatible sources selected" : hosts). "
            + "Providers receive your IP address and the Aegis-Beholder/1.0 app identifier."
    }

    private func card(_ finding: BeholderFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(finding.provider.title).font(.headline)
                Spacer()
                Text(finding.status.title).font(.caption)
                    .foregroundStyle(finding.status == .candidate ? HUD.primary : HUD.inkMuted)
            }
            ForEach(finding.fields.keys.sorted(), id: \.self) { label in
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased()).font(.caption2).foregroundStyle(HUD.inkMuted)
                    Text(verbatim: finding.fields[label] ?? "").textSelection(.enabled)
                }
            }
            if let checked = finding.checkedAt {
                Text("Checked " + checked.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(HUD.inkMuted)
            }
            if let source = finding.sourceURL {
                Text(verbatim: source.absoluteString).font(.caption2).foregroundStyle(HUD.inkMuted).textSelection(.enabled)
            }
            if finding.status == .candidate, let url = finding.provider.profileURL(research.username) {
                Link("Open public profile ↗", destination: url).font(.caption)
                    .help("Opens your browser; the website receives the visit under your browser's settings.")
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
        } catch { exportProblem = "The case could not be prepared for export." }
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
