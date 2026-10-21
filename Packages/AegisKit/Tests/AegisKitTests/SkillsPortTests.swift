// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), tests/skills/test_parser.py, test_loader_markdown.py,
// test_loader_discover.py and test_skills.py, commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0.
// Changes: Swift XCTest, synthetic owner recipes; no tools, signing, sidecars or logging.

@testable import AegisKit
import Foundation
import XCTest

final class SkillsPortTests: XCTestCase {
    func testMinimalFrontmatterAndDefaults() throws {
        let manifest = try SkillParser.parseFrontmatter(["name": .string("minimal"), "description": .string("Does something useful")])
        XCTAssertEqual(manifest.name, "minimal")
        XCTAssertEqual(manifest.description, "Does something useful")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertEqual(manifest.author, "")
        XCTAssertTrue(manifest.steps.isEmpty)
        XCTAssertTrue(manifest.requiredCapabilities.isEmpty)
        XCTAssertTrue(manifest.metadata.isEmpty)
        XCTAssertTrue(manifest.userInvocable)
        XCTAssertFalse(manifest.disableModelInvocation)
        XCTAssertNil(manifest.trigger)
        XCTAssertNil(manifest.schedule)
    }

    func testRequiredFieldsAndTypes() {
        assertError(["description": .string("x")], "Missing required field in frontmatter: name")
        assertError(["name": .string("test-skill")], "Missing required field in frontmatter: description")
        assertError(["name": .number(1), "description": .string("x")], "Field 'name' must be a string, got <class 'int'>")
        assertError(["name": .string("test"), "description": .bool(false)], "Field 'description' must be a string, got <class 'bool'>")
        for value: SkillValue in [.number(1.5), .list([]), .map([:])] {
            assertError(["name": value, "description": .string("x")], "Field 'name' must be a string, got \(value.pythonType)")
        }
    }

    func testNamingErrorsMatchUpstream() {
        let errors = [
            "MySkill": "must be lowercase", "-skill": "must not start or end with a hyphen",
            "skill-": "must not start or end with a hyphen", "my--skill": "must not contain consecutive hyphens",
            "my_skill": "contains invalid character '_'; only lowercase alphanumeric and hyphens are allowed",
        ]
        for (name, reason) in errors {
            assertError(["name": .string(name), "description": .string("x")], "Skill name '\(name)' \(reason)")
        }
    }

    func testValidNamesAndLengthBoundaries() throws {
        for name in ["a", "1", "my-skill-123", String(repeating: "a", count: 64), "café"] {
            XCTAssertEqual(try parse(name: name).name, name)
        }
        assertError(["name": .string(""), "description": .string("x")], "Field 'name' must be 1-64 chars, got 0")
        assertError(
            ["name": .string(String(repeating: "a", count: 65)), "description": .string("x")],
            "Field 'name' must be 1-64 chars, got 65"
        )
        for count in [0, 1025] {
            assertError(
                ["name": .string("test"), "description": .string(String(repeating: "a", count: count))],
                "Field 'description' must be 1-1024 chars, got \(count)"
            )
        }
        XCTAssertNoThrow(try SkillParser.parseFrontmatter([
            "name": .string("test"),
            "description": .string(String(repeating: "a", count: 1024)),
        ]))
    }

    func testCompatibilityValidation() throws {
        var fields: [String: SkillValue] = ["name": .string("test"), "description": .string("x"), "compatibility": .number(1)]
        assertError(fields, "Field 'compatibility' must be a string")
        fields["compatibility"] = .string(String(repeating: "a", count: 501))
        assertError(fields, "Field 'compatibility' exceeds 500 chars")
        fields["compatibility"] = .string(String(repeating: "a", count: 500))
        XCTAssertNoThrow(try SkillParser.parseFrontmatter(fields))
    }

    func testAllTolerantMappings() throws {
        let manifest = try parse(extra: [
            "version": .string("1.2.3"), "author": .string("Example Sam"), "tags": .list([.string("research"), .string("nlp")]),
            "depends": .list([.string("summarize")]), "required_capabilities": .list([.string("network:fetch")]),
            "user_invocable": .bool(false), "disable_model_invocation": .bool(true),
            "platforms": .list([.string("macos"), .string("linux")]), "prerequisites": .string("local setup"),
        ])
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.author, "Example Sam")
        XCTAssertEqual(manifest.tags, ["research", "nlp"])
        XCTAssertEqual(manifest.depends, ["summarize"])
        XCTAssertEqual(manifest.requiredCapabilities, ["network:fetch"])
        XCTAssertFalse(manifest.userInvocable)
        XCTAssertTrue(manifest.disableModelInvocation)
        XCTAssertEqual(manifest.metadata["openjarvis"]?.map?["platforms"], .list([.string("macos"), .string("linux")]))
        XCTAssertEqual(manifest.metadata["openjarvis"]?.map?["prerequisites"], .string("local setup"))
    }

    func testNamespacedMappingsOverrideTopLevel() throws {
        let namespaced: [String: SkillValue] = [
            "version": .string("9.9.9"), "author": .string("Example Sam"), "tags": .list([.string("already"), .string("mapped")]),
            "depends": .list([.string("b")]), "required_capabilities": .list([.string("local")]),
            "user_invocable": .bool(false), "disable_model_invocation": .bool(true),
        ]
        var fields = namespaced.mapValues { _ in SkillValue.string("top-level") }
        fields["metadata"] = .map(["openjarvis": .map(namespaced), "other": .string("kept")])
        let manifest = try parse(extra: fields)
        XCTAssertEqual(manifest.version, "9.9.9")
        XCTAssertEqual(manifest.tags, ["already", "mapped"])
        XCTAssertEqual(manifest.author, "Example Sam")
        XCTAssertEqual(manifest.depends, ["b"])
        XCTAssertEqual(manifest.requiredCapabilities, ["local"])
        XCTAssertFalse(manifest.userInvocable)
        XCTAssertTrue(manifest.disableModelInvocation)
        XCTAssertEqual(manifest.metadata["other"], .string("kept"))
    }

    func testUnmappedFieldsPreservedWithoutLogging() throws {
        let manifest = try parse(extra: ["weird_field": .string("preserved"), "weird_vendor_field": .string("something")])
        XCTAssertEqual(
            manifest.metadata["openjarvis"]?.map?["original_frontmatter"],
            .map(["weird_field": .string("preserved"), "weird_vendor_field": .string("something")])
        )
        XCTAssertTrue(try parse(extra: ["metadata": .string("ignored")]).metadata.isEmpty)
    }

    func testLegacyStepFieldsAndCodable() throws {
        let step = SkillStep(skillName: "summarize", outputKey: "result")
        XCTAssertEqual(step.toolName, "")
        XCTAssertEqual(step.argumentsTemplate, "{}")
        XCTAssertEqual(step.skillName, "summarize")
        XCTAssertEqual(SkillStep(toolName: "web_search").skillName, "")
        let manifest = SkillManifest(
            name: "test",
            steps: [step],
            tags: ["research"],
            depends: ["summarize"],
            userInvocable: false,
            disableModelInvocation: true,
            markdownContent: "When asked to research..."
        )
        XCTAssertEqual(try JSONDecoder().decode(SkillManifest.self, from: JSONEncoder().encode(manifest)), manifest)
        let values: [SkillValue] = [.string("x"), .number(2.5), .bool(true), .list([.string("a")]), .map(["x": .bool(false)])]
        XCTAssertEqual(try JSONDecoder().decode([SkillValue].self, from: JSONEncoder().encode(values)), values)
    }

    private func parse(name: String = "test", extra: [String: SkillValue] = [:]) throws -> SkillManifest {
        try SkillParser.parseFrontmatter(["name": .string(name), "description": .string("x")].merging(extra) { _, right in right })
    }

    private func assertError(_ fields: [String: SkillValue], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SkillParser.parseFrontmatter(fields), file: file, line: line) {
            XCTAssertEqual($0 as? SkillParseError, .invalid(message), file: file, line: line)
        }
    }
}

extension SkillsPortTests {
    func testMarkdownParserDelegationAndLegacyFields() throws {
        let manifest = try SkillFile
            .parse(
                "---\nname: legacy-skill\ndescription: x\nversion: 2.0.0\ntags: [a, b]\nrequired_capabilities: [network:fetch]\n---\nBody"
            )
        XCTAssertEqual(manifest.name, "legacy-skill")
        XCTAssertEqual(manifest.version, "2.0.0")
        XCTAssertEqual(manifest.tags, ["a", "b"])
        XCTAssertEqual(manifest.requiredCapabilities, ["network:fetch"])
        XCTAssertEqual(manifest.markdownContent, "Body")
        XCTAssertThrowsError(try SkillFile.parse("Just some instructions.\n"))
        XCTAssertThrowsError(try SkillFile.parse("---\nname: guide_skill\ndescription: x\n---\nBody"))
        XCTAssertThrowsError(try SkillFile.parse("---\nname: research\n---\nBody"))
    }

    func testYamlSubsetAndAegisConveniences() throws {
        let manifest = try SkillFile.parse("""
        ---
        name: morning-routine # comment
        description: "What I want: each morning # notes"
        author: 'Example Sam'
        tags:
          - local
          - 'owner''s commands'
        metadata:
          aegis:
            trigger: good morning
            schedule: weekdays 07:00
          enabled: true
          weight: 2.5
        ---
        Optional notes in markdown.

        ## Steps
        1. What's the weather today?
        2. Catch me up
        3. Open Calendar
        """)
        XCTAssertEqual(manifest.trigger, "good morning")
        XCTAssertEqual(manifest.schedule?.description, "weekdays 07:00")
        XCTAssertEqual(manifest.description, "What I want: each morning # notes")
        XCTAssertEqual(manifest.tags, ["local", "owner's commands"])
        XCTAssertEqual(manifest.metadata["weight"], .number(2.5))
        XCTAssertEqual(manifest.metadata["enabled"], .bool(true))
        XCTAssertEqual(manifest.steps.map(\.command), ["What's the weather today?", "Catch me up", "Open Calendar"])
    }

    func testFirstListAndExplicitStepsSelection() throws {
        let prefix = "---\nname: research\ndescription: x\n---\n"
        let body = "When asked to research a topic:\n1. Break into sub-questions\n2. Search each one\n\nNotes\n- Ignore this list"
        XCTAssertEqual(try SkillFile.parse(prefix + body).steps.map(\.command), ["Break into sub-questions", "Search each one"])
        let explicit = "- Notes only\n## Steps\n- Catch me up\n- Open Calendar\n## More\n- Not a step"
        XCTAssertEqual(try SkillFile.parse(prefix + explicit).steps.map(\.command), ["Catch me up", "Open Calendar"])
        XCTAssertTrue(try SkillFile.parse(prefix + "## Steps\nNo commands\n## Notes\n- Ignore").steps.isEmpty)
    }

    func testMalformedYamlRejected() {
        for yaml in ["name: [broken", "name: \"unterminated", "name: test\nname: duplicate", "name: test\n\tdescription: x", "[test]"] {
            XCTAssertThrowsError(try SkillFile.parse("---\n\(yaml)\n---\nBody"))
        }
    }

    func testFileRoundTripPreservesAllFields() throws {
        let manifest = SkillManifest(
            name: "test-skill", version: "2.0.0", description: "A recipe: with \"quotes\"\nsecond line", author: "Example Sam",
            steps: [
                SkillStep(
                    command: "Catch me up",
                    toolName: "inert",
                    skillName: "also-inert",
                    argumentsTemplate: "{previous}",
                    outputKey: "result"
                ),
                SkillStep(command: "Open Calendar"),
            ], requiredCapabilities: ["local"],
            metadata: [
                "aegis": .map(["trigger": .string("good morning"), "schedule": .string("daily 07:00")]),
                "nested": .list([.map(["count": .number(1)]), .bool(false)]),
            ],
            tags: ["a", "b"], depends: ["other"], userInvocable: false, disableModelInvocation: true,
            markdownContent: "Notes\n- a note, not a command\n## Steps\n1. Old notes\n"
        )
        XCTAssertEqual(try SkillFile.parse(SkillFile.render(manifest)), manifest)
        let minimal = SkillManifest(name: "minimal", description: "x", steps: [SkillStep(command: "Open Calendar")])
        XCTAssertEqual(try SkillFile.parse(SkillFile.render(minimal)), minimal)
    }

    func testRenderedFileEditsKeepVisibleCommandsAuthoritative() throws {
        let manifest = SkillManifest(name: "morning", description: "x", steps: [SkillStep(command: "Catch me up")])
        let edited = SkillFile.render(manifest).replacingOccurrences(of: "1. Catch me up", with: "1. Open Calendar")
        XCTAssertEqual(try SkillFile.parse(edited).steps.map(\.command), ["Open Calendar"])
        let conflicting = SkillManifest(
            name: "morning",
            version: "1.0.0",
            description: "x",
            metadata: ["openjarvis": .map(["version": .string("9.9.9")])]
        )
        XCTAssertEqual(try SkillFile.parse(SkillFile.render(conflicting)), conflicting)
    }

    func testQuotedYamlAndNestedLists() throws {
        let text = """
        ---
        name: morning
        description: 'Owner''s # daily recipe' # outside comment
        metadata:
          aegis:
            trigger: what's next
          values: [first, 'a,b', [1, true], "# kept"]
        ---
        ## Steps
        - Catch me up
        """
        let manifest = try SkillFile.parse(text)
        XCTAssertEqual(manifest.description, "Owner's # daily recipe")
        XCTAssertEqual(manifest.trigger, "what's next")
        XCTAssertEqual(
            manifest.metadata["values"],
            .list([.string("first"), .string("a,b"), .list([.number(1), .bool(true)]), .string("# kept")])
        )
        XCTAssertEqual(try SkillFile.parse(SkillFile.render(manifest)), manifest)
        let invalidConveniences = try parse(extra: ["metadata": .map(["aegis": .map([
            "trigger": .number(1),
            "schedule": .string("never"),
        ])])])
        XCTAssertNil(invalidConveniences.trigger)
        XCTAssertNil(invalidConveniences.schedule)
    }

    func testDiscoverySkipsInvalidAndSortsByManifestName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (directory, name) in ["first": "zebra", "second": "alpha", "bad": "Bad_Name"] {
            let child = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: x\n---\nBody".write(
                to: child.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        try "broken".write(to: root.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("source/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "---\nname: nested\ndescription: x\n---\nBody".write(
            to: nested.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("unreadable/SKILL.md"), withIntermediateDirectories: true)
        XCTAssertEqual(SkillFile.discover(in: root).map(\.name), ["alpha", "zebra"])
        XCTAssertTrue(SkillFile.discover(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testTemplateUpstreamAndOwnerPlaceholders() {
        XCTAssertEqual(SkillTemplate.render(#"{"text": "{greeting}"}"#, context: ["greeting": "hi"]), #"{"text": "hi"}"#)
        XCTAssertEqual(SkillTemplate.render("{echoed}", context: ["echoed": "hello world"]), "hello world")
        let context = ["date": "2026-10-19", "time": "07:00", "weekday": "Monday", "previous": "answer"]
        XCTAssertEqual(
            SkillTemplate.render("{date} {time} {weekday} {previous} {unknown}", context: context),
            "2026-10-19 07:00 Monday answer {unknown}"
        )
        XCTAssertEqual(SkillTemplate.render("{a} {a} {a-b} {}", context: ["a": "{b}", "b": "recursive"]), "{b} {b} {a-b} {}")
        XCTAssertEqual(SkillTemplate.render("🦊 {x} {x}", context: ["x": "$1\\😀"]), "🦊 $1\\😀 $1\\😀")
    }
}

extension SkillsPortTests {
    func testRunCommands() {
        for text in ["run my morning routine skill", "run the morning routine", "do my morning routine"] {
            XCTAssertEqual(SkillCommand.parse(text), .run(name: "morning-routine"))
        }
        XCTAssertEqual(SkillCommand.parse("start my bedtime skill"), .run(name: "bedtime"))
    }

    func testCreateCommandsAndSeparators() {
        XCTAssertEqual(
            SkillCommand.parse("create a skill called morning routine: what's the weather, catch me up, then open Calendar"),
            .create(name: "morning-routine", steps: ["what's the weather", "catch me up", "open Calendar"])
        )
        XCTAssertEqual(
            SkillCommand.parse("make a skill named bedtime that does set an alarm; then read me tomorrow's calendar"),
            .create(name: "bedtime", steps: ["set an alarm", "read me tomorrow's calendar"])
        )
        for separator in [", then ", "; then ", ";", " then ", ", and then ", ","] {
            XCTAssertEqual(
                SkillCommand.parse("create a skill called test: first\(separator)second"),
                .create(name: "test", steps: ["first", "second"])
            )
        }
    }

    func testSaveRecentCommands() {
        XCTAssertEqual(SkillCommand.parse("save that as a skill called catch up"), .saveRecent(name: "catch-up", count: 1))
        XCTAssertEqual(SkillCommand.parse("save the last 3 things as a skill called morning"), .saveRecent(name: "morning", count: 3))
        XCTAssertEqual(SkillCommand.parse("turn the last two requests into a skill named commute"), .saveRecent(name: "commute", count: 2))
    }

    func testListDeleteAndShowCommands() {
        for text in ["what skills do I have", "list my skills", "show my skills"] {
            XCTAssertEqual(SkillCommand.parse(text), .list)
        }
        XCTAssertEqual(SkillCommand.parse("delete the morning skill"), .delete(name: "morning"))
        XCTAssertEqual(SkillCommand.parse("forget my bedtime skill"), .delete(name: "bedtime"))
        XCTAssertEqual(SkillCommand.parse("remove the commute skill"), .delete(name: "commute"))
        XCTAssertEqual(SkillCommand.parse("what does my morning skill do"), .show(name: "morning"))
    }

    func testScheduleCommands() throws {
        XCTAssertEqual(
            SkillCommand.parse("run my morning skill every weekday at 7"),
            try .schedule(name: "morning", XCTUnwrap(SkillSchedule("weekdays 07:00")))
        )
        XCTAssertEqual(
            SkillCommand.parse("run the bedtime skill daily at 9:30 pm"),
            try .schedule(name: "bedtime", XCTUnwrap(SkillSchedule("daily 21:30")))
        )
        XCTAssertEqual(
            SkillCommand.parse("run my morning skill daily at 12 am"),
            try .schedule(name: "morning", XCTUnwrap(SkillSchedule("daily 00:00")))
        )
        XCTAssertNil(SkillCommand.parse("run my morning skill daily at 24:00"))
        XCTAssertNil(SkillCommand.parse("run my morning skill daily at 99"))
        XCTAssertNil(SkillCommand.parse("run my morning skill daily at 0 pm"))
    }

    func testNonSkillCommands() {
        for text in [
            "what's the weather",
            "remind me to run at 7",
            "I'm learning a new skill",
            "run",
            "save the file",
            "create a skill called test:",
            "save the last zero things as a skill called test",
            "run my bad_name skill",
        ] {
            XCTAssertNil(SkillCommand.parse(text))
        }
    }

    func testNameSlugs() {
        XCTAssertEqual(SkillName.slug(" Morning  ROUTINE "), "morning-routine")
        for name in ["", "bad_name", "-name", "name-", "bad--name", "hello!", String(repeating: "x", count: 65)] {
            XCTAssertNil(SkillName.slug(name))
        }
    }

    func testSchedulesAndCanonicalStrings() throws {
        let examples = [
            "daily 07:00": "daily 07:00",
            "weekdays 7:30": "weekdays 07:30",
            "weekends 09:00": "weekends 09:00",
            "mondays 8:00": "mon 08:00",
            "mon,wed,fri 06:45": "mon,wed,fri 06:45",
        ]
        for (text, expected) in examples {
            let schedule = try XCTUnwrap(SkillSchedule(text))
            XCTAssertEqual(schedule.description, expected)
            XCTAssertEqual(SkillSchedule(schedule.description), schedule)
            XCTAssertEqual(try JSONDecoder().decode(SkillSchedule.self, from: JSONEncoder().encode(schedule)), schedule)
        }
        for text in ["daily 24:00", "daily 12:60", "daily -1:00", "daily 07:0", "someday 07:00", "mon, 07:00", "daily", "daily 7 pm"] {
            XCTAssertNil(SkillSchedule(text))
        }
    }

    func testScheduleWeekdayAndTime() throws {
        let calendar = try utcCalendar()
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12)))
        let schedule = try XCTUnwrap(SkillSchedule("weekdays 07:30"))
        for offset in 0 ... 6 {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: monday))
            XCTAssertEqual(schedule.isDue(on: date, calendar: calendar), offset < 5)
            if offset < 5 {
                let time = try XCTUnwrap(schedule.time(on: date, calendar: calendar))
                XCTAssertEqual(calendar.component(.hour, from: time), 7)
                XCTAssertEqual(calendar.component(.minute, from: time), 30)
                XCTAssertTrue(calendar.isDate(date, inSameDayAs: time))
            } else {
                XCTAssertNil(schedule.time(on: date, calendar: calendar))
            }
        }
    }

    func testScheduleDaySetsAndDaylightSavingGap() throws {
        let calendar = try utcCalendar()
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19)))
        for offset in 0 ... 6 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: monday))
            XCTAssertEqual(SkillSchedule("mon,wed,fri 06:45")?.isDue(on: day, calendar: calendar), [0, 2, 4].contains(offset))
            XCTAssertEqual(SkillSchedule("weekends 09:00")?.isDue(on: day, calendar: calendar), offset >= 5)
            XCTAssertEqual(SkillSchedule("daily 07:00")?.isDue(on: day, calendar: calendar), true)
            XCTAssertEqual(SkillSchedule("mondays 08:00")?.isDue(on: day, calendar: calendar), offset == 0)
        }
        var local = calendar
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let gapDay = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        XCTAssertNil(SkillSchedule("daily 02:30")?.time(on: gapDay, calendar: local))
    }

    func testSkillBookReplaceLookupRemoveAndTriggers() throws {
        var book = SkillBook()
        var manifest = SkillManifest(name: "morning", description: "x", metadata: ["aegis": .map(["trigger": .string("Good morning")])])
        try book.add(manifest)
        XCTAssertEqual(book.skill(forTrigger: "  GOOD   morning  "), manifest)
        XCTAssertNil(book.skill(forTrigger: "say good morning"))
        XCTAssertNil(book.skill(forTrigger: ""))
        manifest.steps = [SkillStep(command: "Open Calendar")]
        try book.add(manifest)
        XCTAssertEqual(book.skills.count, 1)
        XCTAssertEqual(book.skill(named: "MORNING"), manifest)
        XCTAssertEqual(book.remove(name: "morning"), manifest)
        XCTAssertNil(book.remove(name: "morning"))
    }

    func testSkillBookLimitsAreAtomic() throws {
        var book = SkillBook()
        let limitStep = SkillStep(command: String(repeating: "x", count: 300))
        for index in 0 ..< 50 {
            try book.add(SkillManifest(name: "skill-\(index)", steps: Array(repeating: limitStep, count: 12)))
        }
        XCTAssertThrowsError(try book.add(SkillManifest(name: "overflow"))) { XCTAssertEqual($0 as? SkillBook.LimitError, .tooManySkills) }
        try book.add(SkillManifest(name: "skill-0"))
        XCTAssertThrowsError(try book.add(SkillManifest(name: "skill-0", steps: Array(repeating: limitStep, count: 13)))) {
            XCTAssertEqual($0 as? SkillBook.LimitError, .tooManySteps)
        }
        XCTAssertThrowsError(try book.add(SkillManifest(
            name: "skill-0",
            steps: [SkillStep(command: String(repeating: "x", count: 301))]
        ))) {
            XCTAssertEqual($0 as? SkillBook.LimitError, .commandTooLong)
        }
        XCTAssertEqual(book.skills.count, 50)
        XCTAssertEqual(book.skill(named: "skill-0")?.steps, [])
    }

    func testSkillBookDue() throws {
        var book = SkillBook()
        for (name, schedule) in ["morning": "weekdays 07:00", "bedtime": "daily 21:30", "weekend": "weekends 09:00"] {
            try book.add(SkillManifest(name: name, metadata: ["aegis": .map(["schedule": .string(schedule)])]))
        }
        try book.add(SkillManifest(name: "manual"))
        let calendar = try utcCalendar()
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19)))
        XCTAssertEqual(book.due(on: monday, calendar: calendar).map(\.name), ["bedtime", "morning"])
    }

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return calendar
    }
}
