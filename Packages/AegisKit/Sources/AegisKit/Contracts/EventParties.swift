import Foundation

// MARK: - v0.2: who the message is between

extension Event {
    /// The v0.2 rules about the parties: outgoing exactly when the sender is "me", a notification is never
    /// outgoing, handles and recipients are non-empty and unique, and a matched contact is complete.
    func partyErrors() -> [String] {
        var errors: [String] = []
        if (direction == .outgoing) != (sender == "me") {
            errors.append("/direction: outgoing exactly when sender is \"me\"")
        }
        if source == .notification, direction == .outgoing {
            errors.append("/direction: a notification is never outgoing")
        }
        if senderHandle?.isEmpty == true {
            errors.append("/sender_handle: shorter than 1")
        }
        if recipients.contains(where: \.isEmpty) {
            errors.append("/recipients: items must not be empty")
        }
        if Set(recipients).count != recipients.count {
            errors.append("/recipients: items must be unique")
        }
        if let contact = senderContact, contact.id.isEmpty || contact.name.isEmpty {
            errors.append("/sender_contact: id and name must not be empty")
        }
        if senderContact != nil, flags.contains(.ambiguousSender) {
            errors.append("/sender_contact: must be null when the sender is ambiguous")
        }
        return errors
    }
}

/// Fills in v0.2's fields for a v0.1 event, from what v0.1 already said. Stage 0 wrote "me" for the owner's
/// own messages and the raw handle as the sender for Messages and SMS. For email, the handle is the
/// address in the From text. Nothing is guessed from message bodies, and no contact is matched.
func migrate(fromV01 event: Event) -> Event {
    var migrated = event
    migrated.direction = event.sender == "me" ? .outgoing : .incoming
    migrated.recipients = []
    migrated.senderContact = nil
    switch (event.source, event.sender) {
    case (_, "me"), (.notification, _), (_, nil):
        migrated.senderHandle = nil
    case let (.email, sender?):
        migrated.senderHandle = emailAddress(in: sender)
    case let (_, sender?):
        migrated.senderHandle = sender.isEmpty ? nil : sender
    }
    return migrated
}

/// The address in `Name <address>`, or the whole text when it is itself an address; nil otherwise.
func emailAddress(in text: String) -> String? {
    if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
        let address = text[text.index(after: open) ..< close].trimmingCharacters(in: .whitespaces)
        return address.contains("@") ? address : nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.contains("@") && !trimmed.contains(" ") ? trimmed : nil
}
