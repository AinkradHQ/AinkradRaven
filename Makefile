DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.devhost/Documents/DevPlugins

generate: ; xcodegen generate
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
release: ; ./scripts/release.sh $(V)
