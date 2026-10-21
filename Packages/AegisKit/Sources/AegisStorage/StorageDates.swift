import AegisKit
import Foundation

/// Contract timestamps have microsecond precision. Index the same instant decoded from JSON so a
/// keyset cursor made from a returned Event cannot repeat/skip rows when input has sub-microsecond times.
enum StorageDates {
    static func check(_ dates: [Date?]) throws {
        for date in dates.compactMap(\.self) {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, seconds >= -62_167_219_200, seconds < 253_402_300_799 else {
                throw StorageError.invalidRecord
            }
        }
    }

    static func seconds(_ date: Date) -> Double {
        // check() guards the contract's year range before encoding. Fractional seconds round to micros.
        ContractTime.parse(ContractTime.format(date))?.timeIntervalSince1970 ?? date.timeIntervalSince1970
    }
}
