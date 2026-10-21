import Foundation

/// Fail-closed pipeline errors. Errors never contain collected text.
public enum PipelineError: Error, Sendable {
    case invalidPolicy, invalidDraft, scratchStorage, unlabelledEvent, invalidCorpus
}

/// Complete serialized model input and the IDs it actually includes.
public struct BriefInput: Sendable, Equatable {
    public let text: String
    public let eventIDs: [String]
    public let omittedEvents: Int
    /// Senders the owner marked "Not junk" (#167), carried to the brief checks.
    public var trustedSenders: Set<String> = []
    /// Owner visibility and priority rules carried to the final checks (#185).
    public var ownerRules: OwnerRules = .empty
}

/// Window and hard Unicode-scalar limits, matching Stage 0's input policy.
public struct BriefInputPolicy: Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    public let maxText: Int
    public let perEvent: Int
    public let maxEvents: Int
    public let maxBody: Int
    /// Events from here up to `windowStart` serve only as conversation context for questions: never items,
    /// never counted as omitted (#153). Nil means the window itself.
    public let contextStart: Date?
    /// Senders the owner marked "Not junk" (#167): never treated as junk. Lower-cased handles or bundle IDs.
    public let trustedSenders: Set<String>
    /// Owner rules, applied before selection and carried to the publication gate.
    public let ownerRules: OwnerRules
    /// Resolved identities for Messages notification titles; supplied by the named snapshot's caller.
    public let contacts: [String: Event.ContactRef]
    /// Earlier same-thread messages given to each question.
    public static let contextPerQuestion = 3

    public init(
        windowStart: Date, windowEnd: Date, maxText: Int = 12000,
        perEvent: Int = 1000, maxEvents: Int = 40, maxBody: Int = 280, contextStart: Date? = nil,
        trustedSenders: Set<String> = [], ownerRules: OwnerRules = .empty, contacts: [String: Event.ContactRef] = [:]
    ) throws {
        guard windowStart <= windowEnd, maxText >= 7, perEvent >= 1, maxEvents >= 0, maxBody >= 0,
              (contextStart ?? windowStart) <= windowStart
        else {
            throw PipelineError.invalidPolicy
        }
        self.contextStart = contextStart
        self.trustedSenders = trustedSenders.union(ownerRules.trusted)
        self.ownerRules = ownerRules
        self.contacts = contacts
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.maxText = maxText
        self.perEvent = perEvent
        self.maxEvents = maxEvents
        self.maxBody = maxBody
    }

    public static let asksMarker = " · (asks you something)"
    public static let ordersMarker = " · (gives orders to an assistant)"

    /// A question from someone else in Messages, SMS, email, or a Messages notification.
    public static func asksOwner(_ event: Event) -> Bool {
        !SenderDisplay.isOutgoing(event) && event.body.contains("?")
            && (event.source == .imessage || event.source == .sms || event.source == .email || MessagesApp.contains(event.appID))
            // Machines ask nobody anything: "Reply Y to confirm" from a no-reply address isn't a question (#135).
            && !NoiseRules.automatedSender(event)
    }

    private static let orderPatterns: [NSRegularExpression] = {
        let addressed = #"(?:^|[.!?\n]\s*)(?:@(?:aegis|assistant)\b|"#
            + #"(?:(?:hey|hi|dear|ok|okay|hello|yo|greetings|attention|(?:note to|message for|to)(?: the)?)\s+)?"#
            + #"(?:aegis|assistant|ai assistant|ai model|chatbot|language model|ai)\s*[,:])"#
        let override = #"\b(?:ignore|disregard|forget|override)\s+(?:all\s+|any\s+)?(?:of\s+)?"#
            + #"(?:your\s+|the\s+|these\s+|those\s+)?(?:previous|prior|above|earlier|original|system)\s+"#
            + #"(?:instructions|prompts?|rules)\b|\bsystem prompt\b"#
        return [addressed, override].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Rule-based detection of collected text that addresses or attempts to override an assistant.
    public static func givesOrders(_ event: Event) -> Bool {
        let text = [event.title, event.body].compactMap(\.self).joined(separator: "\n")
        let range = NSRange(text.startIndex..., in: text)
        return orderPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// A safely quoted physical line; metadata too large for the limit omits the event.
    /// `answered` suppresses only the question marker, never the assistant-orders marker.
    public func eventLine(_ event: Event, answered: Bool = false) -> String? {
        func oneLine(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned: " ".unicodeScalars.first ?? scalar
                default: scalar.value == 0x2028 || scalar.value == 0x2029 ? " ".unicodeScalars.first ?? scalar : scalar
                }
            }))
        }
        var line = "[\(event.id)] \(ContractTime.format(event.eventTime)) · \(event.source.rawValue)"
        if let sender = SenderDisplay.label(event), !sender.isEmpty {
            line += " · " + scalarPrefix("from " + oneLine(sender), perEvent)
        }
        if let title = event.title, !title.isEmpty, !exactText(title, event.sender) {
            line += " · " + scalarPrefix(oneLine(title), perEvent)
        }
        line += EventEvidence.metadata(event)
        var body = scalarPrefix(event.body, maxBody) + (event.body.unicodeScalars.count > maxBody ? "…" : "")
        let suffix = Self.givesOrders(event) ? Self.ordersMarker : (Self.asksOwner(event) && !answered ? Self.asksMarker : "")
        let prefix = line + " · "
        line = prefix + (body.isEmpty ? "(no text: \(event.content.rawValue))" : jsonString(body)) + suffix
        while line.unicodeScalars.count > perEvent, !body.isEmpty {
            body = scalarPrefix(body, body.unicodeScalars.count - max(1, line.unicodeScalars.count - perEvent))
            line = prefix + jsonString(body) + suffix
        }
        return line.unicodeScalars.count <= perEvent ? line : nil
    }

    /// Consume an already merged, single-pass stream. Newest eligible events are rendered oldest first.
    /// Optional ranks preserve legacy arrival ordering for equal timestamps.
    /// RAM is O(maxEvents * perEvent); private scratch files resolve later owner replies in arbitrary arrival order.
    /// Scratch records contain bounded rendered variants and hashed thread IDs, and are removed on return or error.
    public func build(_ events: some Sequence<Event>, inputOrder: [String: Int]? = nil) throws -> BriefInput {
        let scratch = try InputScratch()
        defer { scratch.remove() }
        let selection = try NoiseSelectionScratch(folder: scratch.folder)
        defer { selection.close() }
        let count = try spool(events, scratch: scratch, selection: selection, inputOrder: inputOrder)
        var used = 7
        var kept = try selected(scratch: scratch, selection: selection, used: &used)
        try appendContext(to: &kept, used: &used, scratch: scratch, selection: selection)
        kept.sort(by: Self.renderOrder)
        return BriefInput(
            text: "Events:" + kept.map { "\n" + ($0.normal ?? "") }.joined(),
            eventIDs: kept.map(\.id),
            omittedEvents: count - kept.filter { !$0.contextOnly }.count,
            trustedSenders: trustedSenders, ownerRules: ownerRules
        )
    }
}
