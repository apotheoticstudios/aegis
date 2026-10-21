@testable import AegisKit
import Foundation
import XCTest

final class ContactIdentityTests: XCTestCase {
    private let example = ContactSnapshot(
        id: "example-1", displayName: "Alex Example", phones: ["0400 000 001"], emails: ["alex@example.com"]
    )

    func testAUPhoneFormsAndInternationalNumber() {
        let index = ContactIndex([example, ContactSnapshot(
            id: "example-2", displayName: "Sam Example", phones: ["+44 20 7946 0000"]
        )])
        for handle in ["0400 000 001", "+61 400 000 001", "61400000001", "(04) 0000 0001", "tel:0400-000.001"] {
            XCTAssertEqual(index.resolve(handle: handle), .match(.init(id: example.id, name: example.displayName)))
        }
        for handle in ["+44 20 7946 0000", "tel:+44(20)7946-0000", "442079460000"] {
            XCTAssertEqual(index.resolve(handle: handle), .match(.init(id: "example-2", name: "Sam Example")))
        }
        for handle in ["+0400000001", "0400x000001", "0400/000001", "0400000002"] {
            XCTAssertEqual(index.resolve(handle: handle), .none)
        }
        let nonAU = ContactIndex([example], defaultRegion: "GB")
        XCTAssertEqual(nonAU.resolve(handle: "+61 400 000 001"), .none)
        XCTAssertEqual(nonAU.resolve(handle: "0400 000 001"), .match(.init(id: example.id, name: example.displayName)))
    }

    func testShortCodesAndBrandsAreExact() {
        let index = ContactIndex([ContactSnapshot(
            id: "brand-example", displayName: "Brand Example", phones: ["12345", "123456", "KFC AU", "0480027043"]
        )])
        for handle in ["12345", "123456", "KFC AU", "0480027043"] {
            XCTAssertEqual(index.resolve(handle: handle), .match(.init(id: "brand-example", name: "Brand Example")))
        }
        for handle in ["12-345", "+12345", "kfc au", "KFC  AU", "1234", ""] {
            XCTAssertEqual(index.resolve(handle: handle), .none)
        }
    }

    func testEmailsAndPlusAddresses() {
        let index = ContactIndex([example, ContactSnapshot(
            id: "plus-example", displayName: "Plus Example", emails: [" MAILTO:Alex+tag@Example.COM "]
        )])
        XCTAssertEqual(index.resolve(handle: " mailto:ALEX@EXAMPLE.COM\n"), .match(.init(id: example.id, name: example.displayName)))
        XCTAssertEqual(index.resolve(handle: "alex+tag@example.com"), .match(.init(id: "plus-example", name: "Plus Example")))
        XCTAssertEqual(index.resolve(handle: "alex+other@example.com"), .none)
    }

    func testDistinctIDsAndDuplicateHandles() {
        var duplicate = example
        duplicate.phones += ["+61 400 000 001", "0400 000 001"]
        XCTAssertEqual(
            ContactIndex([example, duplicate]).resolve(handle: "0400000001"),
            .match(.init(id: example.id, name: example.displayName))
        )
        duplicate.id = "example-2"
        XCTAssertEqual(
            ContactIndex([example, duplicate]).resolve(handle: "0400000001"),
            .ambiguous(count: 2),
            "equal names do not establish that two cards are the same person"
        )
        duplicate.displayName = "Sam Example"
        XCTAssertEqual(
            ContactIndex([example, duplicate]).resolve(handle: "0400000001"), .ambiguous(count: 2),
            "different people sharing a number are never guessed"
        )
    }

    func testTheOwnersOwnCardAndAddressesAreTheOwners() throws {
        var me = ContactSnapshot(id: "me", displayName: "Example Owner", phones: ["+61 400 000 114"], emails: ["owner@example.com"])
        me.isMe = true
        var index = ContactIndex([example, me])
        XCTAssertTrue(index.isOwner(handle: "0400 000 114"))
        XCTAssertTrue(index.isOwner(handle: "Owner@Example.com"))
        XCTAssertEqual(index.resolve(handle: "owner@example.com"), .none, "the Me card is never a sender")
        index.addOwner(handle: "owner.school@example.com")
        let mine = try XCTUnwrap(resolveSenders([event(handle: "owner.school@example.com")], index: index).first)
        XCTAssertEqual(mine.direction, .outgoing, "mail between the owner's own accounts is theirs")
        XCTAssertNil(mine.senderContact)
        let theirs = try XCTUnwrap(resolveSenders([event(handle: "0400000001")], index: index).first)
        XCTAssertEqual(theirs.direction, .incoming)
    }

    func testEmptyNameFallsBackToQueriedHandleAndEmptyIDsAreIgnored() throws {
        let index = ContactIndex([
            ContactSnapshot(id: "unnamed-example", displayName: "", phones: example.phones),
            ContactSnapshot(id: "", displayName: "Invalid Example", phones: example.phones),
        ])
        let handle = "+61 400 000 001"
        XCTAssertEqual(index.resolve(handle: handle), .match(.init(id: "unnamed-example", name: handle)))
        let resolved = try XCTUnwrap(resolveSenders([event(handle: handle)], index: index).first)
        XCTAssertEqual(resolved.validate(), [])
    }

    func testResolutionOnlyChangesSenderIdentityAndPreservesValidation() throws {
        let index = ContactIndex([example])
        var incoming = event(handle: "0400000001")
        incoming.flags = [.edited, .ambiguousSender]
        let resolved = try XCTUnwrap(resolveSenders([incoming], index: index).first)
        var expected = incoming
        expected.senderContact = .init(id: example.id, name: example.displayName)
        expected.flags = [.edited]
        XCTAssertEqual(resolved, expected)
        XCTAssertEqual(resolved.validate(), [])
        XCTAssertEqual(resolveSenders([resolved], index: index), [resolved])

        var second = example
        second.id = "example-2"
        second.displayName = "Sam Example"
        let ambiguous = try XCTUnwrap(resolveSenders([resolved], index: ContactIndex([example, second])).first)
        XCTAssertNil(ambiguous.senderContact)
        XCTAssertEqual(ambiguous.flags, [.edited, .ambiguousSender])
        XCTAssertEqual(ambiguous.validate(), [])
        XCTAssertEqual(resolveSenders([ambiguous], index: ContactIndex([example, second])), [ambiguous])
        let unknown = try XCTUnwrap(resolveSenders([ambiguous], index: ContactIndex([])).first)
        XCTAssertNil(unknown.senderContact)
        XCTAssertEqual(unknown.flags, [.edited])
        XCTAssertEqual(unknown.validate(), [])
    }

    func testOutgoingAndHandlelessNotificationsAreUntouched() {
        var outgoing = event(handle: "0400000001")
        outgoing.direction = .outgoing
        outgoing.sender = "me"
        let notification = event(handle: nil, source: .notification)
        let events = [outgoing, notification]
        XCTAssertEqual(resolveSenders(events, index: ContactIndex([example])), events)
        for event in events {
            XCTAssertEqual(event.validate(), [])
        }
    }

    func testNamesInTitleBodyAndSenderNeverResolveAHandle() {
        let index = ContactIndex([example])
        for handle in [nil, "unknown@example.com", "Alex Example"] {
            var message = event(handle: handle)
            let original = resolveSenders([message], index: index)
            message.title = "Alex Example"
            message.body = "Alex Example mentioned alex@example.com and +61 400 000 001."
            message.sender = "Alex Example"
            let resolved = resolveSenders([message], index: index)
            XCTAssertNil(resolved[0].senderContact)
            XCTAssertEqual(resolved[0].flags, original[0].flags)
            XCTAssertEqual(resolved[0].validate(), [])
        }
        var message = event(handle: "0400000001")
        message.direction = .unknown
        message.body = "Sam Example wrote this."
        XCTAssertEqual(resolveSenders([message], index: index)[0].senderContact?.id, example.id)
    }

    func testTenThousandContactsWithThirtyThousandHandles() {
        let contacts = (0 ..< 10000).map { number in
            ContactSnapshot(
                id: "example-\(number)", displayName: "Example \(number)",
                phones: [String(format: "+61 400 %03d %03d", number / 1000, number % 1000)],
                emails: ["example\(number)@example.com", "example\(number)+tag@example.com"]
            )
        }
        let start = ContinuousClock.now
        let index = ContactIndex(contacts)
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1))
        for contact in contacts {
            for handle in contact.phones + contact.emails {
                XCTAssertEqual(index.resolve(handle: handle), .match(.init(id: contact.id, name: contact.displayName)))
            }
        }
    }

    private func event(handle: String?, source: Event.Source = .sms) -> Event {
        let time = Date(timeIntervalSince1970: 0)
        return Event(
            source: source, sourceRecordID: "synthetic-message", appID: nil, sender: handle, threadID: nil,
            eventTime: time, eventTimeSource: .received, captureTime: time, title: nil, body: "Synthetic message.",
            content: .complete, observations: [.init(
                route: source == .notification ? .notificationDB : .chatDB,
                sourceRecordID: "synthetic-message", captureTime: time
            )], senderHandle: handle
        )
    }
}
