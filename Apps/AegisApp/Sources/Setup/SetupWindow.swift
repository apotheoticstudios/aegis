import AegisKit
import AppKit
import SwiftUI

/// The setup wizard on screen (#26): AegisKit's wizard, saved after every change so setup resumes where it stopped.
@MainActor @Observable
final class SetupModel {
    var wizard: SetupWizard {
        didSet { save() }
    }

    /// Laptop or desktop as this Mac reports it, before any correction: the Segmented marks it "detected".
    let detectedLaptop: Bool
    /// A text field has the keyboard, so Return belongs to it rather than to Next.
    var typing = false
    private let file: SetupFile?

    init(file: SetupFile? = SetupModel.standardFile, mac: MacProfile = .detect()) {
        self.file = file
        detectedLaptop = mac.isLaptop
        var wizard = (try? file?.load()) ?? SetupWizard(mac: mac)
        // Free space changes between runs; the rest was detected (or corrected by the owner) before.
        wizard.mac.diskFreeBytes = mac.diskFreeBytes
        self.wizard = wizard
    }

    /// Setup has been finished once on this Mac.
    static var finished: Bool {
        (try? standardFile?.load())?.finished == true
    }

    /// `~/Library/Application Support/Aegis/setup.json`, beside AegisCore's files.
    static let standardFile: SetupFile? = {
        guard let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Aegis", isDirectory: true),
            (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        return SetupFile(url: folder.appendingPathComponent("setup.json"))
    }()

    /// A choice the design adds for a feature not built yet, kept with the answers (#65): `recommended` until changed.
    func option(_ key: String, _ recommended: String) -> Binding<String> {
        Binding(get: { self.wizard.answers[option: key] ?? recommended }, set: { value in
            self.wizard.answers[option: key] = value == recommended ? nil : value
        })
    }

    /// An on/off choice, as `option`.
    func flag(_ key: String, _ recommended: Bool) -> Binding<Bool> {
        Binding(get: { self.wizard.answers[option: key].map { $0 == "on" } ?? recommended }, set: { on in
            self.wizard.answers[option: key] = on == recommended ? nil : on ? "on" : "off"
        })
    }

    /// A list choice (never-read apps, people), one entry per line.
    func list(_ key: String, _ recommended: [String]) -> Binding<[String]> {
        Binding(get: { self.wizard.answers[option: key].map { $0.split(separator: "\n").map(String.init) } ?? recommended }, set: { list in
            self.wizard.answers[option: key] = list == recommended ? nil : list.joined(separator: "\n")
        })
    }

    private func save() {
        // shortcut: an unwritable file only loses progress (setup starts again next launch), so it isn't reported.
        try? file?.save(wizard)
    }
}

/// The wizard's window: 1360 × 860 like the design, at the normal window level so System Settings can come in front
/// of it while the owner grants access.
@MainActor
enum SetupWindow {
    private(set) static var window: NSWindow?
    static let size = CGSize(width: 1360, height: 860)

    /// Shows setup where it stopped, or from the start when `again` (from the menu) and it was finished before; `done`
    /// runs when it finishes.
    static func show(_ app: SetupApp, again: Bool, setup: SetupModel = SetupModel(), done: @escaping () -> Void) {
        // Closed halfway (Escape), it resumes there rather than starting over.
        if again, setup.wizard.finished {
            setup.wizard.restart()
        }
        let created = window ?? HUDWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true
        )
        created.isReleasedWhenClosed = false
        // A panel hides when Aegis isn't active; the wizard stays while the owner is in System Settings.
        created.hidesOnDeactivate = false
        created.isMovableByWindowBackground = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.contentView = NSHostingView(rootView: SetupView(
            setup: setup,
            app: app,
            finish: {
                let minutes = setup.wizard.briefMinutes
                Task { _ = await app.model.service.handle(.setBriefTime(minutes: minutes)) }
                close()
                done()
            },
            later: close
        ))
        window = created
        // The models download in the background while the owner goes through the steps (ADR-0030).
        ModelDownloads.shared.start()
        HUDPresence.shared.setup = true
        NSApp.activate()
        created.center()
        created.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
        HUDPresence.shared.setup = false
    }
}

/// The wizard (the design's WizardShell): the brand, step count and download meter along the top; the numbered step
/// rail on the left; the step's code, title, intro and content in the middle, at a fixed height so the window never
/// changes size; Back, progress, Use recommended and Next along the bottom.
struct SetupView: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    let finish: () -> Void
    let later: () -> Void
    @State private var tuning = false
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        let wizard = setup.wizard
        HUDShell {
            SetupTopBar(position: wizard.position, count: wizard.steps.count)
        } content: {
            HStack(alignment: .top, spacing: HUD.space8) {
                SetupRail(setup: setup).frame(width: 200)
                VStack(alignment: .leading, spacing: 0) {
                    SetupHeading(step: wizard.current, position: wizard.position)
                    ScrollView(.vertical) {
                        SetupScreen(setup: setup, app: app, tuning: $tuning)
                            .padding(.top, HUD.space6)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: 554)
                    .id(wizard.current)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(.timingCurve(0.05, 0.7, 0.1, 1, duration: 0.26), value: wizard.current)
        } bottom: {
            SetupNav(setup: setup, tuning: tuning, finish: finish)
        }
        .padding(HUD.space3)
        .frame(width: SetupWindow.size.width, height: SetupWindow.size.height)
        .background(HUDGround())
        .hudType(.body)
        .foregroundStyle(HUD.ink)
        .environment(\.colorScheme, .dark)
        .environment(\.hudTheme, theme)
        // Escape closes setup, whatever has the keyboard; it resumes on this step next time.
        .background {
            Button("Close setup", action: later).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }
}

/// The top bar: the emblem and the name in characters with SETUP after it, the step count in the middle and the
/// background model download on the right.
private struct SetupTopBar: View {
    let position: Int
    let count: Int
    @State private var banner: [String] = []

    var body: some View {
        HStack(spacing: HUD.space3) {
            if let emblem = SetupBrand.emblem {
                Image(nsImage: emblem).resizable().interpolation(.high).frame(width: 30, height: 30)
                    .accessibilityLabel("Aegis")
            }
            HUDAsciiText(lines: banner, cols: banner.map(\.count).max() ?? 0, size: 2.5, tone: HUD.primary)
            Text("Setup").hudCaps(11, tracking: 0.22).foregroundStyle(HUD.primary).hudGlow()
                .padding(.leading, HUD.space3)
                .overlay(alignment: .leading) { Rectangle().fill(HUD.glassEdge).frame(width: 1, height: 16) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { banner = HUDBanner.lines("Aegis", rows: 10) }
        (Text("Step ") + Text("\(position + 1)").foregroundStyle(HUD.ink) + Text(" of \(count)"))
            .font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
            .fixedSize()
        SetupDownloads()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The models downloading in the background, on every step (DESIGN.md "Wizard rules"); Retry if it stopped.
private struct SetupDownloads: View {
    var body: some View {
        let downloads = ModelDownloads.shared
        HStack(spacing: HUD.space4) {
            switch downloads.state {
            case .ready:
                HUDMeter(label: "Models ready", value: 1, display: SetupText.gigabytes(downloads), size: .small, tone: HUD.ok, segments: 32)
                    .frame(width: 270)
            case .failed:
                HUDMeter(
                    label: "Download stopped",
                    value: downloads.fraction,
                    display: SetupText.gigabytes(downloads),
                    size: .small,
                    tone: HUD.warn,
                    segments: 32
                )
                .frame(width: 270)
                Button("Retry") { ModelDownloads.shared.start() }.buttonStyle(HUDPlateStyle(compact: true))
            case .idle, .downloading:
                HUDMeter(
                    label: "Downloading",
                    value: downloads.fraction,
                    display: SetupText.gigabytes(downloads),
                    size: .small,
                    segments: 32
                )
                .frame(width: 270)
            }
        }
    }
}

/// The numbered steps: done ones ticked, the current one lit, any step already reached clickable.
private struct SetupRail: View {
    @Bindable var setup: SetupModel
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let wizard = setup.wizard
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(wizard.steps.enumerated()), id: \.offset) { index, step in
                let current = index == wizard.position
                let reached = index <= wizard.reachedPosition
                Button { setup.wizard.go(to: index) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                        Text(String(format: "%02d", index + 1)).font(HUDFace.mono(10))
                            .foregroundStyle(current ? HUD.primary : HUD.inkMuted)
                        Text(step.label).hudCaps(10, tracking: 0.16)
                            .foregroundStyle(current || reached ? HUD.ink : HUD.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index < wizard.position {
                            Text("✓").font(HUDFace.mono(11)).foregroundStyle(HUD.ok).accessibilityLabel("done")
                        }
                    }
                    .lineLimit(1)
                    .padding(.vertical, 5)
                    .padding(.horizontal, HUD.space3)
                    .background {
                        if current {
                            LinearGradient(colors: [theme.color(.primarySoft), .clear], startPoint: .leading, endPoint: .trailing)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if current {
                            Rectangle().fill(HUD.primary).frame(width: 2).hudGlow().offset(x: -1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SetupRailStyle())
                .disabled(current || !reached)
                .accessibilityAddTraits(current ? [.isSelected] : [])
            }
        }
        .overlay(alignment: .leading) { Rectangle().fill(HUD.glassEdge).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
    }
}

private struct SetupRailStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SetupRailRow(configuration: configuration)
    }
}

private struct SetupRailRow: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background {
                if enabled, hovering {
                    Rectangle().fill(HUD.surfaceRaised)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// The step's code, its title in Xirod and its one-line intro, over a hairline.
private struct SetupHeading: View {
    let step: SetupStep
    let position: Int

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            Text(String(format: "%02d / ", position + 1) + step.label.uppercased()).font(HUDFace.mono(11)).foregroundStyle(HUD.primary)
            Text(step.title.uppercased()).font(HUDFace.hero(22)).tracking(0.88).foregroundStyle(HUD.ink)
            Text(step.intro).font(HUDFace.text(12)).foregroundStyle(HUD.inkMuted).frame(maxWidth: 800, alignment: .leading)
        }
        .padding(.bottom, HUD.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
    }
}

/// Back, the progress meter, Use recommended and Next (Start on the first step, Open Aegis on the last).
private struct SetupNav: View {
    @Bindable var setup: SetupModel
    let tuning: Bool
    let finish: () -> Void

    var body: some View {
        let wizard = setup.wizard
        let count = wizard.steps.count
        let last = wizard.position == count - 1
        HStack(spacing: HUD.space6) {
            if wizard.canGoBack {
                Button("Back") { setup.wizard.back() }.buttonStyle(HUDPlateStyle())
            }
            HUDMeter(
                label: wizard.current.label, value: Double(wizard.position + 1) / Double(count),
                display: String(format: "%02d / %02d", wizard.position + 1, count), size: .small, segments: count * 3
            )
            if wizard.position < (wizard.steps.firstIndex(of: .tuneUp) ?? count - 1) {
                Button(wizard.position == 0 ? "Use recommended for everything" : "Use recommended for the rest") {
                    setup.wizard.useRecommendedForRest()
                }
                .buttonStyle(HUDPlateStyle())
            }
            Button(wizard.position == 0 ? "Start" : last ? "Open Aegis" : "Next") {
                setup.wizard.next()
                if last {
                    finish()
                }
            }
            .buttonStyle(HUDPlateStyle(kind: .primary))
            .keyboardShortcut(setup.typing ? nil : .defaultAction)
            .disabled(wizard.current == .tuneUp && tuning)
            .help(wizard.current == .tuneUp && tuning ? "Finishing the tune-up" : "")
        }
    }
}

/// What the wizard's screens change in the running app: the panel's model, the wake listener and the shortcut.
struct SetupApp {
    let model: PanelModel
    let wake: WakeListener
    let hotKey: String?
}

/// The logo kit's emblem (Resources/Brand).
enum SetupBrand {
    static let emblem = Bundle.main.url(forResource: "aegis-emblem", withExtension: "png", subdirectory: "Brand")
        .flatMap(NSImage.init(contentsOf:))
}

extension SetupStep {
    /// The name on the rail.
    var label: String {
        switch self {
        case .welcome: "Welcome"
        case .mac: "Your Mac"
        case .storage: "Storage"
        case .schedule: "Schedule"
        case .permissions: "Permissions"
        case .sources: "Sources"
        case .home: "Home"
        case .control: "Control"
        case .addons: "Addons"
        case .privacy: "Privacy"
        case .personality: "Personality"
        case .voice: "Voice"
        case .interface: "Interface"
        case .silence: "Silence"
        case .tuneUp: "Tune-up"
        case .ready: "Ready"
        }
    }

    /// The step's title, in Xirod above its intro.
    var title: String {
        self == .silence ? "Silence and alerts" : label
    }

    /// One line on what the step is for.
    var intro: String {
        switch self {
        case .welcome: "Aegis is a private assistant that lives on this Mac. Setup takes a few minutes."
        case .mac: "Found automatically. It decides which models and voices fit."
        case .storage: "How much space Aegis may use. Models, memory, voice and addons all live inside it."
        case .schedule: "When your brief should be ready, and when Aegis should keep still."
        case .permissions: "macOS keeps each kind of data behind its own permission. Grant them once."
        case .sources: "What Aegis reads, all found on this Mac. Turn off anything it should ignore."
        case .home: "Your Apple Home, through the hubs you already have."
        case .control: "Aegis acts only when you ask. Choose which apps it may operate, and how careful it is."
        case .addons: "Separate apps built to work with Aegis. Tick what to download; only the monitor is suggested."
        case .privacy: "What Aegis must never read. It reads everything else, and keeps all of it here."
        case .personality: "How Aegis talks to you. Tone only: it knows the same things in every style."
        case .voice: "How Aegis sounds while the panel is open."
        case .interface: "How you open the panel, how it looks, and AegisShell."
        case .silence: "Aegis is silent while the panel is closed. Choose the few exceptions."
        case .tuneUp: "A 30-second test on this Mac picks the final model size and compression."
        case .ready: "Everything is set. You can change any of it later, or run setup again from settings."
        }
    }
}
