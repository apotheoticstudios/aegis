@testable import AegisKit
import Foundation
import XCTest

final class ActionContractTests: XCTestCase {
    func testEveryDomainAndOriginRoundTrips() throws {
        let time = Date(timeIntervalSince1970: 1000)
        let payloads: [ActionPayload] = [
            .message(recipientHandle: "synthetic-recipient", text: "Synthetic message"),
            .message(recipientHandle: "recipient@example.invalid", text: "Synthetic email", channel: .email),
            .home(accessory: "synthetic-light", characteristic: .light, value: .boolean(true)),
            .home(accessory: "synthetic-thermostat", characteristic: .thermostat, value: .number(22)),
            .app(bundleID: "com.example.reader", verb: .open), .file(path: "/synthetic/note.txt", verb: .read),
            .calendar(title: "Synthetic meeting", start: time, end: time.addingTimeInterval(60)),
            .reminder(title: "Synthetic task", due: nil), .reminder(title: "Synthetic task", due: time),
            .system(setting: .appearance, value: .text("dark")),
            .shortcut(name: "Synthetic shortcut"), .website(url: "https://example.invalid/page"),
        ]
        XCTAssertEqual(Set(payloads.map(\.domain)), Set(ActionDomain.allCases))
        for payload in payloads {
            for origin in ActionOrigin.allCases {
                let request = ActionRequest(payload: payload, origin: origin)
                try assertRoundTrip(request)
                let object = try object(request)
                XCTAssertEqual(object["domain"] as? String, payload.domain.rawValue)
                XCTAssertEqual(object["origin"] as? String, origin.rawValue)
            }
        }
    }

    func testDecisionSettingsAndLogCodesRoundTrip() throws {
        let time = Date(timeIntervalSince1970: 1000)
        for tier in ActionTier.allCases {
            let decision = ActionDecision(tier: tier, reasonCodes: ActionReasonCode.allCases)
            try assertRoundTrip(decision)
            try assertRoundTrip(ActionOwnerSettings(panelIsOpen: true, minimumTier: tier))
            XCTAssertEqual(try object(decision)["allowed"] as? Bool, tier != .never)
            for outcome in ActionOutcomeCode.allCases {
                try assertRoundTrip(ActionLogEntry(time: time, requestID: UUID(), domain: .app, decision: decision, outcomeCode: outcome))
            }
        }
        for verb in ActionVerb.allCases {
            try assertRoundTrip(verb)
        }
        for characteristic in ActionHomeCharacteristic.allCases {
            try assertRoundTrip(characteristic)
        }
        for setting in ActionSystemSetting.allCases {
            try assertRoundTrip(setting)
        }
    }

    func testCollectedOriginsAndMissingOriginsCannotDecode() throws {
        let request = ActionRequest(payload: .file(path: "/synthetic/note.txt", verb: .open), origin: .ownerTyped)
        for origin in ["collectedContent", "email", "message", "notification", "webPage", "model", "owner"] {
            var json = try object(request)
            json["origin"] = origin
            XCTAssertThrowsError(try decodeRequest(json))
        }
        var missing = try object(request)
        missing.removeValue(forKey: "origin")
        XCTAssertThrowsError(try decodeRequest(missing))
        missing["origin"] = NSNull()
        XCTAssertThrowsError(try decodeRequest(missing))
    }

    func testMismatchedDomainUnknownFieldsAndArbitraryOperationsCannotDecode() throws {
        let request = ActionRequest(payload: .file(path: "/synthetic/note.txt", verb: .open), origin: .ownerTyped)
        var mismatch = try object(request)
        mismatch["domain"] = "message"
        XCTAssertThrowsError(try decodeRequest(mismatch))
        var collected = try object(request)
        collected["event"] = "Synthetic collected text"
        XCTAssertThrowsError(try decodeRequest(collected))
        var invalidID = try object(request)
        invalidID["id"] = "Synthetic payload text"
        XCTAssertThrowsError(try decodeRequest(invalidID))
        let arbitraryVerb = Data(#""run arbitrary script""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ActionVerb.self, from: arbitraryVerb))
    }

    func testDecisionCannotClaimForbiddenWorkIsAllowedAndDeduplicatesCodes() throws {
        let decision = ActionDecision(tier: .never, reasonCodes: [.deletion, .deletion])
        XCTAssertEqual(decision.reasonCodes, [.deletion])
        var json = try object(decision)
        json["allowed"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(ActionDecision.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testAuditRecordRejectsExtraPayloadFields() throws {
        let entry = ActionLogEntry(
            time: Date(timeIntervalSince1970: 1000), requestID: UUID(), domain: .message,
            decision: .init(tier: .confirmTwice, reasonCodes: [.outwardFacing]), outcomeCode: .awaitingConfirmation
        )
        var json = try object(entry)
        json["payload"] = "Synthetic private message"
        XCTAssertThrowsError(try JSONDecoder().decode(ActionLogEntry.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    private func assertRoundTrip(_ value: some Codable & Equatable) throws {
        let decoded = try JSONDecoder().decode(type(of: value), from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decodeRequest(_ object: [String: Any]) throws -> ActionRequest {
        try JSONDecoder().decode(ActionRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
