@testable import AegisKit
import Foundation
import XCTest

/// General commands, slice 3 (#45): Maps, Settings pages, volume and dark mode from the owner's words, their tier,
/// and the local model's checked picks.
final class CommandSystemTests: XCTestCase {
    private func parse(_ text: String) -> ActionCommand? {
        ActionCommand.parse(text, now: Date(timeIntervalSince1970: 1000), calendar: Calendar(identifier: .gregorian))
    }

    func testMapsFromTheOwnersWords() {
        XCTAssertEqual(parse("directions to the airport"), .automate(.mapsDirections, argument: "the airport"))
        XCTAssertEqual(
            parse("Hey Aegis, get directions to Brisbane Airport in Maps"),
            .automate(.mapsDirections, argument: "Brisbane Airport")
        )
        XCTAssertEqual(parse("navigate to 1 Synthetic Street"), .automate(.mapsDirections, argument: "1 Synthetic Street"))
        XCTAssertEqual(parse("find a pharmacy in Maps"), .automate(.mapsSearch, argument: "a pharmacy"))
        XCTAssertEqual(parse("open Brisbane in Apple Maps"), .automate(.mapsSearch, argument: "Brisbane"))
        XCTAssertEqual(parse("navigate to apple.com"), .openWebsite(url: "https://apple.com"))
        XCTAssertNil(parse("show me Tokyo on the map"), "the globe's phrase stays the World view's")
        XCTAssertEqual(parse("directions to the airport")?.summary(calendar: .current), "Get directions to “the airport” in Maps?")
    }

    func testSettingsPagesOpenOnlyFromTheFixedList() {
        XCTAssertEqual(parse("open Wi-Fi settings"), .automate(.settingsPage, argument: "wifi"))
        XCTAssertEqual(parse("open the bluetooth settings"), .automate(.settingsPage, argument: "bluetooth"))
        XCTAssertEqual(parse("show me privacy and security settings"), .automate(.settingsPage, argument: "privacy"))
        XCTAssertEqual(parse("open settings for displays"), .automate(.settingsPage, argument: "displays"))
        XCTAssertEqual(parse("open screen time settings"), .automate(.settingsPage, argument: "screentime"))
        XCTAssertEqual(parse("open Wi-Fi settings")?.summary(calendar: .current), "Open Wi-Fi settings?")
        XCTAssertNil(SettingsPage.key("passwords"))
        XCTAssertNil(SettingsPage.key("com.apple.Passwords-Settings.extension"))
        XCTAssertEqual(parse("open settings"), .openApp(name: "settings"))
        XCTAssertEqual(Set(SettingsPage.pages.map(\.key)).count, SettingsPage.pages.count)
        for page in SettingsPage.pages {
            XCTAssertEqual(SettingsPage.key(page.key), page.key)
            XCTAssertTrue(page.id.hasPrefix("com.apple."), page.key)
        }
    }

    func testVolumeAndDarkModeFromTheOwnersWords() {
        let cases: [(String, AppAutomation, String)] = [
            ("set the volume to 30", .volumeSet, "30"), ("volume 75%", .volumeSet, "75"), (
                "turn the sound down to 5 percent",
                .volumeSet,
                "5"
            ),
            ("turn it up", .volumeUp, ""), ("louder", .volumeUp, ""), ("turn the volume down a bit", .volumeDown, ""),
            ("mute", .mute, ""), ("mute the sound", .mute, ""), ("unmute", .unmute, ""), ("turn the sound back on", .unmute, ""),
            ("turn on dark mode", .darkMode, ""), ("dark mode", .darkMode, ""), ("switch to light mode", .lightMode, ""),
            ("turn off dark mode", .lightMode, ""),
        ]
        for (text, entry, argument) in cases {
            XCTAssertEqual(parse(text), .automate(entry, argument: argument), text)
        }
        XCTAssertNotEqual(parse("set the volume to 300"), .automate(.volumeSet, argument: "300"))
        XCTAssertEqual(parse("set the volume to 30")?.summary(calendar: .current), "Set the volume to 30%?")
    }

    func testNewEntriesRunAtOnceWhenNamed() {
        for entry in [AppAutomation.mapsDirections, .mapsSearch, .settingsPage, .volumeSet, .volumeUp, .mute, .darkMode, .lightMode] {
            let decision = ActionPolicy.decision(
                for: ActionRequest(payload: .automation(entry, argument: entry == .volumeSet ? "30" : ""), origin: .ownerSpoken),
                settings: .init(panelIsOpen: true)
            )
            XCTAssertEqual(decision.tier, .auto, entry.rawValue)
        }
    }

    func testModelPicksAreChecked() {
        let pick = { (json: String) in CommandPlan.parse(json, shortcuts: []) }
        XCTAssertEqual(pick(#"{"ability":"volume","value":"30"}"#)?.command, .automate(.volumeSet, argument: "30"))
        XCTAssertEqual(pick(#"{"ability":"volume","value":"up"}"#)?.command, .automate(.volumeUp, argument: ""))
        XCTAssertEqual(pick(#"{"ability":"settings","value":"Wi-Fi"}"#)?.command, .automate(.settingsPage, argument: "wifi"))
        XCTAssertEqual(
            pick(#"{"ability":"directions","value":"the airport"}"#)?.command,
            .automate(.mapsDirections, argument: "the airport")
        )
        XCTAssertEqual(pick(#"{"ability":"maps","value":"coffee"}"#)?.command, .automate(.mapsSearch, argument: "coffee"))
        XCTAssertEqual(pick(#"{"ability":"dark","value":"anything"}"#)?.command, .automate(.darkMode, argument: ""))
        for reply in [
            #"{"ability":"volume","value":"300"}"#, #"{"ability":"volume","value":"loud"}"#, #"{"ability":"settings","value":"passwords"}"#,
            #"{"ability":"directions","value":""}"#, #"{"ability":"maps","value":"a\nb"}"#,
        ] {
            XCTAssertNil(pick(reply), reply)
        }
        XCTAssertTrue(CommandPlan.systemPrompt().contains("wifi, bluetooth"))
        XCTAssertTrue(CommandPlan.looksLikeCommand("mute everything"))
    }
}
