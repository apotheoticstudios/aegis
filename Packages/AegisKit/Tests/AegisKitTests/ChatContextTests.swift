@testable import AegisKit
import Foundation
import XCTest

/// The owner's report (#203): replies claimed actions nothing took, and short follow-ups lost their context.
/// Each exchange below is the synthetic shape of one from that report.
final class ChatContextTests: XCTestCase {
    func testTheReportedRepliesNeverReachTheOwner() {
        let exchanges = [
            ("Open the panel", "Open the Panel for you, sir. I've got it pulling up now; looking good, isn't it?"),
            (
                "I mean, Example Dev.",
                "Ah, you want to address the developer directly? Got it. I'll note that down for future reference."
            ),
            (
                "Cancel",
                "Understood, sir. The command to cancel has been executed; the scheduled events for Sunday are now cleared from "
                    + "your calendar."
            ),
        ]
        for (owner, raw) in exchanges {
            XCTAssertEqual(Chat.reply(raw, owner: owner), Chat.cannotAct, raw)
            XCTAssertNil(Chat.check(raw, owner: owner), raw)
            XCTAssertFalse(Chat.speakable(raw + " More.", owner: owner).contains("cleared"), raw)
        }
        XCTAssertEqual(Chat.speakable("Open the Panel for you, sir. I've got it pulling up now. ", owner: "Open the panel"), "")
    }

    func testClaimsInAnyForm() {
        let claims = [
            ("open Safari", "Opening Safari now."), ("open Safari", "I'm opening it."), ("run the Work shortcut", "Done."),
            ("run the Work shortcut", "I've gone ahead and run the shortcut."), ("cancel my 3pm", "Your 3pm has been cancelled."),
            ("clear my afternoon", "Cleared."), ("clear my afternoon", "I've cleared your afternoon."),
            ("delete it", "It's been deleted from your calendar."), ("remember the code", "Noted."),
            ("add milk to my list", "I'll add milk to your list."), ("turn off the lights", "I've turned the lights off."),
            ("open Safari", "I'll open Safari now."), ("run Work", "I'll run Work now."), ("open Safari", "Opening Safari."),
            ("cancel my 3pm", "It's been cancelled."),
        ]
        for (owner, reply) in claims {
            XCTAssertTrue(Chat.claimsAction(reply, owner: owner), reply)
        }
    }

    func testConversationIsNotAClaim() {
        let fine = [
            ("what can you do", "I can open apps, run your shortcuts and add reminders when you say them as commands."),
            ("What did Example Sam say?", "Example Sam said the dinner has been cancelled."),
            ("catch me up", "Example Sam's dinner has been cancelled, and the dentist is at 5pm."),
            ("My sister is vegetarian and hates mushrooms", "Noted, I'll keep that in mind."),
            ("name a habit trick", "I call it the two-minute rule."), ("what is 3 plus 4", "If I add 3 and 4 I get 7."),
            ("pick a day", "I'm playing it safe and saying Friday."), ("say something wise", "I'm reminded of an old saying."),
            ("how do budgets work", "Setting up a budget is about knowing where your money goes."),
            ("any ideas?", "I'm open to ideas. I'm not sure yet."),
            ("could you open it?", "I'd open it if I could, but I can't from here."),
            ("how long does bread take?", "Done right, a loaf takes about four hours."),
            ("How would you solve it?", "If I set the variable to zero, the loop stops."),
            ("help me word a text cancelling my booking", "You could say: I'll cancel the booking tomorrow, sorry for the short notice."),
            ("what should I tell them", "Tell them “I've cancelled it” and leave it there."),
            ("how do I train for a marathon", "Running a marathon takes about four months of training."),
        ]
        for (owner, reply) in fine {
            XCTAssertFalse(Chat.claimsAction(reply, owner: owner), reply)
        }
    }

    func testAShortcutNameIsMatchedLikeSpeech() {
        let names = ["Work", "ExampleDev", "Pay Rent"]
        XCTAssertEqual(ShortcutName.match("Example Dev", in: names), .same("ExampleDev"), "spaces and case aren't part of a name")
        XCTAssertEqual(ShortcutName.match("example-dev", in: names), .same("ExampleDev"))
        XCTAssertEqual(ShortcutName.match("work", in: names), .same("Work"))
        XCTAssertEqual(ShortcutName.match("Exampel's Dev", in: names), .close("ExampleDev"), "a mishearing is only offered")
        XCTAssertNil(ShortcutName.match("Synthetic", in: names))
        XCTAssertNil(ShortcutName.match("Report 3", in: ["Report 1", "Report 2"]), "two near names are too close to guess")
        XCTAssertEqual(ShortcutName.match("Example Dev", in: ["Example Dev", "ExampleDev"]), .same("Example Dev"), "exact first")
        XCTAssertNil(ShortcutName.match("Example dev", in: ["ExampleDev", "Example-Dev"]), "never guessed between two of the same")
    }

    func testCorrectionsReplayTheLastCommand() {
        let cases: [(String, FollowUp)] = [
            ("I mean, Example Dev.", .instead("Example Dev")), ("No, Example Dev", .instead("Example Dev")),
            ("I said the Work shortcut", .instead("Work")), ("no I meant Safari", .instead("Safari")),
            ("I mean the other one", .other),
        ]
        for (text, followUp) in cases {
            XCTAssertEqual(FollowUp.parse(text), followUp, text)
        }
        for text in ["No thanks", "No, thanks", "no, it's fine", "I mean, never mind", "no"] {
            XCTAssertNil(FollowUp.parse(text), text)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let misheard = CommandContext(
            words: "Run the Exampel's Dev shortcut.", command: .runShortcut(name: "ExampleDev"), target: "Exampel's Dev", at: now,
            guessed: true
        )
        XCTAssertEqual(misheard.resolve(.instead("Example Dev")), .ask("Run the Example Dev shortcut."))
        XCTAssertEqual(misheard.resolve(.instead("open Safari")), .ask("open Safari"), "a whole command stands on its own")
        let whole = FollowUp.parse("I said run the Music shortcut")
        XCTAssertEqual(whole, .instead("run the Music shortcut"), "kept whole, so it stays a shortcut")
        XCTAssertEqual(whole.map(misheard.resolve), .ask("run the Music shortcut"))
        XCTAssertEqual(misheard.resolve(.instead("Make Coffee")), .ask("Run the Make Coffee shortcut."), "a name, not a command")
        let missing = CommandContext(words: "run the Synthetic shortcut", command: nil, target: "Synthetic", at: now)
        XCTAssertEqual(missing.resolve(.instead("Work")), .ask("run the Work shortcut"))
        let reminder = CommandContext(words: "remind me to call the bank", command: nil, at: now)
        XCTAssertEqual(reminder.resolve(.instead("tomorrow")), .say("I'm not sure what to swap. Say it in full."))
    }

    func testABareCancelAndRequestsAboutAegis() {
        for text in ["Cancel", "cancel.", "OK, cancel", "Hey Aegis, cancel"] {
            XCTAssertTrue(ActionReply.cancels(text), text)
        }
        for text in ["cancel my meeting", "cancel that", "cancelled"] {
            XCTAssertFalse(ActionReply.cancels(text), text)
        }
        XCTAssertEqual(SelfCommand.parse("Open the panel", name: "Aegis"), .openPanel)
        XCTAssertEqual(SelfCommand.parse("Friday, bring up your panel", name: "Friday"), .openPanel)
        XCTAssertEqual(SelfCommand.parse("hide the panel", name: "Aegis"), .closePanel)
        XCTAssertEqual(SelfCommand.parse("open your settings", name: "Aegis"), .openSettings)
        XCTAssertEqual(SelfCommand.parse("open Friday settings", name: "Friday"), .openSettings)
        for text in ["open settings", "open wifi settings", "open Safari", "what's on the panel today"] {
            XCTAssertNil(SelfCommand.parse(text, name: "Aegis"), text)
        }
    }
}
