DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR
# Where a DEBUG host actually scans for sideloaded plugins:
# `AinkradHome.defaultCacheRoot(bundleID:)` is
# <App Support>/<bundleID>/Cache, and `AppEnvironment+BootstrapStores`
# appends `DevPlugins` to it. Release builds never scan this directory —
# `PluginTrust.scansDevPluginsDirectory` is `#if DEBUG`.
#
# The bundle id is the HOST's, not this plugin's. `com.ainkrad.app` is the
# main Ainkrad app (the Xcode Debug build); `com.ainkrad.devhost` is the
# separate Dev Host target. Quest's Makefile — which this was copied from —
# points at the devhost's *Documents* directory, which is both the wrong app
# and the pre-`VaultMigration` location, so a bundle placed there is invisible
# to the main app. Override on the command line to target the Dev Host:
#   make sideload HOST_BUNDLE_ID=com.ainkrad.devhost
HOST_BUNDLE_ID ?= com.ainkrad.app
DEV_PLUGINS := $(HOME)/Library/Application Support/$(HOST_BUNDLE_ID)/Cache/DevPlugins

generate: ; ./scripts/generate-oauth-credentials.sh && xcodegen generate
build: generate ; xcodebuild -scheme RavenPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/RavenPlugin.bundle"
	cp -R build/Build/Products/Debug/RavenPlugin.bundle "$(DEV_PLUGINS)/RavenPlugin.bundle"
# A wall-clock cap on `make test`, because a hanging test is INDISTINGUISHABLE
# from a slow build and the difference is measured in hours.
#
# A mutation run once wedged this target for **eight hours** before anyone looked;
# a second shell then blocked waiting on it. The suite completes in ~20 seconds,
# and the whole target including a clean build has never approached 8 minutes, so
# the cap costs nothing and converts an unbounded hang into exit code 124.
#
# It is a real risk rather than a hypothetical: 338 async tests, of which only 46
# use `boundedOutcome`, and NO suite carries swift-testing's `.timeLimit`. A test
# driving a `ScriptedTransport` that never receives its scripted response leaves a
# continuation suspended forever, and the runner waits with it.
#
# Guarded on `timeout` existing (it is GNU coreutils, not a macOS built-in) so a
# machine without it still runs the suite, just unbounded.
TEST_TIMEOUT ?= 480
TIMEOUT := $(shell command -v timeout 2>/dev/null)
XCTEST := xcodebuild -scheme RavenPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
test: generate
	@if [ -n "$(TIMEOUT)" ]; then \
		$(TIMEOUT) $(TEST_TIMEOUT) $(XCTEST); \
		status=$$?; \
		if [ $$status -eq 124 ]; then \
			echo ""; \
			echo "*** TEST TIMED OUT after $(TEST_TIMEOUT)s — this is a HANG, not a failure."; \
			echo "*** A suspended continuation looks exactly like a slow build. Suspects:"; \
			echo "***   - a ScriptedTransport test awaiting a response never scripted"; \
			echo "***   - a second 'make test' already running (shared DerivedData wedges)"; \
			echo "*** Re-run one suite with: $(XCTEST) 2>&1 | tail -50"; \
		fi; \
		exit $$status; \
	else \
		echo "note: 'timeout' not found — running the suite UNBOUNDED. A hang will not self-terminate."; \
		$(XCTEST); \
	fi
# Dev-only harness that runs the real GmailAuth OAuth flow against real
# Google traffic. Opens a browser and needs a human to click through
# Google's consent screen — never run unattended.
dev-auth: generate ; xcodebuild -scheme RavenDevAuth -configuration Debug -derivedDataPath build -destination 'platform=macOS' build && build/Build/Products/Debug/RavenDevAuth
# Dev-only: captures RAW (unredacted) Gmail API responses to
# ~/.config/ainkrad-raven/raw-fixtures/, outside the repo, for hand-redaction
# into Tests/RavenFeatureTests/Fixtures/. Requires RAVEN_DEV_ACCOUNT_ID set to
# the already-authorized account's email, and a refresh token already stored
# via `make dev-auth`. Never run unattended in CI.
dev-fixtures: generate ; xcodebuild -scheme RavenDevAuth -configuration Debug -derivedDataPath build -destination 'platform=macOS' build && build/Build/Products/Debug/RavenDevAuth --capture-fixtures
release: ; ./scripts/release.sh $(V)
