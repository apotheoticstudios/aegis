import Foundation

/// Debounces audio levels into speech boundaries without owning any audio APIs or clock.
public struct VoiceActivityGate: Sendable {
    /// A confirmed onset (timestamped at its first loud frame) or end of an utterance.
    public enum Event: Equatable, Sendable {
        case speechStarted(TimeInterval)
        case speechEnded(started: TimeInterval, ended: TimeInterval)
    }

    private var noiseFloor: Float = -60
    private var lastTime: TimeInterval?
    private var loudSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var speechSince: TimeInterval?

    /// Creates an idle gate with a noise floor of -60 dBFS.
    public init() {}

    /// Feed finite levels with increasing monotonic timestamps, normally every 20 ms.
    /// Invalid or out-of-order frames are ignored. Ends use the confirmation time, capped at onset + 12 s.
    public mutating func feed(level dBFS: Float, at time: TimeInterval) -> Event? {
        guard dBFS.isFinite, time.isFinite else { return nil }
        if let lastTime, time <= lastTime {
            return nil
        }
        let elapsed = lastTime.map { time - $0 } ?? 0
        lastTime = time
        let isLoud = dBFS > max(noiseFloor + 12, -50)
        if let started = speechSince {
            return advanceSpeech(isLoud: isLoud, started: started, at: time)
        }
        if isLoud {
            let onset = loudSince ?? time
            loudSince = onset
            guard time >= onset + 0.15 else { return nil }
            speechSince = onset
            loudSince = nil
            return .speechStarted(onset)
        }
        loudSince = nil
        // A two-second exponential average follows gradual ambient rises, never loud clicks or speech.
        let weight = Float(1 - exp(-elapsed / 2))
        noiseFloor += weight * (dBFS - noiseFloor)
        return nil
    }

    private mutating func advanceSpeech(isLoud: Bool, started: TimeInterval, at time: TimeInterval) -> Event? {
        if time >= started + 12 {
            return endSpeech(started: started, ended: started + 12)
        }
        if isLoud {
            quietSince = nil
            return nil
        }
        let silence = quietSince ?? time
        quietSince = silence
        guard time >= silence + 0.7 else { return nil }
        return endSpeech(started: started, ended: time)
    }

    private mutating func endSpeech(started: TimeInterval, ended: TimeInterval) -> Event {
        speechSince = nil
        quietSince = nil
        loudSince = nil
        return .speechEnded(started: started, ended: ended)
    }
}
