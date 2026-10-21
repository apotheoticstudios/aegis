import AppKit
import SwiftUI

/// The panel's World screen (#299): God's Eye View's own interface, with Aegis as its voice (#311). Its voice button
/// starts Aegis listening, and the question and answer show in God's Eye View's own voice card.
struct WorldScreen: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button("◀ AEGIS") { WorldWindow.shared.close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(BriefView.cyan)
                    .help("Back to Aegis")
                Text("WORLD").foregroundStyle(BriefView.cyan)
                Spacer()
            }
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .padding(.leading, 80).padding(.trailing, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            WorldPanelView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: caption, initial: true) { _, lines in
            WorldWindow.shared.showCaption(question: lines[0], answer: lines[1])
        }
    }

    /// What the owner said and what Aegis answered (or is doing), for the voice card.
    private var caption: [String] {
        if case let .listening(words) = model.voice.state {
            return [words, "Listening…"]
        }
        return switch model.askState {
        case let .asking(question): [question, model.partialAnswer.isEmpty ? "Thinking…" : model.partialAnswer]
        case let .answered(question, answer): [question, answer.text]
        case let .failed(question, message): [question, message]
        case .idle: ["", ""]
        }
    }
}

/// Hosts the session's existing web view. Switching screens never prepares or reloads the globe.
struct WorldPanelView: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        WorldWindow.shared.present(in: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator _: ()) {
        view.subviews.forEach { $0.removeFromSuperview() }
    }
}
