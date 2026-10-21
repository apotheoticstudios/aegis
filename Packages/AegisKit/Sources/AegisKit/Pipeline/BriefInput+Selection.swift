import Foundation

extension BriefInputPolicy {
    func spool(
        _ events: some Sequence<Event>, scratch: InputScratch, selection: NoiseSelectionScratch, inputOrder: [String: Int]?
    ) throws -> Int {
        var count = 0
        for event in events where eligible(event) {
            let contextOnly = event.eventTime < windowStart
            count += contextOnly ? 0 : 1
            try pipelinePool {
                guard maxEvents > 0 else { return }
                let thread = selection.threadKey(EventEvidence.thread(event))
                if SenderDisplay.isOutgoing(event), let thread {
                    try scratch.noteReply(thread: thread, time: event.eventTime)
                }
                let normal = eventLine(event)
                let question = Self.asksOwner(event) && !Self.givesOrders(event)
                let answered = question ? eventLine(event, answered: true) : normal
                let renderable = normal != nil || answered != nil
                let rank = inputOrder?[event.id]
                try selection.append(
                    event, rank: rank, renderable: renderable, thread: thread, trusted: trustedSenders,
                    vip: ownerRules.isVIP(event, contacts: contacts)
                )
                if renderable {
                    if inputOrder != nil, inputOrder?[event.id] == nil {
                        throw PipelineError.invalidPolicy
                    }
                    try scratch.append(InputRow(
                        time: event.eventTime, rank: inputOrder?[event.id], id: event.id,
                        thread: question && !contextOnly ? thread : nil, normal: normal, answered: answered,
                        contextOnly: contextOnly
                    ))
                }
            }
        }
        return count
    }

    private func eligible(_ event: Event) -> Bool {
        event.eventTime >= (contextStart ?? windowStart) && event.eventTime <= windowEnd
            && ownerRules.hide(event, contacts: contacts) == nil
            && (ownerRules.isVIP(event, contacts: contacts) || !NoiseRules.excludedBulk(event, trusted: trustedSenders))
    }

    func selected(scratch: InputScratch, selection: NoiseSelectionScratch, used: inout Int) throws -> [InputRow] {
        var useful: [InputRow] = [], noise: [InputRow] = []
        let less = Self.selectionLess
        func retain(_ row: InputRow, in candidates: inout [InputRow]) {
            NoiseSelectionScratch.retainNewest(row, in: &candidates, limit: maxEvents, less: less)
        }
        try scratch.rewind()
        try selection.rewind()
        while let row = try scratch.next() {
            let facts = try selection.next()
            guard !row.contextOnly, let row = try resolved(row, facts: facts, scratch: scratch, selection: selection) else { continue }
            if facts.noise {
                retain(row, in: &noise)
            } else {
                retain(row, in: &useful)
            }
        }
        // Reserve ceil(maxEvents / 2) for useful records; either class may borrow unused room.
        useful.sort { less($1, $0) }
        let reserved = maxEvents / 2 + maxEvents % 2
        var heap = Array(useful.prefix(reserved))
        let remainder = (Array(useful.dropFirst(reserved)) + noise).sorted { less($1, $0) }
        heap += remainder.prefix(maxEvents - heap.count)
        var kept: [InputRow] = []
        used = 7
        // Spend the text budget on reserved records first, then the remaining newest candidates.
        for row in heap {
            guard let line = row.normal else { continue }
            if used + 1 + line.unicodeScalars.count <= maxText {
                kept.append(row)
                used += 1 + line.unicodeScalars.count
            }
        }
        return kept
    }

    private func resolved(
        _ row: InputRow, facts: NoiseSelectionScratch.Facts, scratch: InputScratch, selection: NoiseSelectionScratch
    ) throws -> InputRow? {
        guard let duplicates = try selection.duplicateCount(facts, id: row.id) else { return nil }
        var row = row
        let answered = try row.thread.map { try scratch.replyTime(thread: $0).map { $0 > row.time } ?? false } ?? false
        guard let line = answered ? row.answered : row.normal else { return nil }
        row.normal = NoiseSelectionScratch.countedLine(line, count: duplicates, limit: perEvent)
        row.answered = nil
        row.thread = facts.question ? facts.thread : nil
        return row.normal == nil ? nil : row
    }

    func appendContext(
        to kept: inout [InputRow], used: inout Int, scratch: InputScratch, selection: NoiseSelectionScratch
    ) throws {
        let less = Self.selectionLess
        // Context is optional: never displace a selected candidate. Each question gets up to three of the
        // newest earlier messages in its thread, including ones from before the window (context only).
        let questions = kept.filter { $0.thread != nil }
        for question in questions where kept.count < maxEvents {
            var context: [InputRow] = []
            try scratch.rewind()
            try selection.rewind()
            while let row = try scratch.next() {
                let facts = try selection.next()
                guard facts.thread == question.thread, facts.thread != nil, row.time < question.time,
                      !kept.contains(where: { $0.id == row.id }),
                      let candidate = try resolved(row, facts: facts, scratch: scratch, selection: selection),
                      candidate.normal != nil else { continue }
                NoiseSelectionScratch.retainNewest(candidate, in: &context, limit: Self.contextPerQuestion, less: less)
            }
            for row in context.sorted(by: { less($1, $0) }) where kept.count < maxEvents {
                guard let line = row.normal, used + 1 + line.unicodeScalars.count <= maxText else { continue }
                kept.append(row)
                used += 1 + line.unicodeScalars.count
            }
        }
    }

    /// Selection order: newer is greater; at equal times a lower legacy rank is newer, then the ID decides.
    private static func selectionLess(_ left: InputRow, _ right: InputRow) -> Bool {
        if left.time != right.time {
            return left.time < right.time
        }
        if let lhs = left.rank, let rhs = right.rank, lhs != rhs {
            return lhs > rhs
        }
        return scalarLess(left.id, right.id)
    }

    /// Render order: oldest first; at equal times by legacy arrival rank, then ID.
    static func renderOrder(_ left: InputRow, _ right: InputRow) -> Bool {
        if left.time != right.time {
            return left.time < right.time
        }
        if let lhs = left.rank, let rhs = right.rank, lhs != rhs {
            return lhs < rhs
        }
        return scalarLess(left.id, right.id)
    }
}

struct InputRow: Codable {
    var time: Date
    var rank: Int?
    var id: String
    var thread: String?
    var normal: String?
    var answered: String?
    /// From before the window: eligible only as a question's context.
    var contextOnly = false
}
