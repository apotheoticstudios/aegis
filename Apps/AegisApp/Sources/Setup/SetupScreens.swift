import AegisKit
import SwiftUI

/// The wizard's screens (DESIGN.md "Setup wizard"), each one category, the recommended answer already chosen.
struct SetupScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch setup.wizard.current {
            case .welcome: WelcomeScreen()
            case .mac: MacScreen(setup: setup)
            case .storage: StorageScreen(setup: setup)
            case .schedule: ScheduleScreen(setup: setup)
            case .permissions: PermissionsScreen()
            default: ReadyScreen(setup: setup)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WelcomeScreen: View {
    @State private var banner: [String] = []

    var body: some View {
        HUDAsciiText(lines: banner, cols: banner.map(\.count).max() ?? 0, size: 4.5, tone: HUD.ink, blocks: true)
            .accessibilityLabel("Project: Aegis")
            .padding(.bottom, HUD.space8)
            .task { banner = HUDBanner.lines("Project: Aegis", rows: 5, block: true) }
        HUDSection(title: "Welcome", first: true, linked: false) {
            SetupLine("Aegis runs entirely on this Mac. What it reads, and the AI that sorts it, never leave it.")
            SetupLine("It stays silent until you open it.")
            SetupLine("Every screen has the recommended answers chosen already: pressing Next throughout gives a great setup.")
        }
    }
}

private struct MacScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let mac = setup.wizard.mac
        HUDSection(title: "Your Mac", code: "DETECTED", first: true, linked: false) {
            Grid(alignment: .leading, horizontalSpacing: HUD.space8, verticalSpacing: HUD.space4) {
                GridRow {
                    HUDReadout(label: "Model", value: mac.model)
                    HUDReadout(label: "Chip", value: mac.chip)
                }
                GridRow {
                    HUDReadout(label: "Memory", value: "\(mac.memoryBytes >> 30)", unit: "GB")
                    HUDReadout(
                        label: "Free storage", value: HUDFormat.bytes(Double(mac.diskFreeBytes)),
                        unit: "of " + HUDFormat.bytes(Double(mac.diskTotalBytes))
                    )
                }
                GridRow {
                    HUDReadout(label: "macOS", value: mac.systemVersion)
                    HUDReadout(label: "Apple Intelligence", value: mac.appleIntelligence ? "On" : "Off")
                }
            }
        }
        HUDSection(title: "Kind", linked: false) {
            HStack(spacing: HUD.space2) {
                SetupChoice(title: "Laptop", chosen: mac.isLaptop) { setup.wizard.mac.isLaptop = true }
                SetupChoice(title: "Desktop", chosen: !mac.isLaptop) { setup.wizard.mac.isLaptop = false }
            }
            SetupLine("Detected automatically; change it only if it's wrong.", muted: true)
        }
        HUDSection(title: "What it runs", linked: false) {
            SetupLine("With \(mac.memoryBytes >> 30) GB of memory, Aegis's main model is \(SetupText.model(mac.memoryBytes)).")
        }
    }
}

private struct StorageScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let range = setup.wizard.mac.storageRange
        let recommended = setup.wizard.mac.recommendedStorageGB
        HUDSection(title: "Storage for Aegis", code: "\(range.lowerBound)–\(range.upperBound) GB", first: true, linked: false) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space4) {
                HUDReadout(label: "Assigned", value: "\(setup.wizard.storageGB)", unit: "GB", tone: HUD.primary)
                if setup.wizard.storageGB == recommended {
                    HUDTag(word: "Recommended", tone: HUD.ok)
                } else {
                    Button("Use recommended: \(recommended) GB") { setup.wizard.storageGB = recommended }
                        .buttonStyle(HUDChipStyle())
                }
            }
            // The HUD's meter as the slider: drag along it, or adjust it with VoiceOver.
            let span = Double(max(range.upperBound - range.lowerBound, 1))
            HUDMeter(
                label: "\(range.lowerBound) GB", value: Double(setup.wizard.storageGB - range.lowerBound) / span,
                display: "\(range.upperBound) GB"
            )
            .overlay {
                GeometryReader { proxy in
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        let fraction = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
                        setup.wizard.storageGB = range.lowerBound + Int((fraction * span).rounded())
                    })
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage for Aegis")
            .accessibilityValue("\(setup.wizard.storageGB) GB")
            .accessibilityAdjustableAction { direction in
                setup.wizard.storageGB += direction == .increment ? 5 : -5
            }
            SetupLine("Models, voice, memory and indexes all fit inside it. More space buys a larger model and a longer memory.")
            if setup.wizard.storageExceedsFreeSpace {
                SetupLine("That's more than the drive has free right now.", tone: HUD.warn)
            }
        }
    }
}

private struct ScheduleScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        HUDSection(title: "Morning brief", first: true, linked: false) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space4) {
                HUDReadout(label: "Ready by", value: SetupText.time(setup.wizard.briefMinutes), tone: HUD.primary)
                Button("−15 min") { move(by: -15) }.buttonStyle(HUDChipStyle())
                Button("+15 min") { move(by: 15) }.buttonStyle(HUDChipStyle())
            }
            SetupLine("Aegis writes your brief quietly before this time each day, with the panel closed.")
        }
    }

    private func move(by minutes: Int) {
        setup.wizard.briefMinutes = (setup.wizard.briefMinutes + minutes + 24 * 60) % (24 * 60)
    }
}

private struct PermissionsScreen: View {
    @State private var granted: [Permission: Bool] = [:]

    var body: some View {
        let count = Permission.allCases.filter { granted[$0] == true }.count
        HUDSection(title: "Access", code: "\(count) / \(Permission.allCases.count) GRANTED", first: true, linked: false) {
            ForEach(Permission.allCases, id: \.self) { permission in
                HStack(spacing: HUD.space4) {
                    VStack(alignment: .leading, spacing: HUD.space1) {
                        Text(permission.title).hudType(.label)
                        Text(permission.reason).hudType(.caption).foregroundStyle(HUD.inkMuted)
                    }
                    Spacer()
                    let yes = granted[permission] == true
                    HUDTag(word: yes ? "Granted" : "Needed", tone: yes ? HUD.ok : HUD.warn)
                    Button(yes ? "Settings" : "Allow") { Task { await permission.request() } }
                        .buttonStyle(HUDChipStyle(muted: yes))
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, HUD.space1)
            }
            SetupLine("macOS asks once for each. Change any of them later in System Settings, Privacy & Security.", muted: true)
        }
        // The ticks follow System Settings live, only while this screen shows.
        .task {
            while !Task.isCancelled {
                granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.granted) })
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct ReadyScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let wizard = setup.wizard
        let granted = Permission.allCases.filter(\.granted).count
        HUDSection(title: "Ready", first: true, linked: false) {
            SetupLine("\(wizard.storageGB) GB assigned · brief ready by \(SetupText.time(wizard.briefMinutes))")
            SetupLine("\(granted) of \(Permission.allCases.count) permissions granted · runs \(SetupText.model(wizard.mac.memoryBytes))")
            if granted < Permission.allCases.count {
                SetupLine("Aegis works with what it's allowed; go Back to grant the rest any time.", muted: true)
            }
            SetupLine("Open Aegis to see your first panel.")
        }
    }
}

/// A line of the wizard's text.
private struct SetupLine: View {
    let text: String
    var tone = HUD.ink

    init(_ text: String, muted: Bool = false, tone: HUDColor? = nil) {
        self.text = text
        self.tone = tone ?? (muted ? HUD.inkMuted : HUD.ink)
    }

    var body: some View {
        Text(text).hudType(.body).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
    }
}

/// One of a few choices: the chosen one lit.
private struct SetupChoice: View {
    let title: String
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action).buttonStyle(HUDChipStyle(muted: !chosen, live: chosen))
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

enum SetupText {
    /// "7:00 am", in the Mac's own format.
    static func time(_ minutes: Int) -> String {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())?
            .formatted(date: .omitted, time: .shortened) ?? ""
    }

    /// "Qwen3.5-9B": the model this much memory runs.
    static func model(_ memoryBytes: UInt64) -> String {
        ModelChoice.forMemory(memoryBytes).folderName.replacingOccurrences(of: "-MLX-4bit", with: "")
    }
}
