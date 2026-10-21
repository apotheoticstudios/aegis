import SwiftUI

/// The boot screen (the design system's BootScreen), shown only while the panel waits for AegisCore's first answer:
/// PROJECT: AEGIS in block characters, the emblem in characters and the start-up line.
struct BootScreen: View {
    let model: PanelModel
    @State private var banner: [String] = []
    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space8) {
            VStack(alignment: .leading, spacing: HUD.space4) {
                HUDAsciiText(lines: banner, cols: banner.map(\.count).max() ?? 0, size: 4.5, tone: HUD.ink, blocks: true)
                    .accessibilityLabel("Project: Aegis")
                HUDAsciiDivider(label: "Boot sequence", width: 120, tone: HUD.primary)
            }
            HStack(alignment: .top, spacing: HUD.space12) {
                HUDAsciiText(lines: Self.emblem, cols: Self.emblem.map(\.count).max() ?? 0, size: 7)
                    .accessibilityLabel("The Aegis emblem")
                TimelineView(.periodic(from: started, by: 0.1)) { context in
                    let elapsed = context.date.timeIntervalSince(started)
                    (Text(String(format: "[%05.2f] ", elapsed)) + Text("..")
                        .foregroundStyle(HUD.primary) + Text("  connecting to aegis core"))
                        .hudType(.term)
                        .foregroundStyle(HUD.inkMuted)
                }
            }
        }
        .padding(.horizontal, HUD.space12)
        .padding(.vertical, HUD.space8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { banner = HUDBanner.lines("Project: Aegis", rows: 5, block: true) }
    }

    /// The emblem in characters, from the design system's Ascii kit.
    private static let emblem = (Bundle.main.url(forResource: "emblem", withExtension: "txt", subdirectory: "Brand")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
        .components(separatedBy: .newlines)
}
