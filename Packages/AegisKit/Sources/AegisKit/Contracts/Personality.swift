import Foundation

/// Who Aegis is and how it talks (#241, additive): its name (also the wake word), a preset style, what it calls
/// the owner and the owner's own notes. Set only by the owner in settings (later the setup wizard), never by
/// collected content. Tone only: facts and priorities are the same in every style.
public struct Personality: Codable, Sendable, Hashable {
    /// DESIGN.md › Personality presets.
    public enum Style: String, Codable, Sendable, CaseIterable {
        case classic, friendly, professional, none

        public var title: String {
            switch self {
            case .classic: "Classic"
            case .friendly: "Friendly"
            case .professional: "Professional"
            case .none: "None"
            }
        }

        /// The style as the model reads it.
        public var description: String {
            switch self {
            case .classic:
                "A classic cinematic assistant: calm, impeccably polite and quietly brilliant, with a dry British wit and "
                    + "understated sarcasm; unflappable, loyal and always a step ahead."
            case .friendly:
                "warm, upbeat and casual, like a good mate: relaxed Australian English, jokes easily, never stiff."
            case .professional:
                "crisp, efficient and to the point: polite, no small talk or jokes unless the owner starts them."
            case .none:
                "pure information: the facts in as few words as possible, no small talk, no jokes, no flourishes."
            }
        }
    }

    public var name: String
    public var style: Style
    /// What Aegis calls the owner ("sir", "boss", their name); empty for nothing in particular.
    public var callOwner: String
    /// The owner's own words about how Aegis should be ("swear a bit", "roast me", "be more Australian").
    public var notes: String

    public static let standard = Personality(name: "Aegis", style: .classic, callOwner: "", notes: "")
    public static let maxName = 24
    public static let maxCallOwner = 40
    public static let maxNotes = 600

    public init(name: String, style: Style, callOwner: String, notes: String) {
        self.name = name
        self.style = style
        self.callOwner = callOwner
        self.notes = notes
    }

    /// Trimmed, within limits, and a name of letters (and spaces, hyphens or apostrophes) only.
    public var cleaned: Personality? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let call = callOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= Self.maxName,
              name.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" }),
              call.unicodeScalars.count <= Self.maxCallOwner, notes.unicodeScalars.count <= Self.maxNotes
        else { return nil }
        return Personality(name: name, style: style, callOwner: call, notes: notes)
    }

    /// The identity and personality paragraph of the chat prompt.
    public var prompt: String {
        var lines = [
            "Your name is \(name). You are the owner's own personal AI assistant, living on their Mac. Always speak "
                + "as \(name): when asked who or what you are, say you're \(name), their assistant, and never call "
                + "yourself a language model, Qwen, ChatGPT, Claude or \"just an AI assistant\", or say who made you.",
            "Your personality: " + style.description,
        ]
        if !callOwner.isEmpty {
            lines.append("Call the owner \"\(callOwner)\" now and then, as Aegis says \"sir\".")
        }
        if !notes.isEmpty {
            lines.append("The owner's own notes on how you should be (follow them): " + notes)
        }
        return lines.joined(separator: "\n")
    }
}

/// Where the personality is kept (#241).
public protocol PersonalityPersistence: Sendable {
    func load() throws -> Personality
    func save(_ personality: Personality) throws
}

/// The personality as JSON in Aegis's private folder; no file means the standard Aegis.
public struct PersonalityFile: PersonalityPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Personality {
        guard FileManager.default.fileExists(atPath: url.path) else { return .standard }
        return try JSONDecoder().decode(Personality.self, from: Data(contentsOf: url))
    }

    public func save(_ personality: Personality) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(personality).write(to: url, options: .atomic)
    }
}
