import AegisKit
import Foundation

/// Calibrates levels against the room before the existing speech boundary detector sees them.
/// Keeps numeric levels only; never audio or words. Playback resets boundaries, not the learned room level.
struct WakeActivityGate {
    private var gate = VoiceActivityGate()
    private var levels: [(time: TimeInterval, level: Float)] = []
    private var floor: Float?
    private var lastSample: TimeInterval?
    private var lastTime: TimeInterval?
    private var active = false

    mutating func resetSpeech() {
        gate = VoiceActivityGate()
        active = false
    }

    mutating func feed(level: Float, at time: TimeInterval, capture: Bool, interruption: Bool = false) -> VoiceActivityGate.Event? {
        guard level.isFinite, time.isFinite, lastTime.map({ time > $0 }) ?? true else { return nil }
        lastTime = time
        if !active, lastSample.map({ time - $0 >= 0.1 }) ?? true {
            let elapsed = min(0.1, lastSample.map { time - $0 } ?? 0)
            lastSample = time
            levels.removeAll { time - $0.time > 5 }
            levels.append((time, level))
            if let first = levels.first, time - first.time >= 0.5 {
                let sorted = levels.map(\.level).sorted()
                let candidate = max(-80, sorted[sorted.count / 5])
                // Learn a quieter room immediately; do not mistake a new speaker for a louder room.
                floor = floor.map { min(candidate, $0 + Float(elapsed) * 2) } ?? candidate
            }
        }
        guard capture, let floor else { return nil }
        // An invited question needs less evidence than speech that might interrupt playback.
        // Hysteresis retains softer syllables; the core gate still debounces onset and silence.
        // Give that gate a binary level so it cannot learn the speaker as a second noise floor.
        let margin: Float = interruption ? 12 : (active ? 3 : 6)
        let minimum: Float = active && !interruption ? -73 : -70
        let audible = level > max(floor + margin, minimum)
        let event = gate.feed(level: audible ? -30 : -80, at: time)
        switch event {
        case .speechStarted: active = true
        case .speechEnded: active = false
        case nil: break
        }
        return event
    }
}
