import Foundation

/// The setup wizard's screens, in DESIGN.md's order: the Mac first (it decides what's offered), permissions before
/// what they unlock, personality before voice, the tune-up last.
public enum SetupStep: String, Codable, Sendable, CaseIterable {
    case welcome, mac, storage, schedule, permissions, sources, home, control, privacy, personality, voice, interface,
         silence, tuneUp, ready

    /// The screens the wizard shows. Home, Control and Tune-up stay hidden until their features exist (owner's
    /// choice, #24).
    public static let offered = allCases.filter { ![.home, .control, .tuneUp].contains($0) }

    var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// The Mac as the app detects it. The wizard shows it to confirm, never to type in; the owner may correct it.
public struct MacProfile: Codable, Sendable, Hashable {
    /// The kind of Mac, e.g. "MacBook Air".
    public var model: String
    /// The chip, e.g. "Apple M4".
    public var chip: String
    public var memoryBytes: UInt64
    /// The drive Aegis keeps its data on.
    public var diskTotalBytes: UInt64
    public var diskFreeBytes: UInt64
    /// The macOS version, e.g. "26.1".
    public var systemVersion: String
    public var appleIntelligence: Bool
    public var isLaptop: Bool

    public init(
        model: String, chip: String, memoryBytes: UInt64, diskTotalBytes: UInt64, diskFreeBytes: UInt64,
        systemVersion: String, appleIntelligence: Bool, isLaptop: Bool
    ) {
        self.model = model
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.diskTotalBytes = diskTotalBytes
        self.diskFreeBytes = diskFreeBytes
        self.systemVersion = systemVersion
        self.appleIntelligence = appleIntelligence
        self.isLaptop = isLaptop
    }

    static let gigabyte: UInt64 = 1_000_000_000

    /// The storage slider's range in GB (DESIGN.md "Storage assignment"): 20 GB up to 75% of the drive.
    public var storageRange: ClosedRange<Int> {
        20 ... max(20, Int(diskTotalBytes / Self.gigabyte * 3 / 4))
    }

    /// The recommended assignment: the Pro band's 50 GB with 32 GB of memory or more (the RAM that runs every band),
    /// otherwise the Standard band's 20 GB; at most half the free space, and within the slider's range.
    public var recommendedStorageGB: Int {
        let band = memoryBytes >= 32 * Self.gigabyte ? 50 : 20
        return min(band, Int(diskFreeBytes / Self.gigabyte / 2)).clamped(to: storageRange)
    }
}

/// The owner's answers. Nil means "recommended", so an answer the owner hasn't changed follows later corrections to
/// the Mac's details.
public struct SetupAnswers: Codable, Sendable, Hashable {
    public var storageGB: Int?
    /// Always on (a desktop) or laptop (battery throttling, catch-up on wake).
    public var alwaysOn: Bool?
    /// When the brief is ready, in minutes after local midnight.
    public var briefMinutes: Int?
    /// Wake the Mac before the brief.
    public var wakeMacForBrief: Bool?

    public init() {}
}

/// Where the owner is in setup and what they've chosen (DESIGN.md "Setup wizard"). Saved after every change, so
/// setup resumes where it stopped; going back loses nothing.
public struct SetupWizard: Codable, Sendable, Hashable {
    /// The screens this version of Aegis shows, in order; never empty. Not saved: a newer Aegis may show more.
    public var steps = SetupStep.offered {
        didSet { precondition(!steps.isEmpty) }
    }

    /// The saved screen; `current` is the one shown.
    public private(set) var step = SetupStep.welcome
    public private(set) var finished = false
    public var mac: MacProfile
    public var answers = SetupAnswers()

    private enum CodingKeys: String, CodingKey {
        case step, finished, mac, answers
    }

    public init(mac: MacProfile) {
        self.mac = mac
    }

    /// The shown screen's index. A saved screen this version doesn't show resumes at the next one it does.
    public var position: Int {
        steps.firstIndex { $0.rank >= step.rank } ?? steps.count - 1
    }

    public var current: SetupStep {
        steps[position]
    }

    public var canGoBack: Bool {
        position > 0
    }

    /// The next screen; Next on the last screen (Ready) finishes setup.
    public mutating func next() {
        if position == steps.count - 1 {
            finished = true
        } else {
            step = steps[position + 1]
        }
    }

    public mutating func back() {
        step = steps[max(0, position - 1)]
    }

    /// "Use recommended for the rest": the answers not yet changed are already the recommended ones.
    public mutating func useRecommendedForRest() {
        step = steps[steps.count - 1]
    }

    /// Runs setup again from settings, keeping every answer.
    public mutating func restart() {
        step = steps[0]
        finished = false
    }

    // MARK: - Answers, recommended unless the owner changed them

    public var storageGB: Int {
        get { (answers.storageGB ?? mac.recommendedStorageGB).clamped(to: mac.storageRange) }
        set { answers.storageGB = newValue }
    }

    /// The assignment is more than the drive has free now (the slider warns, but allows it).
    public var storageExceedsFreeSpace: Bool {
        UInt64(storageGB) * MacProfile.gigabyte > mac.diskFreeBytes
    }

    public var alwaysOn: Bool {
        get { answers.alwaysOn ?? !mac.isLaptop }
        set { answers.alwaysOn = newValue }
    }

    /// Minutes after local midnight; 7:00 am unless changed.
    public var briefMinutes: Int {
        get { (answers.briefMinutes ?? 7 * 60).clamped(to: 0 ... 24 * 60 - 1) }
        set { answers.briefMinutes = newValue }
    }

    public var wakeMacForBrief: Bool {
        get { answers.wakeMacForBrief ?? false }
        set { answers.wakeMacForBrief = newValue }
    }
}

/// Setup's progress as JSON in Aegis's private folder, written atomically.
public struct SetupFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Nil before setup has started.
    public func load() throws -> SetupWizard? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SetupWizard.self, from: Data(contentsOf: url))
    }

    public func save(_ wizard: SetupWizard) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(wizard).write(to: url, options: .atomic)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
