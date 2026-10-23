import AegisKit
import AppKit
import Contacts
import Foundation

/// A message the owner asked for (#276): who, how, what, and whether Aegis sends it.
struct MessageDraft {
    let channel: ActionMessageChannel
    let name: String
    let handle: String
    let text: String
    let subject: String?
}

/// Texts and emails from the owner's own words (#276). By default Aegis opens a ready-written draft in Messages or
/// Mail and the owner sends it; "… and send it" makes Aegis send it after two confirmations.
extension PanelModel {
    /// The reply to a message request, or nil when the question isn't one.
    func messageAnswer(_ question: String, origin: ActionOrigin) async -> Answer? {
        guard let command = MessageCommand.parse(question) else { return nil }
        let found = await Self.recipient(for: command)
        let draft: MessageDraft
        switch found {
        case let .failure(problem):
            return Self.said(problem.message)
        case let .success(match):
            note(question, nil, target: command.candidates.first { $0.body == match.body }?.name)
            draft = MessageDraft(
                channel: command.channel,
                name: match.name,
                handle: match.handle,
                text: match.body,
                subject: command.subject
            )
        }
        if command.send {
            let request = ActionRequest(payload: Self.payload(draft, verb: .send), origin: origin)
            let summary = MessageCommand.summary(
                channel: draft.channel,
                to: draft.name,
                text: draft.text,
                subject: draft.subject,
                send: true
            )
            guard await proposeMessage(draft, request: request, text: summary) else {
                return Self.said("I won't send that one myself. I can open it as a draft instead: say it again without “send it”.")
            }
            return Self.said(summary + " Press Send, or say yes.")
        }
        return await Self.said(openDraft(draft, origin: origin))
    }

    /// Opens the message in Messages or Mail, written and addressed, for the owner to send.
    private func openDraft(_ draft: MessageDraft, origin: ActionOrigin) async -> String {
        let request = ActionRequest(payload: Self.payload(draft, verb: .open), origin: origin)
        await logMessage(request, .proposed)
        var parts = URLComponents()
        if draft.channel == .email {
            parts.scheme = "mailto"
            parts.path = draft.handle
            parts.queryItems = [URLQueryItem(name: "subject", value: draft.subject ?? ""), URLQueryItem(name: "body", value: draft.text)]
        } else {
            parts.scheme = "sms"
            parts.path = draft.handle.filter { !$0.isWhitespace } + "&body=" + draft.text
        }
        guard let url = parts.url, NSWorkspace.shared.open(url) else {
            await logMessage(request, .failed)
            return "I couldn't open that draft."
        }
        await logMessage(request, .succeeded)
        return draft.channel == .email ? "It's ready in Mail to \(draft.name). Check it and press Send."
            : "It's ready in Messages to \(draft.name): “\(draft.text)”. Check it and press Send."
    }

    /// Sends it through Messages or Mail (Apple Events; macOS asks once). Nil when sent, otherwise what to say.
    static func send(_ draft: MessageDraft) async -> String? {
        let script = draft.channel == .email
            ? """
            on run argv
              tell application "Mail"
                set theMessage to make new outgoing message with properties {subject:item 2 of argv, content:item 3 of argv, visible:false}
                tell theMessage to make new to recipient at end of to recipients with properties {address:item 1 of argv}
                send theMessage
              end tell
            end run
            """
            : """
            on run argv
              tell application "Messages"
                try
                  send item 2 of argv to participant (item 1 of argv) of (1st account whose service type = iMessage)
                on error
                  send item 2 of argv to participant (item 1 of argv) of (1st account whose service type = SMS)
                end try
              end tell
            end run
            """
        let arguments = draft.channel == .email ? [draft.handle, draft.subject ?? "", draft.text] : [draft.handle, draft.text]
        let app = draft.channel == .email ? "Mail" : "Messages"
        return await osascript(script, arguments) ? nil
            : "It didn't send. Check that Aegis may control \(app) (Privacy & Security › Automation), then try again."
    }

    static func payload(_ draft: MessageDraft, verb: ActionVerb) -> ActionPayload {
        .message(recipientHandle: draft.handle, text: draft.text, channel: draft.channel, verb: verb)
    }

    @discardableResult
    func logMessage(_ request: ActionRequest, _ outcome: ActionOutcomeCode) async -> ActionDecision {
        let decision = ActionPolicy.decision(for: request, settings: .init(panelIsOpen: true))
        try? await actions?.append(ActionLogEntry(time: Date(), request: request, decision: decision, outcomeCode: outcome))
        return decision
    }

    private func proposeMessage(_ draft: MessageDraft, request: ActionRequest, text: String) async -> Bool {
        let decision = await logMessage(request, .proposed)
        guard decision.allowed else { return false }
        ActionPresence.shared.pending = PendingAction(command: nil, message: draft, request: request, text: text, at: Date(), needed: 2)
        await logMessage(request, .awaitingConfirmation)
        return true
    }

    // MARK: - Contacts

    private struct Match {
        let name: String
        let handle: String
        let body: String
    }

    private struct Problem: Error {
        let message: String
    }

    /// The first way of reading the name that matches exactly one contact with a usable address.
    private static func recipient(for command: MessageCommand) async -> Result<Match, Problem> {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return .failure(
                Problem(message: "I'm not allowed to look in your contacts. Allow Aegis under Contacts in Privacy & Security.")
            )
        }
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        var ambiguous: [String] = []
        for candidate in command.candidates {
            let people = ((try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: candidate.name),
                keysToFetch: keys
            )) ?? [])
                .filter { handle(of: $0, channel: command.channel) != nil }
            let exact = people.filter { fullName($0).lowercased() == candidate.name.lowercased() }
            let chosen = exact.count == 1 ? exact : people
            if chosen.count == 1, let person = chosen.first, let address = handle(of: person, channel: command.channel) {
                return .success(Match(name: fullName(person), handle: address, body: candidate.body))
            }
            if chosen.count > 1, ambiguous.isEmpty {
                ambiguous = chosen.prefix(3).map(fullName)
            }
        }
        if !ambiguous.isEmpty {
            return .failure(Problem(message: "Which one: " + ambiguous.joined(separator: ", ") + "? Say it again with the full name."))
        }
        let name = command.candidates.last?.name ?? "them"
        return .failure(Problem(message: "I couldn't find \(name) in your contacts" +
                (command.channel == .email ? " with an email address." : ".")))
    }

    private static func fullName(_ person: CNContact) -> String {
        let name = [person.givenName, person.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? (person.nickname.isEmpty ? person.organizationName : person.nickname) : name
    }

    /// A mobile number for texts (else any number, else an email for iMessage); an email address for email.
    private static func handle(of person: CNContact, channel: ActionMessageChannel) -> String? {
        if channel == .email {
            return person.emailAddresses.first.map { String($0.value) }
        }
        let mobile = person.phoneNumbers.first { [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone].contains($0.label ?? "") }
        return (mobile ?? person.phoneNumbers.first)?.value.stringValue ?? person.emailAddresses.first.map { String($0.value) }
    }
}
