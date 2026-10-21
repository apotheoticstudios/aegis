import Contacts
import EventKit

/// Asks once for the access AegisCore uses (the grants reach it, #66): Contacts to name who messaged you,
/// Calendar and Reminders for today's schedule. Only asks while undecided, so "Don't Allow" is respected.
enum Permissions {
    static func requestIfNeeded() async {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        let events = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await events.requestFullAccessToEvents()
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await events.requestFullAccessToReminders()
        }
    }
}
