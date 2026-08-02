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
release: ; ./scripts/release.sh $(V)
