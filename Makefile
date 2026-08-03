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
test: generate ; xcodebuild -scheme RavenPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
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
