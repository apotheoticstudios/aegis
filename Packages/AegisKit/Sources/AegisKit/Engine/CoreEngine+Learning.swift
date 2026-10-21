import Foundation

/// Automatic memory (#282), after OpenJarvis's MemoryService (memory/service.py, Apache-2.0): once a chat goes
/// quiet, the still-loaded local model reads what the owner said and keeps lasting facts. Only the owner's own
/// words are read, never Aegis's replies or collected content; nothing leaves the Mac; a new question cancels it.
extension CoreEngine {
    /// Queues the owner's chat line and starts the quiet timer again.
    func queueLearning(_ owner: String) {
        guard memory.learningPaused != true, FactExtractor.worthReading(owner) else { return }
        learnQueue = Array((learnQueue + [owner]).suffix(FactExtractor.maxLines))
        let ticket = UUID()
        learnTicket = ticket
        let delay = options.learnDelay
        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self.learn(ticket)
        }
    }

    /// A new question: stop any learning pass so the owner never waits for it; its lines are read later.
    func pauseLearning() async {
        learnTicket = nil
        if let job = learnJobID {
            await model.cancel(jobID: job)
        }
    }

    /// One learning pass, if the chat is still quiet and nothing else is using the model.
    func learn(_ ticket: UUID) async {
        guard learnTicket == ticket, !learnQueue.isEmpty, questionJobID == nil, memory.learningPaused != true else { return }
        let lines = learnQueue
        let scanner = InjectionScanner()
        // As in OpenJarvis, a severe finding (pasted "ignore previous instructions" text) drops the batch unread.
        if let level = scanner.scan(lines.joined(separator: "\n")).threatLevel, level >= .high {
            learnQueue = []
            return
        }
        guard let job = try? FactExtractor.job(owner: lines, model: options.modelName, now: clock()), job.validate().isEmpty
        else {
            learnQueue = []
            return
        }
        await acquire()
        defer { release() }
        guard learnTicket == ticket, questionJobID == nil else { return }
        learnJobID = job.id
        let result = try? await model.run(job)
        learnJobID = nil
        guard learnTicket == ticket, let result, result.status == .completed, let text = result.text else { return }
        learnQueue.removeAll { lines.contains($0) }
        learnTicket = nil
        let facts = FactExtractor.parse(text)
        guard !facts.isEmpty, memory.learningPaused != true else { return }
        // Per fact, not per batch: a flagged fact is quarantined while clean ones stay usable.
        let flagged = facts.filter { !scanner.scan($0).isClean }
        let previous = memory
        guard memory.learn(facts.filter { !flagged.contains($0) }, quarantined: flagged, now: clock()) > 0 else { return }
        if !saveMemory() {
            memory = previous
        }
        if memory.reflectionDue {
            await reflect()
        }
    }

    /// Hindsight-style reflection (#315), while the model is still loaded: a few observations from the owner's notes.
    /// A new question cancels it; it tries again after the next learning pass.
    func reflect() async {
        guard questionJobID == nil, let job = try? Reflection.job(notes: memory.reflectionNotes, model: options.modelName, now: clock()),
              job.validate().isEmpty
        else { return }
        learnJobID = job.id
        let result = try? await model.run(job)
        learnJobID = nil
        guard let result, result.status == .completed, let text = result.text, memory.learningPaused != true else { return }
        let scanner = InjectionScanner()
        let previous = memory
        memory.reflect(FactExtractor.parse(text).filter { scanner.scan($0).isClean }, now: clock())
        if !saveMemory() {
            memory = previous
        }
    }
}
