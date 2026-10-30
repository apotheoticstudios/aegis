import AegisKit
import AppKit
import SwiftUI

/// The HUD panel, laid out as the Project: Aegis design system draws it (ADR-0029): one glass shell with the AEGIS
/// top bar and the menu. HOME is the overview, SYSTEM the Mac's
/// diagnostics, COMMS everything collected, CHAT the conversation, LOGS what Aegis did and remembers, BEHOLDER public research.
struct BriefView: View {
    let model: PanelModel
    @State private var screen = HUDScreen.home
    /// The owner's theme, chosen in setup (#28).
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        Group {
            if WorldPresence.shared.inPanel {
                WorldScreen(model: model)
            } else if case .loading = model.phase {
                BootScreen(model: model)
            } else {
                HUDFit { current }
            }
        }
        .frame(minWidth: 1120, minHeight: 700)
        .hudType(.body)
        .foregroundStyle(HUD.ink)
        // The HUD's frame is the window's edge: inset by its stroke so the corner brackets draw whole, and clipped
        // to its cut corners so nothing shows outside them.
        .padding(HUD.strokeFrame)
        .background(HUDGround())
        .clipShape(HUDCut(kind: .panel, cut: HUD.chamferLg))
        .environment(\.colorScheme, .dark)
        .environment(\.hudTheme, theme)
        // A question in progress, or the voice listening, belongs on CHAT.
        .onChange(of: model.askState) { _, state in
            if case .asking = state {
                screen = .chat
            }
        }
        // "Hey Aegis" opens on CHAT, where the conversation shows.
        .onChange(of: model.voice.wakes) { screen = .chat }
        .onChange(of: model.voice.isListening) { _, listening in
            if listening {
                screen = .chat
            }
        }
    }

    @ViewBuilder private var current: some View {
        switch screen {
        case .home: HomeScreen(model: model, screen: $screen)
        case .system: SystemScreen(model: model, screen: $screen)
        case .comms: CommsScreen(model: model, screen: $screen)
        case .chat: ChatScreen(model: model, screen: $screen)
        case .logs: LogsScreen(model: model, screen: $screen)
        case .beholder: BeholderScreen(model: model, screen: $screen)
        }
    }
}

/// Lays a screen out at least `height` tall and scales it down to the window, so a screen taller than the panel
/// shows whole, slightly smaller, instead of cut off.
struct HUDFit<Content: View>: View {
    var height: CGFloat = 860
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, proxy.size.height / height)
            content
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// The menu's sections, in order.
enum HUDScreen: Int, CaseIterable {
    case home, system, comms, chat, logs, beholder

    var title: String {
        switch self {
        case .home: "Home"
        case .system: "System"
        case .comms: "Comms"
        case .chat: "Chat"
        case .logs: "Logs"
        case .beholder: "Beholder"
        }
    }
}

/// The bar across the top of every screen: the emblem and the assistant's name drawn in characters, the menu, the
/// clock and one status word.
struct HUDTopBar: View {
    let model: PanelModel
    @Binding var screen: HUDScreen
    @State private var banner: [String] = []

    var body: some View {
        HStack(spacing: HUD.space3) {
            HUDEmblem(size: 34)
            // The name resolves out of ramp noise as the top bar arrives.
            HUDBuildClock(until: 0.8, fps: 12) { time in
                let lines = time.map { HUDMotion.resolve(banner, HUDMotion.progress($0, 0, 0.8), tick: Int($0 * 12), seed: 5) }
                HUDAsciiText(lines: lines ?? banner, cols: banner.map(\.count).max() ?? 0, size: 2.5, tone: HUD.primary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(model.personality.name)
        .task(id: model.personality.name) {
            banner = HUDBanner.lines(model.personality.name, rows: 10)
        }
        Spacer(minLength: HUD.space4)
        HUDMenuTabs(
            items: HUDScreen.allCases.map(\.title),
            active: Binding(get: { screen.rawValue }, set: { screen = HUDScreen(rawValue: $0) ?? .home })
        )
        Spacer(minLength: HUD.space4)
        HStack(spacing: HUD.space4) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.custom(HUDType.title.fontName, size: 22)).tracking(0.88).foregroundStyle(HUD.ink)
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                        .hudType(.data).foregroundStyle(HUD.inkMuted)
                }
                .lineLimit(1)
            }
            if model.isSample {
                HUDTag(word: "Sample", tone: HUD.warn).help("Synthetic sample data, not your day")
            }
            HUDTag(word: status.word, tone: status.tone)
        }
    }

    /// One word from the status vocabulary; what Aegis is doing now wins.
    private var status: (word: String, tone: HUDColor) {
        if model.voice.isListening {
            return ("Listening", HUD.primary)
        }
        if model.voice.speaking {
            return ("Speaking", HUD.primary)
        }
        if case .asking = model.askState {
            return (model.handingOff.map { "Via " + $0.name } ?? "Thinking", HUD.primary)
        }
        if model.writing {
            return ("Writing", HUD.primary)
        }
        if case .unavailable = model.phase {
            return ("Offline", HUD.critical)
        }
        return model.health.isEmpty ? ("Online", HUD.ok) : ("Degraded", HUD.warn)
    }
}

/// The Aegis emblem from the design system's logo kit; it keeps its own colours in every theme.
struct HUDEmblem: View {
    let size: CGFloat

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        }
    }

    private static let image = Bundle.main.url(forResource: "aegis-emblem", withExtension: "png", subdirectory: "Brand")
        .flatMap(NSImage.init(contentsOf:))
}

/// The reactor's state as one word, for its caption and the status tag.
extension PanelModel {
    var reactorMode: ReactorView.Mode {
        if voice.isListening {
            return .listening
        }
        if voice.speaking {
            return .speaking
        }
        if case .asking = askState {
            return .thinking
        }
        return writing ? .thinking : .idle
    }

    /// Aegis's name in the panel, as the owner chose it (#241).
    var assistant: String {
        personality.name.uppercased()
    }

    /// What needs the owner today: the brief's urgent and reply items.
    var needsYou: Int {
        stored?.brief.items.filter { $0.priority != .fyi }.count ?? 0
    }

    /// What Aegis says now: the latest answer, or the brief read as one short paragraph.
    var saying: String {
        switch askState {
        case let .answered(_, answer): return answer.text
        case let .failed(_, message): return message
        case .asking: return partialAnswer.isEmpty ? "…" : partialAnswer
        case .idle: break
        }
        if case let .unavailable(reason) = phase {
            return reason
        }
        return stored.map { BriefPresentation.spoken($0.brief, now: Date(), calendar: .current) } ?? ""
    }
}

extension ReactorView.Mode {
    var word: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Think"
        case .listening: "Listen"
        case .speaking: "Speak"
        }
    }
}

/// The reactor at a screen's centre, with its caption: a label, a value in Xirod and its state.
struct HUDCore: View {
    let model: PanelModel
    var size: CGFloat = 300
    var label = "Needs you"
    var value: String?

    var body: some View {
        VStack(spacing: HUD.space2) {
            ReactorView(mode: model.reactorMode, size: size).hudHub()
            HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                Text(label).hudType(.label).foregroundStyle(HUD.inkMuted)
                if let value {
                    Text(value).font(.custom(HUDType.title.fontName, size: 22)).tracking(0.44).foregroundStyle(HUD.ink).hudGlow()
                }
                Text(model.reactorMode.word).hudType(.label).foregroundStyle(HUD.primary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
        // The reactor and its caption flicker on at 480 ms, whatever column they sit in.
        .hudArrive(.flicker(0.42), after: 0.48)
        .environment(\.hudArrival.at, 0)
    }
}
