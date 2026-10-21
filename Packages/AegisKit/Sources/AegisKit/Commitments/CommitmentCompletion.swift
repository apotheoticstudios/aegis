import Foundation

enum CommitmentCompletion {
    static func thread(_ event: Event) -> String? {
        if event.source == .email {
            let handle = event.direction == .outgoing ? event.recipients.first : event.senderHandle
            return handle.flatMap { $0.isEmpty ? nil : "email:" + BriefLayout.handleKey($0) }
        }
        guard event.source == .imessage || event.source == .sms, let thread = event.threadID, !thread.isEmpty else { return nil }
        return "messages:" + thread
    }

    static func completes(_ later: Event, verb: CommitmentVerb, madeAt: Date) -> Bool {
        let text = CommitmentText.unquoted(CommitmentText.body(later)).replacingOccurrences(of: "’", with: "'")
        if later.direction == .incoming {
            return acknowledged(text)
        }
        guard later.direction == .outgoing else { return false }
        if verb == .send, later.flags.contains(.attachmentOnly) {
            return true
        }
        if verb == .check || verb == .getBack {
            return later.eventTime.timeIntervalSince(madeAt) >= 600
        }
        // A new promise, question, or negated completion is not evidence that the earlier task was done.
        let exclusions = #"\b(?:not|never|haven't|hasn't|didn't|wasn't|isn't|won't|can't|cannot|will|i'll)\b"#
        guard CommitmentText.match(exclusions, in: text) == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        else { return false }
        return CommitmentText.match(cue(verb), in: text) != nil
    }

    private static func acknowledged(_ text: String) -> Bool {
        let exclusions = #"\b(?:not|never|haven't|hasn't|didn't|wasn't|isn't|won't|can't|cannot|will)\b"#
        guard CommitmentText.match(exclusions, in: text) == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return false }
        return CommitmentText.match(#"\b(?:got it|received|thanks for sending|that works|all good)\b"#, in: text) != nil
    }

    private static func cue(_ verb: CommitmentVerb) -> String {
        switch verb {
        case .send: #"\b(?:sent|attached|here it is|here's|here you go|forwarded)\b"#
        case .call: #"\b(?:called|rang|spoke|tried calling)\b"#
        case .pay: #"\b(?:paid|transferred|sent the money)\b"#
        case .book: #"\b(?:booked|reserved|confirmed)\b"#
        default: #"\b(?:done|fixed|finished|sorted|all good)\b"#
        }
    }
}
