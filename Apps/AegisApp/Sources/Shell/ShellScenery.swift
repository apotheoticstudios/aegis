import AegisKit
import SwiftUI

/// The scenery drawn round AegisShell's readings: the ground, each workspace's art, the world rising out of the corner
/// with the weather, and home's floor plan.
struct ShellScenery: View {
    let shell: ShellController
    let geometry: ShellGeometry
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    private var still: Bool {
        shell.still != nil
    }

    private var hidden: Bool {
        shell.hideDetails
    }

    private var readings: ShellController.Readings {
        shell.readings
    }

    var body: some View {
        mood
    }

    /// Each workspace's own art behind the core: Focus flies down a ringed tunnel, Evening has a ringed planet and a
    /// night skyline along the ground, Movie a black hole barely there.
    @ViewBuilder var mood: some View {
        let scale = geometry.scale, centre = geometry.centre
        switch shell.workspace {
        case .work:
            EmptyView()
        case .focus:
            HUDAsciiArt(shape: .tunnel, cols: Int(105 * scale), rows: Int(52.5 * scale), grit: 0.1, tone: HUD.primary, animate: !still)
                .opacity(0.38)
                .position(centre)
        case .evening:
            HUDAsciiArt(
                shape: .city,
                cols: Int(geometry.size.width / 6),
                rows: Int(18 * scale),
                grit: 0.1,
                tone: HUD.accent,
                animate: !still
            )
            .opacity(0.4)
            .frame(width: 0, height: 0, alignment: .topLeading)
            .position(x: 0, y: geometry.size.height - 110 * scale)
            HUDAsciiArt(shape: .planet, cols: Int(50 * scale), rows: Int(25 * scale), tone: HUD.accent, label: "Planet", animate: !still)
                .frame(width: 0, height: 0, alignment: .topLeading)
                .position(x: geometry.size.width - (geometry.big ? 56 : 40) - 300 * scale, y: 60)
        case .movie:
            HUDAsciiArt(shape: .blackhole, cols: Int(66 * scale), rows: Int(33 * scale), grit: 0.1, tone: HUD.accent, animate: !still)
                .opacity(0.16)
                .position(centre)
        }
    }

    /// The wireframe floor rolling toward you under the core, fading in from its skyline; falling code in Matrix.
    var ground: some View {
        let scale = geometry.scale
        return HUDAsciiArt(
            shape: theme == .matrix ? .rain : .horizon, cols: Int(120 * scale), rows: Int(17 * scale), grit: theme == .matrix ? 0.05 : 0.1,
            tone: HUD.primary, animate: !still
        )
        .opacity(theme == .matrix ? 0.45 : 0.4)
        .mask(LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)],
            startPoint: .top,
            endPoint: .bottom
        ))
        .position(x: geometry.centre.x, y: geometry.size.height - 104 * scale + CGFloat(Int(17 * scale)) * 12 / 2)
        .allowsHitTesting(false)
    }

    // MARK: - The world, rising out of the corner, with the weather above it

    var world: some View {
        let scale = geometry.scale, cols = geometry.big ? 84 : 56, side = CGFloat(cols * 6)
        let corner = CGPoint(x: geometry.size.width - side * 0.78 - 16 * scale, y: geometry.size.height - side * 0.66)
        let weather = readings.weather.map(ShellWeather.init)
        return ZStack(alignment: .topLeading) {
            HUDAsciiArt(shape: .globe, cols: cols, rows: cols / 2, grit: 0.22, tone: HUD.primary, label: "Globe", animate: !still)
                .opacity(0.85)
                .overlay {
                    if WorldHome.point != nil {
                        ShellPin(text: hidden ? "Home" : WorldWindow.homeCity ?? "Home", note: weather?.temperature)
                            .position(x: side * 0.5, y: side * 0.3)
                    }
                }
                .frame(width: 0, height: 0, alignment: .topLeading)
                .position(corner)
            if let weather {
                VStack(alignment: .leading, spacing: 6) {
                    HUDAsciiArt(
                        shape: weather.stormy ? .storm : .sun, cols: geometry.big ? 22 : 16, rows: geometry.big ? 11 : 8,
                        tone: weather.stormy ? HUD.primary : HUD.accent, animate: !still
                    )
                    Text(weather.headline).hudCaps(10, tracking: 0.2).foregroundStyle(weather.stormy ? HUD.warn : HUD.primary).fixedSize()
                    Text(weather.detail).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
                        .frame(width: 220 * scale, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 0, height: 0, alignment: .topLeading)
                .position(x: geometry.size.width - 250 * scale, y: corner.y - 140 * scale)
            }
        }
    }

    // MARK: - Home: the floor plan (Home control isn't built yet)

    var home: some View {
        let cols = geometry.big ? 92 : 64, rows = geometry.big ? 26 : 18, x = geometry.big ? 56.0 : 40
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Rectangle().fill(HUD.primary).frame(width: 4, height: 4).hudGlow()
                Text("Home").hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                Text("not set up").font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
            }
            HUDAsciiArt(shape: .floorplan, cols: cols, rows: rows, grit: 0.08, tone: HUD.inkMuted, label: "Home floor plan", animate: false)
                .opacity(0.45)
                .overlay {
                    // Printed into the art: the characters under the words are cleared, as the design's marks do.
                    VStack(spacing: 2) {
                        Text("Home control isn't set up yet").font(.custom(HUDType.body.fontName, size: 12)).foregroundStyle(HUD.inkMuted)
                        Text("It arrives with Home control").font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HUD.void)
                }
        }
        .fixedSize()
        .frame(width: 0, height: 0, alignment: .topLeading)
        .position(x: x, y: geometry.size.height - (geometry.big ? 360 : 300) - 22)
    }
}

/// A place pinned on the globe: a glowing mark, its name and a note.
private struct ShellPin: View {
    let text: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle().fill(HUD.primary).frame(width: 5, height: 5).rotationEffect(.degrees(45)).hudGlow()
            Text(text).font(.custom(HUDType.body.fontName, size: 12)).foregroundStyle(HUD.ink)
            if let note {
                Text(note).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
            }
        }
        .fixedSize()
        .padding(.horizontal, 4)
        .background(HUD.void.opacity(0.6))
    }
}
