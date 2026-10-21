import ApplicationServices
import Contacts
import EventKit
import Foundation

/// What one process can access. Statuses and counts only: no calendar, reminder or contact content is
/// read, kept or written. The owner runs this; its output is never committed.
public struct ProbeReport: Codable, Equatable {
    public var process: String
    public var pid: Int32
    public var parentPID: Int32
    public var time: String
    /// "allowed", "denied (<errno>)" or "invalid" (the protected folder doesn't exist).
    public var fullDiskAccess: String
    public var calendarStatus: String
    /// How many event calendars are visible (a number only), when access works.
    public var calendarCount: Int?
    public var remindersStatus: String
    public var reminderListCount: Int?
    public var contactsStatus: String
    /// "yes" if one contact identifier could be fetched with no fields; otherwise the error code.
    public var contactsReadable: String
    /// Stage 2 probe 0.1: "trusted" or "not trusted" for Accessibility (never prompts).
    public var accessibility: String?
    /// Stage 2 probe 0.1: banner observer results (counts and roles only).
    public var banners: BannerReport?
}

public enum Probe {
    public static let resultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AegisPermissionsProbe")

    public static func run(process: String) -> ProbeReport {
        let events = EKEventStore()
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        let remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        let contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        return ProbeReport(
            process: process,
            pid: getpid(),
            parentPID: getppid(),
            time: ISO8601DateFormatter().string(from: Date()),
            fullDiskAccess: fullDiskAccess(),
            calendarStatus: describe(calendarStatus),
            calendarCount: calendarStatus == .fullAccess ? events.calendars(for: .event).count : nil,
            remindersStatus: describe(remindersStatus),
            reminderListCount: remindersStatus == .fullAccess ? events.calendars(for: .reminder).count : nil,
            contactsStatus: describe(contactsStatus),
            contactsReadable: contactsStatus == .authorized ? contactsReadable() : "not tried",
            accessibility: AXIsProcessTrusted() ? "trusted" : "not trusted"
        )
    }

    /// Opens and closes the folder macOS protects with Full Disk Access, reading no entry (as in #11).
    static func fullDiskAccess() -> String {
        let folder = "/Library/Application Support/com.apple.TCC"
        if let handle = opendir(folder) {
            closedir(handle)
            return "allowed"
        }
        let code = errno
        return code == ENOENT || code == ENOTDIR ? "invalid" : "denied (\(code))"
    }

    /// Fetches at most one contact with no keys: proves access without reading any field. Only tried once
    /// access is granted, so the probe never raises a permission prompt on its own.
    static func contactsReadable() -> String {
        do {
            var seen = false
            try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: [])) { _, stop in
                seen = true
                stop.pointee = true
            }
            return seen ? "yes" : "yes (no contacts)"
        } catch {
            return "no (\((error as NSError).domain) \((error as NSError).code))"
        }
    }

    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    static func describe(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    public static func write(_ report: ProbeReport, name: String) throws {
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: resultFolder.appendingPathComponent(name), options: .atomic)
    }
}
