import AegisKit
import Foundation
import MacSources

/// The owner's contacts as an index for naming senders, re-read at most every 10 minutes and only while
/// Contacts access is granted (the app's grant reaches AegisCore, #66). Minimal keys only (MacSources);
/// nothing about a contact is logged.
actor ContactsCache: ContactsProvider {
    private let source = ContactsSource()
    private var cached: (index: ContactIndex, at: Date)?

    func index() async -> ContactIndex? {
        if let cached, Date().timeIntervalSince(cached.at) < 600 {
            return cached.index
        }
        let (status, contacts) = source.snapshots()
        guard status.ok else {
            cached = nil
            return nil
        }
        let index = ContactIndex(contacts)
        cached = (index, Date())
        return index
    }
}
