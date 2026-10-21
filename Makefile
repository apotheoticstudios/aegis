# The one entry point for humans and AI agents. See AGENTS.md.
.PHONY: bootstrap generate build app heldout test test-core test-ipc test-voice test-wake test-prototype test-scripts test-fixtures signing-config lint format guard clean

PROJECT := Aegis.xcodeproj
SCHEME  := AegisApp
# Builds stay in build/*.noindex (gitignored; Spotlight skips .noindex folders), so test builds never appear as extra Aegis apps.
XCB     := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData.noindex

bootstrap:
	./scripts/bootstrap.sh

generate:
	xcodegen generate
	@mkdir -p build

build: generate
	$(XCB) build

# The Aegis.app to install: team-signed, with the real MLX ModelService (ADR-0014). Mac only.
app:
	./scripts/build-app.sh

test: generate test-ipc test-voice test-wake
	$(XCB) test

test-core:
	cd Packages/AegisKit && swift test

# SharedIPC (NSXPC) and MacSources (EventKit, Contacts) are macOS-only, so they aren't part of test-core.
test-ipc:
	cd Packages/SharedIPC && swift test
	cd Packages/MacSources && swift test

# Writes Config/Signing.local.xcconfig (gitignored) with the team of this Mac's Apple Development
# certificate, so Xcode builds are team-signed. AegisCore and ModelService must never be registered
# from an ad hoc build (ADR-0013).
signing-config:
	./scripts/signing-config.sh

test-prototype:
	python3 -m unittest discover -s Prototype -p 'test_*.py' -v

test-scripts:
	python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v

# Fixture generator tests (#14); runs every folder under Fixtures/ that holds test_*.py files.
heldout: ## Stage 1 step 3.2: the synthetic held-out day through the real engine and MLX, then scored (Mac)
	./scripts/heldout.sh

test-fixtures:
	@dirs=$$(find Fixtures -name 'test_*.py' -exec dirname {} \; | sort -u); \
	if [ -z "$$dirs" ]; then echo "No fixture tests yet (the generator arrives with #14)."; fi; \
	for d in $$dirs; do python3 -m unittest discover -s "$$d" -p 'test_*.py' -v || exit 1; done

lint:
	swiftlint lint --quiet
	swiftformat --lint .

format:
	swiftformat .

guard:
	./scripts/privacy-guard.sh

clean:
	rm -rf $(PROJECT) build DerivedData Packages/AegisKit/.build

# Synthetic voice lifecycle tests; models are optional for the separate local smoke check.
test-voice:
	cd Packages/VoiceRuntime && swift test

# Pure keyword-runtime checks; optional synthetic inference benchmark uses packaged public models.
test-wake:
	cd Packages/WakeRuntime && swift test
