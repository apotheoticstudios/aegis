import SwiftUI

/// The HUD's look (concept A, #292): frosted glass with hard edges and corner brackets over a near-black grid with
/// soft coloured glows for the glass to blur.
extension View {
    /// A frosted-glass panel; `lifted` adds the very slight shadow the side panels have.
    func hudPanel(lifted: Bool = true) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(
                colors: [.white.opacity(0.10), .white.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .background(.ultraThinMaterial)
            // Drawn behind the glass so the text casts no shadow of its own.
            .background(Rectangle().fill(.black.opacity(lifted ? 0.3 : 0)).blur(radius: 12).offset(y: 6))
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.22)).frame(height: 1) }
            .overlay(Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .overlay(HUDBrackets().stroke(BriefView.cyan, lineWidth: 2))
    }
}

/// Corner brackets, top left and bottom right.
struct HUDBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 14
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        return path
    }
}

/// A rectangle with two cut corners, for the Ask bar and chips.
struct HUDChamfer: Shape {
    var cut: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
            path.closeSubpath()
        }
    }
}

/// Near-black with a faint 32-point grid and three blurred glows: cyan, violet and amber.
struct HUDBackdrop: View {
    var body: some View {
        Color(red: 0.008, green: 0.024, blue: 0.043)
            .overlay {
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 0, through: size.width, by: 32) {
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: 0, through: size.height, by: 32) {
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(BriefView.cyan.opacity(0.045)), lineWidth: 1)
                }
            }
            .overlay(alignment: .leading) { glow(BriefView.cyan.opacity(0.28)).offset(x: -160) }
            .overlay(alignment: .topTrailing) { glow(Color(red: 0.47, green: 0.43, blue: 1).opacity(0.2)).offset(x: 120, y: -120) }
            .overlay(alignment: .bottom) { glow(Color(red: 0.96, green: 0.69, blue: 0.25).opacity(0.14)).offset(x: 200, y: 220) }
            .clipped()
    }

    private func glow(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 520, height: 520).blur(radius: 120)
    }
}
