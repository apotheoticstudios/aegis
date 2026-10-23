import Foundation

/// The domain whose executor handles a request.
public enum ActionDomain: String, Codable, Sendable, CaseIterable {
    case message, home, app, file, calendar, reminder, system
    /// The owner's own shortcuts, by name, and websites (ADR-0031, additive).
    case shortcut, web
}

/// Closed operation vocabulary: arbitrary scripts and UI commands are not accepted; a shortcut runs only by the
/// name of one the owner has (ADR-0031). Forbidden operations are representable so the policy can reject and audit them.
public enum ActionVerb: String, Codable, Sendable, CaseIterable {
    case read, open, create, send, edit, move, delete, run
    case payment, purchase, moneyTransfer, changePassword, accessCredentials
}

/// Messages and email share the same outward-facing safety policy.
public enum ActionMessageChannel: String, Codable, Sendable {
    case message, email
}

/// Semantic accessory characteristics, resolved from trusted device metadata by a future adapter.
public enum ActionHomeCharacteristic: String, Codable, Sendable, CaseIterable {
    case light, scene, plug, thermostat, blinds, doorLock, garageDoor
}

/// System settings are a closed vocabulary; security, privacy and credentials are always forbidden.
public enum ActionSystemSetting: String, Codable, Sendable, CaseIterable {
    case volume, appearance, focus, security, privacy, password, credentials
}

/// A typed characteristic or setting value. Text is data and cannot name an operation.
public enum ActionValue: Codable, Sendable, Hashable {
    case boolean(Bool), number(Double), text(String)
}

/// Minimal typed arguments per domain; an enum prevents domain/payload mismatches.
/// The owner command adapter must resolve semantics, never reinterpret text as executable code.
public enum ActionPayload: Codable, Sendable, Hashable {
    case message(recipientHandle: String, text: String, channel: ActionMessageChannel = .message, verb: ActionVerb = .send)
    case home(accessory: String, characteristic: ActionHomeCharacteristic, value: ActionValue, verb: ActionVerb = .edit)
    case app(bundleID: String, verb: ActionVerb)
    case file(path: String, verb: ActionVerb)
    case calendar(title: String, start: Date, end: Date, verb: ActionVerb = .create)
    case reminder(title: String, due: Date?, verb: ActionVerb = .create)
    case system(setting: ActionSystemSetting, value: ActionValue, verb: ActionVerb = .edit)
    /// One of the owner's shortcuts, by its exact name (ADR-0031).
    case shortcut(name: String, verb: ActionVerb = .run)
    /// An http(s) address for the owner's browser (ADR-0031).
    case website(url: String, verb: ActionVerb = .open)

    public var domain: ActionDomain {
        switch self {
        case .message: .message
        case .home: .home
        case .app: .app
        case .file: .file
        case .calendar: .calendar
        case .reminder: .reminder
        case .system: .system
        case .shortcut: .shortcut
        case .website: .web
        }
    }

    public var verb: ActionVerb {
        switch self {
        case let .message(_, _, _, verb), let .home(_, _, _, verb),
             let .calendar(_, _, _, verb), let .system(_, _, verb): verb
        case let .app(_, verb), let .file(_, verb), let .reminder(_, _, verb),
             let .shortcut(_, verb), let .website(_, verb): verb
        }
    }

    /// Each field is inspected separately so another field cannot hide a sentence-start instruction.
    var textFields: [String] {
        switch self {
        case let .message(handle, text, _, _): [handle, text]
        case let .home(accessory, _, value, _): [accessory] + value.textFields
        case let .app(bundleID, _): [bundleID]
        case let .file(path, _): [path]
        case let .shortcut(name, _): [name]
        case let .website(url, _): [url]
        case let .calendar(title, _, _, _), let .reminder(title, _, _): [title]
        case let .system(_, value, _): value.textFields
        }
    }
}

extension ActionValue {
    var textFields: [String] {
        if case let .text(text) = self {
            return [text]
        }
        return []
    }
}
