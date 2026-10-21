import AegisKit
import Foundation

/// What the mapping needs from one contact card: the minimal keys only (no notes, addresses, birthdays or
/// photos are ever fetched).
public protocol ContactValues {
    var identifier: String { get }
    var givenName: String { get }
    var familyName: String { get }
    var organizationName: String { get }
    var phoneNumbers: [String] { get }
    var emailAddresses: [String] { get }
}

public enum ContactsMapping {
    /// A `ContactSnapshot` for #92's `ContactIndex`. The name is "given family", else the organisation;
    /// an empty name is fine (the index falls back to the handle).
    public static func snapshot(_ values: some ContactValues) -> ContactSnapshot {
        let person = [values.givenName, values.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = person.isEmpty ? values.organizationName.trimmingCharacters(in: .whitespacesAndNewlines) : person
        return ContactSnapshot(id: values.identifier, displayName: name, phones: values.phoneNumbers, emails: values.emailAddresses)
    }
}
