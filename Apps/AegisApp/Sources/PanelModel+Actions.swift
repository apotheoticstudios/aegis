import AegisKit
import AppKit
import EventKit
import Foundation
import Observation

/// An action waiting for the owner's Add (#270), and what Aegis last added, for "move it to 6 pm" (#274).
@MainActor
@Observable
final class ActionPresence {
    static let shared = ActionPresence()
    var pending: PendingAction?
    @ObservationIgnored var lastAdded: AddedItem?
}

/// An action shown on a card, waiting for Add or "yes".
struct PendingAction {
    /// A reminder, event, move or app; nil for a message.
    let command: ActionCommand?
    var message: MessageDraft?
    let request: ActionRequest
    let text: String
    let at: Date
    /// Confirmations the policy's tier asks for: two to send a message (#276), one otherwise.
    var needed = 1
    var given = 0

    init(command: ActionCommand?, message: MessageDraft? = nil, request: ActionRequest, text: String, at: Date, needed: Int = 1) {
        self.command = command
        self.message = message
        self.request = request
        self.text = text
        self.at = at
        self.needed = needed
    }

    /// The card's button.
    var button: String {
        message != nil ? (given == 0 ? "Send" : "Send now") : "Add"
    }
}

/// What Aegis last added, by its EventKit identifier.
struct AddedItem {
    let id: String
    let isReminder: Bool
    let title: String
    let at: Date
}

/// Actions from the owner's own words (#270, #274): reminders and events, opening apps, moving what was just added.
/// Each is judged by the action-safety policy and logged; anything above the automatic tier waits for Add or "yes".
extension PanelModel {
    /// The reply to an action request or to a waiting card, or nil when the question isn't one.
    func actionAnswer(_ question: String, origin: ActionOrigin = .ownerTyped) async -> Answer? {
        let presence = ActionPresence.shared
        if let pending = presence.pending, Date().timeIntervalSince(pending.at) < 300, let yes = ActionReply.parse(question) {
            let done: String
            if yes {
                done = await performPending()
            } else {
                await cancelAction()
                done = "Cancelled."
            }
            // A skill paused at this step carries on (#286).
            let more = await resumeSkill()
            return Self.said(more.isEmpty ? done : done + " " + more)
        }
        if let routine = await routineAnswer(question, origin: origin) {
            return routine
        }
        if let skill = await skillAnswer(question) {
            return skill
        }
        guard let command = ActionCommand.parse(question, now: Date(), calendar: .current) else {
            return await messageAnswer(question, origin: origin)
        }
        switch command {
        case let .openApp(name):
            guard let app = Self.application(named: name) else { return nil }
            return await Self.said(openApp(app, name: name, origin: origin))
        case .removeLast:
            await log(ActionRequest(payload: command.payload, origin: origin), .rejected)
            return Self.said("I can't delete things: that's on my never-list. You can remove it in Reminders or Calendar.")
        case let .moveLast(date, _):
            guard let last = presence.lastAdded, Date().timeIntervalSince(last.at) < 1800 else {
                return Self.said("I can only move something I've just added.")
            }
            let payload: ActionPayload = last.isReminder ? .reminder(title: last.title, due: date, verb: .edit)
                : .calendar(title: last.title, start: date, end: date, verb: .edit)
            let text = "Move “\(last.title)” to " + String(command.summary(calendar: .current).dropFirst("Move it to ".count))
            guard await propose(command, request: ActionRequest(payload: payload, origin: origin), text: text) != nil else {
                return Self.said("That's not something I can do.")
            }
            return Self.said(text + " Say yes, or press Add.")
        case .reminder, .event:
            let request = ActionRequest(payload: command.payload, origin: origin)
            let text = command.summary(calendar: .current)
            guard await propose(command, request: request, text: text) != nil else { return Self.said("That's not something I can do.") }
            return Self.said(text + " Say yes, or press Add.")
        }
    }

    /// The owner pressed Add.
    func confirmAction() async {
        let done = await performPending()
        let more = await resumeSkill()
        let reply = more.isEmpty ? done : done + " " + more
        askState = .answered(question: "Add", answer: Self.said(reply))
        remember(Exchange(question: "Add", answer: Self.said(reply), failure: nil))
        voice.speak(reply)
    }

    /// The owner pressed Cancel, or said no.
    func cancelAction() async {
        guard let pending = ActionPresence.shared.pending else { return }
        ActionPresence.shared.pending = nil
        await log(pending.request, .cancelled)
    }

    // MARK: - Steps

    private func propose(_ command: ActionCommand, request: ActionRequest, text: String) async -> Void? {
        let decision = await log(request, .proposed)
        guard decision.allowed else { return nil }
        ActionPresence.shared.pending = PendingAction(command: command, request: request, text: text, at: Date())
        await log(request, .awaitingConfirmation)
        return ()
    }

    private func performPending() async -> String {
        guard var pending = ActionPresence.shared.pending else { return "There's nothing waiting to add." }
        // Sending asks twice (#276).
        if pending.given + 1 < pending.needed {
            pending.given += 1
            ActionPresence.shared.pending = pending
            return "Sure? It goes to \(pending.message?.name ?? "them") as soon as you press Send now, or say yes."
        }
        ActionPresence.shared.pending = nil
        if let message = pending.message {
            let failure = await Self.send(message)
            await logMessage(pending.request, failure == nil ? .succeeded : .failed)
            return failure ?? "Sent to \(message.name)."
        }
        guard let command = pending.command else { return "There's nothing waiting to add." }
        let failure: String? = switch command {
        case let .moveLast(date, allDay):
            await Self.move(to: date, allDay: allDay)
        default:
            await Self.add(command)
        }
        await log(pending.request, failure == nil ? .succeeded : .failed)
        await refresh()
        if let failure {
            return failure
        }
        switch command {
        case .reminder: return "Done. It's in Reminders."
        case .moveLast: return "Done. It's moved."
        default: return "Done. It's in your calendar."
        }
    }

    private func openApp(_ app: URL, name: String, origin: ActionOrigin) async -> String {
        let request = ActionRequest(payload: .app(bundleID: Bundle(url: app)?.bundleIdentifier ?? name, verb: .open), origin: origin)
        let decision = await log(request, .proposed)
        guard decision.tier == .auto else { return "That's not something I can do." }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = await (try? NSWorkspace.shared.openApplication(at: app, configuration: configuration)) != nil
        await log(request, opened ? .succeeded : .failed)
        return opened ? "Opening \(app.deletingPathExtension().lastPathComponent)." : "I couldn't open that."
    }

    @discardableResult
    func log(_ request: ActionRequest, _ outcome: ActionOutcomeCode) async -> ActionDecision {
        let decision = ActionPolicy.decision(
            for: request,
            settings: .init(panelIsOpen: true, minimumTier: request.payload.verb == .open ? .auto : .confirm)
        )
        try? await actions?.append(ActionLogEntry(time: Date(), request: request, decision: decision, outcomeCode: outcome))
        return decision
    }

    static func said(_ text: String) -> Answer {
        Answer(text: text, eventIDs: [], scheduleIDs: [], model: "aegis", generatedAt: Date())
    }

    /// An app by name in the usual folders: an exact name first, then one that starts with it.
    static func application(named name: String) -> URL? {
        let aliases = [
            "email": "mail", "my email": "mail", "emails": "mail", "texts": "messages", "my messages": "messages",
            "browser": "safari", "the browser": "safari", "web browser": "safari", "settings": "system settings",
            "my calendar": "calendar", "my reminders": "reminders", "music": "music", "my music": "music",
            "photos": "photos", "my photos": "photos", "the terminal": "terminal", "maps": "maps", "notes": "notes",
        ]
        let spoken = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let wanted = aliases[spoken] ?? spoken
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        let apps = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        let base = { (url: URL) in url.deletingPathExtension().lastPathComponent.lowercased() }
        return apps.first { base($0) == wanted } ?? apps.first { base($0).hasPrefix(wanted) && wanted.count >= 3 }
    }

    // MARK: - EventKit

    /// Adds it; nil when done, otherwise what to say.
    static func add(_ command: ActionCommand) async -> String? {
        let store = EKEventStore()
        switch command {
        case let .reminder(title, due):
            guard await (try? store.requestFullAccessToReminders()) == true else {
                return "I'm not allowed to add reminders. Allow Aegis under Reminders in Privacy & Security."
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let due {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            guard (try? store.save(reminder, commit: true)) != nil else { return "Reminders didn't take that one. Try again?" }
            ActionPresence.shared.lastAdded = AddedItem(id: reminder.calendarItemIdentifier, isReminder: true, title: title, at: Date())
            return nil
        case let .event(title, start, end):
            guard await (try? store.requestFullAccessToEvents()) == true else {
                return "I'm not allowed to add events. Allow Aegis under Calendars in Privacy & Security."
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.isAllDay = end.timeIntervalSince(start) >= 86400 && Calendar.current.startOfDay(for: start) == start
            event.calendar = store.defaultCalendarForNewEvents
            guard (try? store.save(event, span: .thisEvent, commit: true)) != nil
            else { return "Your calendar didn't take that one. Try again?" }
            ActionPresence.shared.lastAdded = AddedItem(id: event.calendarItemIdentifier, isReminder: false, title: title, at: Date())
            return nil
        default:
            return "That's not something I can add."
        }
    }

    /// Moves what Aegis last added to a new time (an event keeps its length).
    private static func move(to date: Date, allDay: Bool) async -> String? {
        guard let last = ActionPresence.shared.lastAdded else { return "I can only move something I've just added." }
        let store = EKEventStore()
        if last.isReminder {
            guard await (try? store.requestFullAccessToReminders()) == true,
                  let reminder = store.calendarItem(withIdentifier: last.id) as? EKReminder
            else { return "I can't find that reminder any more." }
            let parts: Set<Calendar.Component> = allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: date)
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            reminder
                .addAlarm(EKAlarm(absoluteDate: allDay ? Calendar.current
                        .date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date : date))
            return (try? store.save(reminder, commit: true)) != nil ? nil : "Reminders didn't take the change."
        }
        guard await (try? store.requestFullAccessToEvents()) == true,
              let event = store.calendarItem(withIdentifier: last.id) as? EKEvent
        else { return "I can't find that event any more." }
        let length = max(event.endDate.timeIntervalSince(event.startDate), 1800)
        event.isAllDay = allDay
        event.startDate = date
        event.endDate = allDay ? date.addingTimeInterval(86400) : date.addingTimeInterval(length)
        return (try? store.save(event, span: .thisEvent, commit: true)) != nil ? nil : "Your calendar didn't take the change."
    }
}
