import Foundation

/// Pure hands-free conversation state. All times come from the app's monotonic clock.
public struct ConversationWindow: Sendable {
    /// Listening and response phases of a conversation.
    public enum State: Equatable, Sendable {
        case waitingForWake
        case capturing
        case thinking
        case speaking
        case followUp(until: TimeInterval)
    }

    /// A decision for the app to perform in response to a transition.
    public enum Action: Equatable, Sendable {
        case none
        case openPanel
        case startCapture
        case ask(String)
        case stopListening
    }

    /// Current phase, initially waiting for a wake phrase.
    public private(set) var state: State = .waitingForWake

    /// Creates an idle conversation.
    public init() {}

    /// Call after a wake match. Opening the panel begins capture.
    /// If the match has a question, forward it to `questionComplete` after opening the panel.
    public mutating func wake() -> Action {
        guard state == .waitingForWake else { return .none }
        state = .capturing
        return .openPanel
    }

    /// Submits a completed microphone transcript; blank transcripts leave capture active.
    public mutating func questionComplete(_ question: String) -> Action {
        guard state == .capturing else { return .none }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        state = .thinking
        return .ask(trimmed)
    }

    /// Marks the start of Aegis's reply; microphone speech is ignored during playback.
    public mutating func startedSpeaking() -> Action {
        guard state == .thinking else { return .none }
        state = .speaking
        return .none
    }

    /// Enables six seconds of follow-up listening after playback finishes.
    public mutating func finishedSpeaking(at time: TimeInterval) -> Action {
        guard state == .speaking, time.isFinite else { return .none }
        state = .followUp(until: time + 6)
        return .startCapture
    }

    /// Speech before the follow-up deadline starts a new question without requiring a wake.
    /// Speech in every other phase, including Aegis's own playback, is ignored.
    public mutating func heard(at time: TimeInterval) -> Action {
        guard time.isFinite, case let .followUp(until) = state else { return .none }
        guard time < until else { return cancel() }
        state = .capturing
        return .startCapture
    }

    /// Expires follow-up listening at the deadline, including when no new speech arrives.
    public mutating func tick(now: TimeInterval) -> Action {
        guard now.isFinite, case let .followUp(until) = state, now >= until else { return .none }
        return cancel()
    }

    /// Ends the conversation and returns to wake-only listening.
    public mutating func cancel() -> Action {
        guard state != .waitingForWake else { return .none }
        state = .waitingForWake
        return .stopListening
    }
}
