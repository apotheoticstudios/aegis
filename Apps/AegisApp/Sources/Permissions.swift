import AppKit
import Contacts
import EventKit

/// The access the setup wizard asks for (#26). The grants reach AegisCore (#66; ADR-0010 for Full Disk Access).
/// Asking shows the system's prompt only while undecided, so "Don't Allow" is respected; after that, Privacy &
/// Security's own pane is where it changes.
enum Permission: CaseIterable {
    case fullDisk, contacts, calendar, reminders

    var title: String {
        switch self {
        case .fullDisk: "Full Disk Access"
        case .contacts: "Contacts"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        }
    }

    var reason: String {
        switch self {
        case .fullDisk: "Reads Messages, Mail and notifications. Turn Aegis on in the list."
        case .contacts: "Shows who messaged you by name."
        case .calendar: "Puts today's events in your brief."
        case .reminders: "Puts today's reminders in your brief."
        }
    }

    var granted: Bool {
        switch self {
        case .fullDisk: Self.hasFullDiskAccess()
        case .contacts: CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    /// The system prompt while undecided; otherwise this permission's pane in Privacy & Security.
    func request() async {
        switch self {
        case .contacts where CNContactStore.authorizationStatus(for: .contacts) == .notDetermined:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .calendar where EKEventStore.authorizationStatus(for: .event) == .notDetermined:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders where EKEventStore.authorizationStatus(for: .reminder) == .notDetermined:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        default:
            let pane = switch self {
            case .fullDisk: "Privacy_AllFiles"
            case .contacts: "Privacy_Contacts"
            case .calendar: "Privacy_Calendars"
            case .reminders: "Privacy_Reminders"
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Opens and closes, without reading, a system file only Full Disk Access unlocks: the privacy settings' own
    /// database, not the owner's data. AegisCore's sources report too late for a live tick (they retry over minutes).
    private static func hasFullDiskAccess() -> Bool {
        let handle = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard handle >= 0 else { return false }
        close(handle)
        return true
    }
}
