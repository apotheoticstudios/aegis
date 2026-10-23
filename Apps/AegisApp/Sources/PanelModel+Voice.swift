import AegisKit
import Foundation

/// Voice controls for the visible panel.
extension PanelModel {
    /// Sends a question to AegisCore and shows its answer (about 10 to 30 seconds with the model).
    func ask(_ question: String) async {
        await answerQuestion(question, spoken: false)
    }

    /// A spoken question: asked like a typed one, and the answer read aloud.
    func askAloud(_ question: String) async {
        await answerQuestion(question, spoken: true)
    }

    func answerQuestion(_ question: String, spoken: Bool) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = beginQuestion(trimmed)
        defer { finishQuestion(id) }
        let stream = streamReply(id, spoken: spoken)
        await requestAnswer(trimmed, id: id)
        stream.cancel()
        let streamed = await stream.value
        partialAnswer = ""
        await finishAnswer(id, spoken: spoken, streamed: streamed)
    }

    /// Speaking while thinking (#263): while the model writes, AegisCore's finished, checked sentences are shown
    /// and, for a spoken question, spoken one by one. Returns what was spoken.
    private func streamReply(_ id: UUID, spoken: Bool) -> Task<String, Never> {
        Task { [weak self] in
            var said = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, isCurrentQuestion(id) else { break }
                guard case let .partialReply(text) = await service.handle(.partialReply), !Task.isCancelled,
                      text.count > said.count, text.hasPrefix(said)
                else { continue }
                partialAnswer = text
                if spoken {
                    if said.isEmpty {
                        voice.beginStreaming()
                    }
                    voice.continueStreaming(String(text.dropFirst(said.count)).trimmingCharacters(in: .whitespaces))
                }
                said = text
            }
            return spoken ? said : ""
        }
    }

    /// Speak and release the listener before fetching nonessential citation or memory views.
    func finishAnswer(_ id: UUID, spoken: Bool, streamed: String = "") async {
        guard isCurrentQuestion(id) else {
            if !streamed.isEmpty {
                voice.endStreaming()
            }
            return
        }
        if spoken {
            if streamed.isEmpty {
                speakAnswer(id)
            } else {
                finishStreamedAnswer(streamed)
            }
        }
        let answer: Answer? = if case let .answered(_, value) = askState {
            value
        } else {
            nil
        }
        finishQuestion(id)
        if let answer {
            await loadSources(ids: answer.eventIDs)
            if answer.model == "memory" {
                await reloadMemories()
                await reloadMemoryViews()
            }
        }
    }

    /// The rest of a reply that was partly spoken while it was written.
    private func finishStreamedAnswer(_ streamed: String) {
        let rest: String = switch askState {
        case let .answered(_, answer) where answer.text.hasPrefix(streamed):
            String(answer.text.dropFirst(streamed.count))
        case let .answered(_, answer) where answer.text == Chat.fallback || answer.text == Chat.cannotAct:
            answer.text
        case let .failed(_, message):
            message
        default:
            ""
        }
        voice.continueStreaming(rest.trimmingCharacters(in: .whitespacesAndNewlines))
        voice.endStreaming()
    }

    func speakAnswer(_ id: UUID) {
        guard isCurrentQuestion(id) else { return }
        switch askState {
        case let .answered(_, answer):
            voice.speak(Self.isHandOff(answer) ? CloudHandOff.spoken(answer.text) : answer.text)
        case let .failed(_, message):
            voice.speak(message)
        default: break
        }
    }

    /// Starts listening (the talk hotkey); the words are asked and the answer spoken.
    func talk() async {
        await voice.listen { [weak self] words in
            Task { await self?.submit(words, spoken: true) }
        }
    }

    /// The owner took the turn; keep the visible exchange but stop every pending playback path.
    func interruptSpeech() {
        voice.stopSpeaking()
    }

    /// "Read": the brief aloud, or stop if it's already speaking.
    func readBrief(now: Date = Date()) {
        if voice.speaking {
            voice.stopSpeaking()
        } else if let brief = stored?.brief {
            let world = WorldPresence.shared.briefLines.joined(separator: " ")
            let spoken = BriefPresentation.spoken(brief, now: now, calendar: .current) + (world.isEmpty ? "" : " " + world)
            remember(Exchange(question: "Read the brief", answer: Self.said(spoken), failure: nil))
            voice.speak(spoken)
        }
    }

    /// Ends the spoken conversation at the owner's request, without dismissing unfinished work; CHAT keeps its transcript.
    func endVoiceConversation() {
        guard pendingTask == nil, runningTask == nil else { return }
        // Follow-ups end with the conversation (#49).
        ActionPresence.shared.context = nil
        clearAnswer()
    }

    /// The panel closed: nothing listens or speaks while it's closed (silent rule).
    func panelClosed() {
        // The globe and its server live only for this open panel session.
        WorldWindow.shared.panelClosed()
        clearAnswer()
        voice.silence()
    }
}
