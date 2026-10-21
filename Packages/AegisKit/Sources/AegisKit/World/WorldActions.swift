// Catalogue source: God's Eye View (MIT), src/voice/actionSchemas.js and gevRealtime.js,
// pinned at 93ea088f4556a5a65b3292a2d15142d5a6c562bc in Apps/AegisApp/Resources/World.
import Foundation

/// One God's Eye View page action chosen from the owner's request (#296).
public struct WorldAction: Codable, Sendable, Hashable {
    public let name: String
    public let arguments: WorldValue

    public init(name: String, arguments: WorldValue) {
        self.name = name
        self.arguments = arguments
    }
}

/// Local action planning for the globe; collected content never supplies instructions.
public enum WorldActions {
    /// The most page actions returned for one owner request, in execution order.
    public static let maxActions = 4

    /// The compact, bundled God's Eye View catalogue.
    public static var catalogue: String {
        bundledCatalogue
    }

    /// Only the action names listed in the bundled catalogue.
    public static var names: Set<String> {
        catalogueNames
    }

    private static let bundledCatalogue: String = {
        guard let url = Bundle.module.url(forResource: "world-actions", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }()

    private static let catalogueNames = Set(bundledCatalogue.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("- `"), let end = line.firstIndex(of: "(") else { return nil }
        return String(line.dropFirst(3)[..<end])
    })

    /// Instructions for one local model job, followed by the action catalogue.
    public static func systemPrompt() -> String {
        """
        Pick God's Eye View actions for the owner's request about the globe. Reply with ONLY JSON:
        {"actions":[{"name":"…","arguments":{}}],"say":"one short sentence for the owner"}
        Use {"actions":[]} when the request isn't something the globe can do. At most four actions, in order.
        "Camera movement" means moving the globe view; public CCTV cameras are the cctv layer and control_cctv.
        Never put the owner's own places (my house, home, work, my street) in a search; use coordinates only if given.
        Use only action names and arguments from this catalogue:
        """ + "\n" + catalogue
    }

    /// One owner's request, optionally with the recent public place shown by the globe.
    public static func input(question: String, place: String?) -> String {
        let context = place.map { "\nTHE GLOBE IS SHOWING: " + $0 } ?? ""
        return "OWNER SAYS: " + question + context
    }

    /// Extracts a JSON plan from prose or fences, then drops unknown or privacy-restricted actions.
    /// Invalid shapes return nil; valid plans may have no usable actions.
    public static func parse(_ reply: String) -> Plan? {
        guard let object = Briefing.extractJSON(reply),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let draft = try? JSONDecoder().decode(Draft.self, from: data),
              draft.actions.allSatisfy({
                  if case .object = $0.arguments {
                      true
                  } else {
                      false
                  }
              })
        else { return nil }
        let actions = draft.actions.filter { names.contains($0.name) && safe($0.arguments) }
        return Plan(actions: Array(actions.prefix(maxActions)), say: draft.say)
    }

    /// A checked plan; an empty action list means no usable globe action was chosen.
    public struct Plan: Sendable, Hashable {
        public let actions: [WorldAction]
        public let say: String?
    }

    private struct Draft: Decodable {
        let actions: [WorldAction]
        let say: String?
    }

    /// The owner's own places never go to God's Eye View's online place search.
    private static func safe(_ value: WorldValue) -> Bool {
        switch value {
        case let .string(text):
            text.range(of: #"\b(my|mine|our|me|home|house)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        case let .array(values):
            values.allSatisfy(safe)
        case let .object(fields):
            fields.values.allSatisfy(safe)
        default:
            true
        }
    }
}
