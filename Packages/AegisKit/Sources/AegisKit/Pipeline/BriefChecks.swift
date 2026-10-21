import Foundation

/// Stable reason codes only: no collected text, model output, or event identifiers.
public enum BriefRejection: String, Error, Sendable, CaseIterable {
    case invalidDraft = "invalid_draft"
    case attemptedActions = "attempted_actions"
    case urgentPlantedOrder = "urgent_planted_order"
    case tooManyDroppedItems = "too_many_dropped_items"
    /// Every item was dropped: publishing an empty brief would hide the last valid one.
    case allItemsDropped = "all_items_dropped"
    case missingCitations = "missing_citations"
    case tooManyItems = "too_many_items"
    case tooManyUrgent = "too_many_urgent"
    case textTooLong = "text_too_long"
    case unsafeText = "unsafe_text"
    case invalidBrief = "invalid_brief"
}

/// A publishable brief plus the total structurally malformed/out-of-input items removed.
public struct CheckedBrief: Sendable {
    public let brief: Brief
    public let droppedItems: Int
}

/// Publication gate for untrusted model drafts. It neither stores data nor executes actions.
public enum BriefChecks {
    /// Held-out Stage 1 brief_budget (Fixtures/labels/stage1-heldout.json).
    public static let maxItems = 10
    /// Held-out Stage 1 brief_budget (Fixtures/labels/stage1-heldout.json).
    public static let maxUrgent = 3
    /// Item text is a single physical line of at most 280 Unicode scalars.
    public static let maxItemScalars = 280
    /// More structural/citation drops suggest the draft was steered; retain the previous brief.
    public static let maxDroppedItems = 2

    /// Core's single-call gate: convert a raw JSON draft with trusted metadata, then check it.
    /// Only a success may replace the stored brief. Use the failure with fallback to keep the last valid brief.
    public static func check(
        _ draft: [String: Any], input: BriefInput, events: [String: Event],
        windowStart: Date, windowEnd: Date, model: String, generatedAt: Date = Date()
    ) -> Result<CheckedBrief, BriefRejection> {
        do {
            return try check(Briefing.convert(
                draft, omitted: input.omittedEvents, windowStart: windowStart, windowEnd: windowEnd,
                model: model, generatedAt: generatedAt
            ), input: input, events: events)
        } catch { return .failure(.invalidDraft) }
    }

    /// Check a conversion without losing evidence of action attempts or dropped malformed items.
    public static func check(
        _ conversion: BriefConversion, input: BriefInput, events: [String: Event]
    ) -> Result<CheckedBrief, BriefRejection> {
        guard !conversion.attemptedActions else { return .failure(.attemptedActions) }
        guard !conversion.urgentEventIDs.contains(where: { events[$0].map(BriefLayout.plantedOrder) == true }) else {
            return .failure(.urgentPlantedOrder)
        }
        return checked(conversion.brief, input: input, events: events, droppedItems: conversion.droppedItems)
    }

    /// Check an already typed brief. Raw model output must use the draft/conversion overload to retain provenance.
    public static func check(
        _ brief: Brief, input: BriefInput, events: [String: Event]
    ) -> Result<CheckedBrief, BriefRejection> {
        checked(brief, input: input, events: events, droppedItems: 0)
    }

    /// Keep the previous brief unchanged; status contains only a trusted timestamp and a fixed reason code.
    /// A nil previous brief leaves the panel empty with an explicit status.
    public static func fallback(lastValid: Brief?, rejection: BriefRejection) -> (brief: Brief?, status: String) {
        let kept = lastValid.map { "brief kept from \(ContractTime.format($0.generatedAt))" } ?? "no valid brief available"
        return (lastValid, "\(kept); new draft rejected: \(rejection.rawValue)")
    }

    /// Structurally broken items, and items naming a contact unconnected to their citations, are dropped.
    private static func usable(
        _ item: Brief.Item, allowed: Set<String>, events: [String: Event], contacts: Set<String>
    ) -> Bool {
        !item.text.isEmpty && item.eventIDs.allSatisfy { allowed.contains($0) && events[$0]?.id == $0 }
            && !BriefPeople.namesUnconnectedContact(item, events: events, contacts: contacts)
    }

    private static func textRejection(_ item: Brief.Item) -> BriefRejection? {
        guard !item.eventIDs.isEmpty else { return .missingCitations }
        guard item.text.unicodeScalars.count <= maxItemScalars else { return .textTooLong }
        guard !EventEvidence.exposesIdentity(item.text) else { return .unsafeText }
        guard !item.text.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return .unsafeText }
        return nil
    }

    private static func hidden(
        _ item: Brief.Item, input: BriefInput, events: [String: Event], identities: [String: Event.ContactRef]
    ) -> Bool {
        !item.eventIDs.isEmpty && item.eventIDs.allSatisfy { id in
            guard let event = events[id] else { return false }
            if input.ownerRules.hide(event, contacts: identities) != nil {
                return true
            }
            return !input.ownerRules.isVIP(event, contacts: identities)
                && NoiseRules.isNoise(event, trusted: input.trustedSenders)
        }
    }

    private static func checked(
        _ draft: Brief, input: BriefInput, events: [String: Event], droppedItems: Int
    ) -> Result<CheckedBrief, BriefRejection> {
        // Inspect steering before discarding items, including ones with another bad citation.
        for item in draft.items where item.priority == .urgent {
            if item.eventIDs.contains(where: { events[$0].map(BriefLayout.plantedOrder) == true }) {
                return .failure(.urgentPlantedOrder)
            }
        }
        let allowed = Set(input.eventIDs)
        let contacts = BriefPeople.contacts(in: events)
        var brief = draft
        brief.items = draft.items.filter { usable($0, allowed: allowed, events: events, contacts: contacts) }
        let dropped = droppedItems + draft.items.count - brief.items.count
        // Items made only of junk (sales, codes, routine notices) are left out quietly: the owner never
        // wants them, and it isn't a sign of a broken draft (owner's test review, 2026-10-10).
        let identities = BriefLayout.contactIDs(events)
        brief.items.removeAll { hidden($0, input: input, events: events, identities: identities) }
        guard dropped <= maxDroppedItems else { return .failure(.tooManyDroppedItems) }
        // An empty brief is valid only when the model itself found nothing (a quiet day).
        guard !(brief.items.isEmpty && dropped > 0) else { return .failure(.allItemsDropped) }
        guard brief.items.count <= maxItems else { return .failure(.tooManyItems) }
        guard brief.items.filter({ $0.priority == .urgent }).count <= maxUrgent else { return .failure(.tooManyUrgent) }
        for item in brief.items {
            if let rejection = textRejection(item) {
                return .failure(rejection)
            }
        }
        // Budgets above judge the model's draft; tidying then splits blended items within the same limits.
        brief.items = BriefLayout.tidy(brief.items, events: events, maxUrgent: maxUrgent, rules: input.ownerRules)
        brief.items.removeAll { hidden($0, input: input, events: events, identities: identities) }
        guard brief.omittedEvents == input.omittedEvents, brief.validate(knownEventIDs: allowed).isEmpty else {
            return .failure(.invalidBrief)
        }
        return .success(CheckedBrief(brief: brief, droppedItems: dropped))
    }
}
