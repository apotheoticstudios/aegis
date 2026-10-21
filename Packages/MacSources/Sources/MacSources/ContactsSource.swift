import AegisKit
import Contacts
import Foundation

/// Reads contact cards for sender identity (#92's `ContactIndex`). Fetches only the identifier, names,
/// phone numbers and email addresses. Never asks for access itself, and never logs a name or number.
public final class ContactsSource: @unchecked Sendable {
    private let store = CNContactStore()

    public init() {}

    /// All cards, or the reason they couldn't be read.
    public func snapshots() -> (status: SourceStatus, contacts: [ContactSnapshot]) {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return (SourceStatus(ok: false, code: .permissionDenied), [])
        }
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        var contacts: [ContactSnapshot] = []
        // The owner's own card (#218): its numbers and addresses are the owner's, never a sender's.
        let me = try? store.unifiedMeContactWithKeys(toFetch: [CNContactIdentifierKey as CNKeyDescriptor]).identifier
        do {
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                var snapshot = ContactsMapping.snapshot(ContactCard(contact: contact))
                if contact.identifier == me {
                    snapshot.isMe = true
                }
                contacts.append(snapshot)
            }
        } catch {
            return (SourceStatus(ok: false, code: .unreadable), [])
        }
        return (SourceStatus(ok: true, code: contacts.isEmpty ? .noData : .ok, count: contacts.count), contacts)
    }
}

/// `CNContact` as the mapping's values.
struct ContactCard: ContactValues {
    let contact: CNContact

    var identifier: String {
        contact.identifier
    }

    var givenName: String {
        contact.givenName
    }

    var familyName: String {
        contact.familyName
    }

    var organizationName: String {
        contact.organizationName
    }

    var phoneNumbers: [String] {
        contact.phoneNumbers.map(\.value.stringValue)
    }

    var emailAddresses: [String] {
        contact.emailAddresses.map { $0.value as String }
    }
}
