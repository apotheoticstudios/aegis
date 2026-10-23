@testable import AegisKit
import Foundation
import XCTest

/// Follow-ups in context (#49): what the owner can say after a command, and what it resolves to.
final class CommandContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let swiss = ActionCommand.openFile(path: "/synthetic/home/Documents/Swiss trip plan.pages")
    private let swissOld = ActionCommand.openFile(path: "/synthetic/home/Documents/Old/Swiss trip plan 2025.pdf")
    private let swissNotes = ActionCommand.openFile(path: "/synthetic/home/Desktop/Swiss trip plan notes.txt")

    private var trip: CommandContext {
        CommandContext(words: "open up my Swiss trip plan", command: swiss, candidates: [swiss, swissOld, swissNotes], at: now)
    }

    func testFollowUpPhrases() {
        let cases: [(String, FollowUp)] = [
            ("open the other one", .other), ("no, the other one", .other), ("Hey Aegis, the other one please", .other),
            ("wrong one", .other), ("I meant the other file", .other),
            ("the second one", .pick(2)), ("open the third one", .pick(3)), ("no, the last one", .pick(-1)), ("number 2", .pick(2)),
            ("again", .again), ("do it again", .again), ("open that again", .again), ("one more time", .again),
            ("close it", .close), ("quit that", .close), ("shut it down", .close),
            ("show it in Finder", .reveal), ("where is it saved", .reveal),
            ("do the same for my Bali trip plan", .sameFor("my Bali trip plan")), ("same for Spotify", .sameFor("Spotify")),
            ("do that for Alex", .sameFor("Alex")),
        ]
        for (text, followUp) in cases {
            XCTAssertEqual(FollowUp.parse(text), followUp, text)
        }
        for text in ["open Spotify", "the other day was fun", "close the door", "what's another word for again", "play the next song"] {
            XCTAssertNil(FollowUp.parse(text), text)
        }
    }

    func testAnotherMatch() {
        XCTAssertEqual(trip.resolve(.other), .run(swissOld))
        var moved = trip
        moved.command = swissNotes
        XCTAssertEqual(moved.resolve(.other), .run(swiss), "it goes round")
        XCTAssertEqual(trip.resolve(.pick(3)), .run(swissNotes))
        XCTAssertEqual(trip.resolve(.pick(-1)), .run(swissNotes))
        XCTAssertEqual(trip.resolve(.pick(4)), .say("I only found 3."))
        let one = CommandContext(words: "open Spotify", command: .openApp(name: "Spotify"), at: now)
        XCTAssertEqual(one.resolve(.other), .say("That was the only one I found."))
        XCTAssertEqual(one.resolve(.pick(1)), .run(.openApp(name: "Spotify")))
        XCTAssertEqual(one.resolve(.pick(2)), .say("I only found one."))
    }

    func testAgainCloseAndReveal() {
        XCTAssertEqual(trip.resolve(.again), .run(swiss))
        XCTAssertEqual(trip.resolve(.reveal), .run(.automate(.finderReveal, argument: "/synthetic/home/Documents/Swiss trip plan.pages")))
        XCTAssertEqual(trip.resolve(.close), .say("I can't close one file yet: press ⌘W in it."))
        let app = CommandContext(words: "open Spotify", command: .openApp(name: "Spotify"), at: now)
        XCTAssertEqual(app.resolve(.close), .run(.quitApp(name: "Spotify")))
        XCTAssertEqual(app.resolve(.reveal), .say("That isn't a file or folder."))
        let music = CommandContext(words: "play music", command: .automate(.musicPlay, argument: ""), at: now)
        XCTAssertEqual(music.resolve(.close), .run(.quitApp(name: "Music")))
        let page = CommandContext(words: "open Wi-Fi settings", command: .automate(.settingsPage, argument: "wifi"), at: now)
        XCTAssertEqual(page.resolve(.close), .run(.quitApp(name: "System Settings")))
        let site = CommandContext(words: "open apple.com", command: .openWebsite(url: "https://apple.com"), at: now)
        XCTAssertEqual(site.resolve(.close), .say("I can't close a tab yet: press ⌘W in it."))
        let message = CommandContext(words: "text Sam I'm late", command: nil, target: "Sam", at: now)
        XCTAssertEqual(message.resolve(.again), .ask("text Sam I'm late"))
        XCTAssertEqual(message.resolve(.other), .say("That was the only one I found."))
    }

    func testTheSameForSomethingElse() {
        XCTAssertEqual(trip.target, nil, "a file's path isn't in the owner's words")
        let named = CommandContext(
            words: "open up my Swiss trip plan", command: swiss, target: "my Swiss trip plan", candidates: [swiss], at: now
        )
        XCTAssertEqual(named.resolve(.sameFor("my Bali trip plan")), .ask("open up my Bali trip plan"))
        let app = CommandContext(words: "open Spotify", command: .openApp(name: "spotify"), at: now)
        XCTAssertEqual(app.target, "spotify")
        XCTAssertEqual(app.resolve(.sameFor("Slack")), .ask("open Slack"))
        let site = CommandContext(words: "go to apple.com", command: .openWebsite(url: "https://apple.com"), at: now)
        XCTAssertEqual(site.resolve(.sameFor("bom.gov.au")), .ask("go to bom.gov.au"))
        let note = CommandContext(words: "make a note called Groceries", command: .automate(.notesNewNote, argument: "Groceries"), at: now)
        XCTAssertEqual(note.resolve(.sameFor("Hardware")), .ask("make a note called Hardware"))
        let message = CommandContext(words: "text Sam I'm late", command: nil, target: "Sam", at: now)
        XCTAssertEqual(message.resolve(.sameFor("Alex")), .ask("text Alex I'm late"))
        let volume = CommandContext(words: "turn it up", command: .automate(.volumeUp, argument: ""), at: now)
        XCTAssertEqual(volume.resolve(.sameFor("Slack")), .say("I'm not sure what to swap. Say it in full."))
    }

    func testContextExpiresWithTheConversation() {
        XCTAssertTrue(trip.isFresh(at: now.addingTimeInterval(CommandContext.lifetime - 1)))
        XCTAssertFalse(trip.isFresh(at: now.addingTimeInterval(CommandContext.lifetime)))
        XCTAssertEqual(CommandContext.lifetime, Chat.memory)
    }

    func testQuittingAnAppIsAtOnceAndOnlyForApps() {
        let decide = { (payload: ActionPayload) in
            ActionPolicy.decision(for: ActionRequest(payload: payload, origin: .ownerSpoken), settings: .init(panelIsOpen: true))
        }
        XCTAssertEqual(decide(ActionCommand.quitApp(name: "Spotify").payload).tier, .auto)
        XCTAssertEqual(ActionCommand.quitApp(name: "Spotify").summary(calendar: .current), "Quit Spotify?")
        XCTAssertEqual(decide(.file(path: "/synthetic/note.txt", verb: .close)).tier, .never)
        XCTAssertEqual(decide(.message(recipientHandle: "synthetic", text: "x", verb: .close)).tier, .never)
    }
}
