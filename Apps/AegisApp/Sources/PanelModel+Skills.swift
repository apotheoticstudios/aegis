import AegisKit
import Foundation
import Observation

/// A skill stopped at a step that needs the owner's OK, to carry on after Add or "yes".
@MainActor
@Observable
final class SkillPresence {
    static let shared = SkillPresence()
    @ObservationIgnored var paused: PausedSkill?
}

/// Where a paused skill carries on.
struct PausedSkill {
    let skill: SkillManifest
    let next: Int
    let context: [String: String]
    let at: Date
}

/// The owner's skills (#285, #286): saved lists of their own commands in OpenJarvis's SKILL.md format, kept in
/// Aegis's folder on this Mac. Running one sends each step through the panel's usual path, so every action keeps
/// its confirmations; a step that needs one pauses the skill until the owner answers.
extension PanelModel {
    /// The skills folder: ~/Library/Application Support/Aegis/skills/<name>/SKILL.md.
    static var skillsFolder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Aegis/skills", isDirectory: true)
    }

    static func skillBook() -> SkillBook {
        var book = SkillBook()
        for skill in skillsFolder.map(SkillFile.discover) ?? [] {
            try? book.add(skill)
        }
        return book
    }

    /// Skills scheduled for today whose time has come, for the morning routine.
    func dueSkillNames(now: Date = Date()) -> [String] {
        Self.skillBook().due(on: now, calendar: .current).filter { skill in
            skill.schedule?.time(on: now, calendar: .current).map { $0 <= now } ?? false
        }
        .prefix(10).map(\.name)
    }

    /// A reply to a skill command or trigger phrase; nil when the question is neither.
    func skillAnswer(_ question: String) async -> Answer? {
        let book = Self.skillBook()
        if let skill = book.skill(forTrigger: question) {
            return await Self.said(run(skill, from: 0, context: [:]))
        }
        guard let command = SkillCommand.parse(question) else { return nil }
        switch command {
        case let .run(name):
            // "Do my homework" isn't a skill unless the owner made one called that.
            guard let skill = book.skill(named: name) else { return nil }
            return await Self.said(run(skill, from: 0, context: [:]))
        case let .create(name, steps):
            return Self.said(save(SkillManifest(name: name, description: "Made by voice", steps: steps.map { SkillStep(command: $0) })))
        case let .saveRecent(name, count):
            let recent = thread.suffix(count + 1).map(\.question).filter { SkillCommand.parse($0) == nil }.suffix(count)
            guard !recent.isEmpty else { return Self.said("There's nothing recent to save yet.") }
            return Self.said(save(SkillManifest(
                name: name,
                description: "Saved from our chat",
                steps: recent.map { SkillStep(command: $0) }
            )))
        case .list:
            let names = book.skills.map { $0.name.replacingOccurrences(of: "-", with: " ") }
            return Self.said(
                names.isEmpty ? "You don't have any skills yet. Say “create a skill called morning: what's the weather, then catch me up”."
                    : "Your skills: " + names.joined(separator: ", ") + "."
            )
        case let .show(name):
            guard let skill = book.skill(named: name) else { return Self.said("I don't have a skill called \(name).") }
            let steps = skill.steps.enumerated().map { "\($0.offset + 1), \($0.element.command)" }.joined(separator: "; ")
            let when = skill.schedule.map { " It runs \($0.description)." } ?? ""
            return Self.said("Your \(name) skill: \(steps).\(when)")
        case let .delete(name):
            guard book.skill(named: name) != nil, let folder = Self.skillsFolder?.appendingPathComponent(name) else {
                return Self.said("I don't have a skill called \(name).")
            }
            // To the Trash, so it can be put back.
            guard (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) != nil else {
                return Self.said("I couldn't remove that skill.")
            }
            return Self.said("Done. The \(name) skill is in the Trash.")
        case let .schedule(name, schedule):
            guard var skill = book.skill(named: name) else { return Self.said("I don't have a skill called \(name).") }
            var aegis: [String: SkillValue] = [:]
            if case let .map(existing)? = skill.metadata["aegis"] {
                aegis = existing
            }
            aegis["schedule"] = .string(schedule.description)
            skill.metadata["aegis"] = .map(aegis)
            return Self.said(save(skill, saying: "Done. I'll offer your \(name) skill \(schedule.description) in your morning routine."))
        }
    }

    /// A scheduled skill the owner approved in the morning routine: shown and read out like an answer.
    func runSkill(named name: String) async -> Bool {
        guard let skill = Self.skillBook().skill(named: name) else { return false }
        let reply = await run(skill, from: 0, context: [:])
        let asked = "Morning routine: \(name.replacingOccurrences(of: "-", with: " "))"
        askState = .answered(question: asked, answer: Self.said(reply))
        remember(Exchange(question: asked, answer: Self.said(reply), failure: nil))
        voice.speak(reply)
        return true
    }

    /// Carries on a paused skill after its step was confirmed or cancelled; "" when none is paused.
    func resumeSkill() async -> String {
        guard let paused = SkillPresence.shared.paused, Date().timeIntervalSince(paused.at) < 600 else { return "" }
        SkillPresence.shared.paused = nil
        return await run(paused.skill, from: paused.next, context: paused.context)
    }

    /// Runs the steps from `index`; stops at a step that's waiting for the owner's OK.
    private func run(_ skill: SkillManifest, from index: Int, context: [String: String]) async -> String {
        var context = context
        var said: [String] = []
        let now = Date()
        context["date"] = now.formatted(date: .complete, time: .omitted)
        context["time"] = now.formatted(date: .omitted, time: .shortened)
        context["weekday"] = now.formatted(.dateTime.weekday(.wide))
        for (offset, step) in skill.steps.enumerated().dropFirst(index) {
            let line = SkillTemplate.render(step.command, context: context)
            // A skill never starts another skill.
            guard SkillCommand.parse(line) == nil, Self.skillBook().skill(forTrigger: line) == nil else { continue }
            let answer = await stepAnswer(line)
            said.append(answer)
            context["previous"] = answer
            if ActionPresence.shared.pending != nil {
                if offset + 1 < skill.steps.count {
                    SkillPresence.shared.paused = PausedSkill(skill: skill, next: offset + 1, context: context, at: Date())
                }
                return said.joined(separator: " ")
            }
        }
        return said.isEmpty ? "That skill has nothing for me to do." : said.joined(separator: " ")
    }

    /// One step, answered the way the Ask bar would answer it.
    private func stepAnswer(_ line: String) async -> String {
        if let local = await worldAnswer(line) {
            return local.text
        }
        switch await service.handle(.ask(question: line)) {
        case let .answer(answer): return answer.text
        case let .refused(code): return BriefPresentation.askMessage(code)
        default: return BriefPresentation.askMessage("bad_reply")
        }
    }

    private func save(_ skill: SkillManifest, saying done: String? = nil) -> String {
        guard let folder = Self.skillsFolder?.appendingPathComponent(skill.name, isDirectory: true) else {
            return "I couldn't save that skill."
        }
        var check = Self.skillBook()
        do {
            try check.add(skill)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(SkillFile.render(skill).utf8).write(to: folder.appendingPathComponent("SKILL.md"), options: .atomic)
        } catch {
            return "I couldn't save that skill: a skill can have up to 12 steps, and you can keep up to 50 skills."
        }
        let spoken = skill.name.replacingOccurrences(of: "-", with: " ")
        return done ?? "Saved your \(spoken) skill with \(skill.steps.count) step\(skill.steps.count == 1 ? "" : "s"). Say “run my \(spoken) skill” to use it."
    }
}
