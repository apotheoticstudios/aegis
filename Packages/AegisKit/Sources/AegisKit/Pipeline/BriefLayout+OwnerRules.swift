import Foundation

extension BriefLayout {
    /// Applies changed owner rules to a stored brief without rewriting its calibrated model priorities.
    static func ownerPrioritised(_ items: [Brief.Item], events: [String: Event], rules: OwnerRules) -> [Brief.Item] {
        let contacts = contactIDs(events)
        var urgent = 0
        return items.map { item in
            var item = item
            let cited = item.eventIDs.compactMap { events[$0] }
            item.priority = ownerPriority(item.priority, cited: cited, contacts: contacts, rules: rules)
            if item.priority == .urgent {
                urgent += 1
                if urgent > BriefChecks.maxUrgent {
                    item.priority = .reply
                }
            }
            return item
        }
    }

    /// VIPs have a reply floor; keyword urgency operates on cited data and never raises planted orders.
    static func ownerPriority(
        _ priority: Brief.Priority, cited: [Event], contacts: [String: Event.ContactRef], rules: OwnerRules
    ) -> Brief.Priority {
        guard !cited.isEmpty else { return priority }
        let incoming = cited.filter { !SenderDisplay.isOutgoing($0) && rules.hide($0, contacts: contacts) == nil }
        let onlyVIP = incoming.count == cited.count && incoming.allSatisfy { rules.isVIP($0, contacts: contacts) }
        let floor: Brief.Priority = priority == .fyi && onlyVIP ? .reply : priority
        guard !cited.contains(where: plantedOrder) else { return floor }
        return incoming.contains(where: { rules.matchesKeyword($0, effect: .urgent) }) ? .urgent : floor
    }
}
