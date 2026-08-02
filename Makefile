DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.devhost/Documents/DevPlugins

generate: ; xcodegen generate
build: generate ; xcodebuild -scheme MailPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/MailPlugin.bundle"
	cp -R build/Build/Products/Debug/MailPlugin.bundle "$(DEV_PLUGINS)/MailPlugin.bundle"
test: generate ; xcodebuild -scheme MailPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)
