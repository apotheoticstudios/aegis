import AegisKit
import AppKit
import SwiftUI

/// The wizard's sixteen screens (the design system's WizStep01–16), each one category with the recommended answer
/// already chosen. What Aegis can already read or do comes from the running app; choices for features not built yet
/// are kept with the answers (#65).
struct SetupScreen: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    @Binding var tuning: Bool

    var body: some View {
        switch setup.wizard.current {
        case .welcome: WelcomeScreen()
        case .mac: MacScreen(setup: setup)
        case .storage: StorageScreen(setup: setup)
        case .schedule: ScheduleScreen(setup: setup)
        case .permissions: PermissionsScreen()
        case .sources: SourcesScreen(setup: setup, model: app.model)
        case .home: HomeScreenStep(setup: setup)
        case .control: ControlScreen(setup: setup)
        case .addons: AddonsScreen(setup: setup)
        case .privacy: PrivacyScreen(setup: setup)
        case .personality: PersonalityScreen(setup: setup, model: app.model)
        case .voice: VoiceScreen(setup: setup, app: app)
        case .interface: InterfaceScreen(setup: setup, app: app)
        case .silence: SilenceScreen(setup: setup, model: app.model)
        case .tuneUp: TuneUpScreen(app: app, tuning: $tuning)
        case .ready: ReadyScreen(setup: setup, app: app)
        }
    }
}

// MARK: - Layout

/// The design's step grids: the main column with a 330-point side column, a 340-point lead column before the main
/// one, or two halves; 32 points between.
struct SetupColumns<Main: View, Side: View>: View {
    enum Kind {
        case side, lead, halves
    }

    var kind = Kind.side
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side

    var body: some View {
        HStack(alignment: .top, spacing: HUD.space8) {
            switch kind {
            case .side:
                column { main }
                column { side }.frame(width: 330)
            case .lead:
                column { side }.frame(width: 340)
                column { main }
            case .halves:
                column { main }
                column { side }
            }
        }
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A centred stack in a side column: art over its caption.
struct SetupCentre<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: HUD.space3) { content }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
}

/// A muted `// note` in mono.
struct SetupNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text("// " + text).font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sentence in the text face, muted; `strong` runs are set in ink.
struct SetupParagraph: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    init(_ plain: String) {
        text = Text(plain)
    }

    var body: some View {
        text.font(HUDFace.text(12)).foregroundStyle(HUD.inkMuted).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 01 Welcome

private struct WelcomeScreen: View {
    @State private var banner: [String] = []

    var body: some View {
        SetupColumns(kind: .lead) {
            HUDAsciiText(lines: banner, cols: banner.map(\.count).max() ?? 0, size: 6, tone: HUD.primary)
                .hudBloom()
                .accessibilityLabel("Aegis")
                .task { banner = HUDBanner.lines("Aegis", rows: 14) }
            Spacer().frame(height: HUD.space3)
            ForEach(Self.principles, id: \.0) { code, title, text in
                HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                    Text(code).font(HUDFace.mono(11)).foregroundStyle(HUD.primary).frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).hudCaps(11, tracking: 0.16).foregroundStyle(HUD.ink)
                        Text(text).font(HUDFace.text(12)).foregroundStyle(HUD.inkMuted).lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, HUD.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
            }
            SetupNote("Every step is already filled in with the recommended answer. Models start downloading now, while you go through.")
                .padding(.top, HUD.space4)
        } side: {
            SetupCentre { HUDEmblemArt(cols: 56, label: "The Aegis emblem") }
        }
    }

    private static let principles = [
        (
            "01",
            "Local and private",
            "Everything Aegis reads and thinks stays on this Mac. Nothing goes to the cloud unless you hand a "
                + "question to Claude or ChatGPT yourself, and then only your own words."
        ),
        ("02", "Silent until opened", "No sounds, banners or pop-ups. It works in the background and speaks only when you open the panel."),
        ("03", "Thoughtless", "After setup you do nothing. It starts itself, looks after itself and learns as it goes."),
    ]
}

// MARK: - 02 Your Mac

private struct MacScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let mac = setup.wizard.mac
        let memory = Int(mac.memoryBytes >> 30)
        let used = 1 - Double(mac.diskFreeBytes) / Double(max(mac.diskTotalBytes, 1))
        SetupColumns {
            HUDTermSection(title: "Detected", rows: [
                .init(label: "Model", value: mac.model),
                .init(label: "Chip", value: mac.chip),
                .init(label: "Memory", value: "\(memory) GB"),
                .init(
                    label: "Storage",
                    value: "\(SetupText.gb(mac.diskFreeBytes)) GB free of \(SetupText.gb(mac.diskTotalBytes)) GB",
                    meter: used
                ),
                .init(label: "macOS", value: mac.systemVersion),
                .init(
                    label: "Apple AI",
                    value: mac.appleIntelligence ? "Apple Intelligence on" : "Apple Intelligence off",
                    tone: mac.appleIntelligence ? .ok : nil
                ),
            ])
            HUDSettingRow(label: "This Mac is a", hint: "Laptops pause heavy work on battery and catch up on wake.") {
                HUDSegmented(label: "Mac type", options: [
                    HUDOption(value: true, label: "Laptop", meta: setup.detectedLaptop ? "detected" : nil),
                    HUDOption(value: false, label: "Desktop", meta: setup.detectedLaptop ? nil : "detected"),
                ], value: $setup.wizard.mac.isLaptop)
            }
            SetupNote("Read from the Mac itself. Change something only if it’s wrong.").padding(.top, HUD.space3)
        } side: {
            SetupCentre {
                HUDAsciiArt(shape: .radar, cols: 34, rows: 17, tone: HUD.primary, label: "Hardware scan")
                HUDTag(word: "Scan complete", tone: HUD.ok)
                HStack(spacing: HUD.space8) {
                    HUDReadout(label: "Band", value: SetupText.band(setup.wizard).title, tone: HUD.primary)
                    HUDReadout(label: "Model", value: "~" + SetupText.parameters(.forMemory(mac.memoryBytes)), unit: "B")
                }
                .padding(.top, HUD.space2)
                SetupParagraph(Text("\(memory) GB").foregroundStyle(HUD.ink)
                    + Text(" of memory runs \(SetupText.model(.forMemory(mac.memoryBytes))) without swapping."))
            }
        }
    }
}

// MARK: - 03 Storage

private struct StorageScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let wizard = setup.wizard
        let range = wizard.mac.storageRange
        let free = Int(wizard.mac.diskFreeBytes / 1_000_000_000)
        let band = SetupText.band(wizard)
        SetupColumns {
            HUDRangeSlider(
                label: "Assigned to Aegis", value: $setup.wizard.storageGB, range: range, log: true,
                recommended: wizard.mac.recommendedStorageGB, warnFrom: free, ticks: 72,
                marks: [(range.lowerBound, "\(range.lowerBound) GB min")] + [50, 100, 250]
                    .filter { range.contains($0) && $0 < range.upperBound - 40 }
                    .map { ($0, "\($0)") } + [(range.upperBound, "\(range.upperBound) max")],
                hint: "From 20 GB to 75% of \(SetupText.volumeName) (\(free) GB free now). More buys a smarter model and a longer memory, "
                    + "never extra features."
            ) {
                Text("\(wizard.storageGB) GB").font(HUDFace.hero(26)).tracking(0.78).foregroundStyle(HUD.ink).hudGlow()
            }
            if wizard.storageExceedsFreeSpace {
                Text("More than the \(free) GB free right now. Aegis grows into it as space frees up.")
                    .font(HUDFace.text(11)).foregroundStyle(HUD.warn)
                    .padding(.vertical, HUD.space2).padding(.horizontal, HUD.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(HUD.warn, lineWidth: 1))
                    .padding(.top, HUD.space2)
            }
            HUDSubhead(title: "Model band", meta: "picked from your space and \(wizard.mac.memoryBytes >> 30) GB of memory")
            HStack(spacing: 0) {
                ForEach(SetupText.Band.allCases, id: \.self) { each in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(each.title).hudCaps(10, tracking: 0.18).foregroundStyle(each == band ? HUD.ink : HUD.inkMuted)
                        Text(each.reach).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
                    }
                    .padding(.vertical, HUD.space2).padding(.horizontal, HUD.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if each == band {
                            Rectangle().fill(HUD.primarySoft)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if each == band {
                            Rectangle().fill(HUD.primary).frame(height: 2)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if each != .lite {
                            Rectangle().fill(HUD.glassEdge).frame(width: 1)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(HUD.glassEdge, lineWidth: 1))
            HUDSubhead(title: "Where and how long")
            HUDSettingRow(label: "Drive") {
                HUDSegmented(label: "Drive", options: [
                    HUDOption(value: "internal", label: SetupText.volumeName),
                    HUDOption(value: "external", label: "External SSD", meta: "not connected", disabled: true),
                ], value: setup.option("drive", "internal"))
            }
            HUDSettingRow(
                label: "Full messages kept",
                hint: "Then they shrink to summaries and keywords. Summaries and important items stay forever."
            ) {
                HUDSegmented(label: "Keep full messages", options: [
                    HUDOption(value: "3", label: "3 mo"), HUDOption(value: "6", label: "6 mo"),
                    HUDOption(value: "12", label: "1 yr"), HUDOption(value: "24", label: "2 yr"),
                ], value: setup.option("keep", "12"), small: true)
            }
        } side: {
            StorageBudget(setup: setup)
        }
    }
}

/// What the assignment buys: a stacked bar and its breakdown, then the band's record.
private struct StorageBudget: View {
    @Bindable var setup: SetupModel
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let wizard = setup.wizard
        let parts = SetupText.budget(wizard)
        HUDSubhead(title: "What \(wizard.storageGB) GB buys", first: true)
        GeometryReader { proxy in
            let total = max(parts.map(\.gigabytes).reduce(0, +), 0.001)
            HStack(spacing: 2) {
                ForEach(parts, id: \.name) { part in
                    Rectangle().fill(theme.color(part.tone).opacity(part.tone == .frame ? 0.6 : 1))
                        .frame(width: max(2, (proxy.size.width - CGFloat(parts.count - 1) * 2) * part.gigabytes / total))
                }
            }
        }
        .frame(height: 6)
        .padding(.vertical, HUD.space2)
        .accessibilityHidden(true)
        Grid(alignment: .leading, horizontalSpacing: HUD.space2, verticalSpacing: 4) {
            ForEach(parts, id: \.name) { part in
                GridRow {
                    Rectangle().fill(theme.color(part.tone)).frame(width: 6, height: 6)
                    Text(part.name).foregroundStyle(HUD.inkMuted).frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.1f GB", part.gigabytes)).foregroundStyle(HUD.ink).gridColumnAlignment(.trailing)
                }
            }
        }
        .font(HUDFace.mono(11))
        Spacer().frame(height: HUD.space3)
        let keep = setup.option("keep", "12").wrappedValue
        HUDTermSection(title: SetupText.band(wizard).title, rows: [
            .init(label: "Brain", value: SetupText.model(.forMemory(wizard.mac.memoryBytes))),
            .init(label: "Voice", value: "Kokoro, on this Mac"),
            .init(label: "Memory", value: keep == "24" ? "2 years in full" : keep == "12" ? "1 year in full" : "\(keep) months in full"),
        ])
    }
}

// MARK: - 04 Schedule

private struct ScheduleScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let wizard = setup.wizard
        let quiet = setup.option("quiet", "focus")
        SetupColumns {
            HUDSettingRow(
                label: "This Mac runs",
                hint: wizard.alwaysOn ? "Aegis keeps working around the clock."
                    : "Aegis pauses while it sleeps and catches up on wake."
            ) {
                HUDSegmented(label: "Running mode", options: [
                    HUDOption(value: false, label: "As a laptop"), HUDOption(value: true, label: "Always on"),
                ], value: $setup.wizard.alwaysOn)
            }
            HUDSettingRow(
                label: "Wake-up time",
                hint: "Your brief is written before this, ready the moment you open the panel.",
                recommended: wizard.briefMinutes == 7 * 60
            ) {
                HStack(spacing: HUD.space2) {
                    SetupStepButton(symbol: "−", label: "15 minutes earlier") { move(by: -15) }
                    Text(SetupText.time(wizard.briefMinutes)).font(HUDFace.mono(16)).foregroundStyle(HUD.ink).frame(minWidth: 52)
                    SetupStepButton(symbol: "+", label: "15 minutes later") { move(by: 15) }
                }
            }
            HUDSettingRow(
                label: "Wake the Mac for the brief",
                hint: "Wakes this Mac shortly before \(SetupText.time(wizard.briefMinutes)) so the brief is ready even if it "
                    + "slept. macOS asks for your password once, in its own window; Aegis never sees it."
            ) {
                HUDToggle(on: $setup.wizard.wakeMacForBrief, label: "Wake the Mac for the brief")
            }
            HUDSettingRow(
                label: "Quiet hours",
                hint: quiet.wrappedValue == "focus"
                    ? "Follows your Focus modes, so Sleep and Do Not Disturb count." : "Nothing is written or tidied in these hours."
            ) {
                HUDSegmented(label: "Quiet hours", options: [
                    HUDOption(value: "focus", label: "Follow Focus"), HUDOption(
                        value: "hours",
                        label: SetupText.time(22 * 60) + "–" + SetupText.time(7 * 60)
                    ),
                ], value: quiet)
            }
        } side: {
            SetupCentre {
                ScheduleDial(minutes: wizard.briefMinutes, focus: quiet.wrappedValue == "focus")
                Grid(alignment: .leading, horizontalSpacing: HUD.space2, verticalSpacing: 4) {
                    GridRow {
                        Rectangle().fill(HUD.accent).frame(width: 6, height: 6)
                        Text("Brief written").foregroundStyle(HUD.inkMuted).frame(maxWidth: .infinity, alignment: .leading)
                        Text(SetupText.time(wizard.briefMinutes - 90) + "–" + SetupText.time(wizard.briefMinutes)).foregroundStyle(HUD.ink)
                    }
                    GridRow {
                        Rectangle().fill(HUD.inkMuted).frame(width: 6, height: 6)
                        Text("Quiet").foregroundStyle(HUD.inkMuted).frame(maxWidth: .infinity, alignment: .leading)
                        Text(quiet.wrappedValue == "focus" ? "Focus" : SetupText.time(22 * 60) + "–" + SetupText.time(7 * 60))
                            .foregroundStyle(HUD.ink)
                    }
                }
                .font(HUDFace.mono(11))
                .fixedSize()
            }
        }
    }

    private func move(by minutes: Int) {
        setup.wizard.briefMinutes = (setup.wizard.briefMinutes + minutes + 24 * 60) % (24 * 60)
    }
}

/// A square − or + beside a value.
struct SetupStepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(symbol).font(HUDFace.mono(13)).foregroundStyle(HUD.ink)
                .frame(width: 24, height: 24)
                .background(HUD.surface)
                .overlay(Rectangle().strokeBorder(HUD.frame, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The day as a dial: quarter-hour ticks, the quiet span, the hour and a half the brief is written in, and the
/// wake-up time with its hand.
private struct ScheduleDial: View {
    let minutes: Int
    let focus: Bool
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Canvas { context, _ in
            let centre = CGPoint(x: 110, y: 110)
            let radius: CGFloat = 92
            let point = { (minute: Double, distance: CGFloat) -> CGPoint in
                let angle = minute / 1440 * 2 * .pi - .pi / 2
                return CGPoint(x: centre.x + cos(angle) * distance, y: centre.y + sin(angle) * distance)
            }
            let arc = { (from: Double, to: Double, distance: CGFloat) -> Path in
                var path = Path()
                let start = from / 1440 * 360 - 90
                let span = (to - from + 1440).truncatingRemainder(dividingBy: 1440) / 1440 * 360
                path.addArc(
                    center: centre,
                    radius: distance,
                    startAngle: .degrees(start),
                    endAngle: .degrees(start + span),
                    clockwise: false
                )
                return path
            }
            context.stroke(Path(ellipseIn: CGRect(x: 18, y: 18, width: 184, height: 184)), with: .color(theme.color(.frame)))
            for tick in 0 ..< 96 {
                var mark = Path()
                mark.move(to: point(Double(tick * 15), radius))
                mark.addLine(to: point(Double(tick * 15), radius - (tick.isMultiple(of: 4) ? 7 : 3)))
                context.stroke(mark, with: .color(theme.color(.line)), lineWidth: tick.isMultiple(of: 4) ? 1 : 0.6)
            }
            for (index, hour) in ["00", "06", "12", "18"].enumerated() {
                context.draw(
                    Text(hour).font(HUDFace.mono(10)).foregroundStyle(theme.color(.inkMuted)),
                    at: point(Double(index * 360), radius + 14)
                )
            }
            context.stroke(
                arc(22 * 60, 7 * 60, radius - 16),
                with: .color(theme.color(.inkMuted).opacity(0.55)),
                style: StrokeStyle(lineWidth: 6, dash: focus ? [2, 3] : [])
            )
            context.stroke(arc(Double(minutes - 90), Double(minutes), radius - 28), with: .color(theme.color(.accent)), lineWidth: 3)
            let wake = point(Double(minutes), radius)
            var hand = Path()
            hand.move(to: centre)
            hand.addLine(to: wake)
            context.stroke(hand, with: .color(theme.color(.primary).opacity(0.6)))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: theme.color(.primary), radius: 4))
                layer.fill(Path(CGRect(x: wake.x - 4, y: wake.y - 4, width: 8, height: 8)), with: .color(theme.color(.primary)))
            }
            context.draw(
                Text(SetupText.time(minutes)).font(HUDFace.hero(20)).foregroundStyle(theme.color(.ink)),
                at: CGPoint(x: centre.x, y: centre.y - 8)
            )
            context.draw(
                Text("BRIEF READY").font(HUDFace.caps(9)).tracking(1.6).foregroundStyle(theme.color(.inkMuted)),
                at: CGPoint(x: centre.x, y: centre.y + 12)
            )
        }
        .frame(width: 220, height: 220)
        .accessibilityElement()
        .accessibilityLabel("Day dial: brief written before \(SetupText.time(minutes))")
    }
}

// MARK: - 05 Permissions

private struct PermissionsScreen: View {
    @State private var granted: [Permission: Bool] = [:]

    var body: some View {
        let needed = Permission.allCases.count - 1
        let count = [granted[.fullDisk], granted[.contacts], granted[.calendar].flatMap { cal in granted[.reminders].map { cal && $0 } }]
            .filter { $0 == true }.count
        SetupColumns {
            HUDMeter(
                label: "Granted",
                value: Double(count) / Double(needed),
                display: "\(count) of \(needed)",
                size: .medium,
                tone: count == needed ? HUD.ok : HUD.primary,
                segments: 36
            )
            Spacer().frame(height: HUD.space2)
            row("Full Disk Access", "Read Messages, Mail and the notification log.", [.fullDisk])
            HUDPermissionRow(
                name: "Accessibility",
                why: "Catch notification banners and see the front window.",
                status: .optional,
                statusText: "Not used yet"
            )
            row("Contacts", "Know who is who, without asking you.", [.contacts])
            row("Calendar and Reminders", "Your schedule, deadlines and reminders.", [.calendar, .reminders])
            HUDPermissionRow(
                name: "Notifications",
                why: "Only for emergency alerts, if you turn them on later.",
                status: .optional,
                statusText: "Not used yet"
            )
            HUDPermissionRow(
                name: "Home",
                why: "See and control lights, locks and the garage.",
                status: .optional,
                statusText: "Not used yet"
            )
        } side: {
            SetupCentre {
                HUDAsciiArt(shape: .eye, cols: 36, rows: 14, label: "Watching, on this Mac only")
                SetupParagraph(Text("macOS asks you for each one in System Settings. ") + Text("Nothing here leaves this Mac.")
                    .foregroundStyle(HUD.ink))
                SetupNote("Sources, Home and Control come next because they can only find what these allow.")
            }
        }
        // The ticks follow System Settings live, only while this screen shows.
        .task {
            while !Task.isCancelled {
                granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.granted) })
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ name: String, _ why: String, _ permissions: [Permission]) -> some View {
        let yes = permissions.allSatisfy { granted[$0] == true }
        return HUDPermissionRow(name: name, why: why, status: yes ? .granted : .needed) {
            Task {
                for permission in permissions where granted[permission] != true {
                    await permission.request()
                }
            }
        }
    }
}
