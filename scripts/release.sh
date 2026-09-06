#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
VERSION="${1:?usage: release.sh vX.Y.Z}"
ID="raven"; NAME="Raven"; ICON="envelope"
DESC="A native mail client for Ainkrad — IMAP/SMTP and Gmail, with a real offline outbox."
LONG_DESC="Raven brings mail into the Ainkrad workspace as a first-class surface.

• Real accounts — connect Gmail with one click, or any IMAP/SMTP host by hand.
• Offline-first — the outbox is durable: compose and send with no connection, and the queue drains when you are back, per entry, without losing or duplicating a message.
• Threaded reading — conversations grouped properly, with search across threads.
• Fits the workspace — open it alongside your other apps, themed by the host's DesignTokens."

# Build CLEAN. An incremental build reuses whatever SwiftPM already resolved
# into build/SourcePackages — so after an SDK repin it can silently produce a
# bundle stamped with the PREVIOUS generation, which the host then refuses to
# load. A release build is not the place to save 90 seconds.
rm -rf build

# OAuth credentials are baked into the binary, and this MUST run before
# `xcodegen generate`: xcodegen captures `sources:` as whatever files exist in
# Sources/RavenFeature at generate time, so BakedOAuthCredentials.swift has to
# exist before that scan, not merely before compilation. Same ordering as the
# Makefile's `generate` target — do not reorder these two lines.
#
# NOTE: Config/oauth-client.json is a Google "installed" (Desktop) client.
# Google does not treat those secrets as confidential — a distributed desktop
# app is assumed to carry an extractable secret — which is why baking is the
# intended design here rather than a leak. It does mean the published bundle
# contains the client id/secret. Absent the config, this bakes nils and the
# Accounts surface degrades honestly to manual credential entry.
./scripts/generate-oauth-credentials.sh
xcodegen generate

xcodebuild -scheme RavenPlugin -configuration Release -derivedDataPath build -destination 'platform=macOS' build
BUNDLE="build/Build/Products/Release/RavenPlugin.bundle"

rm -rf dist && mkdir -p dist
# Archive so the extracted tree contains RavenPlugin.bundle at its root
# (PluginInstaller accepts root-is-bundle and .bundle-child layouts).
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "dist/${ID}.bundle.zip"
SHA="$(shasum -a 256 "dist/${ID}.bundle.zip" | awk '{print $1}')"

# apiVersion READ FROM THE BUILT BUNDLE (stamped from the linked SDK by
# scripts/stamp-api-version.sh), never hardcoded — a stale constant here
# publishes a plugin the host refuses to load, silently.
API_VERSION="$(/usr/libexec/PlistBuddy -c 'Print AinkradAPIVersion' "$BUNDLE/Contents/Info.plist")"
[[ -n "$API_VERSION" ]] || { echo "error: could not read AinkradAPIVersion from the built bundle" >&2; exit 1; }

cat > dist/ainkrad-plugin.json <<JSON
{ "id": "$ID", "name": "$NAME", "icon": "$ICON", "description": "$DESC", "apiVersion": $API_VERSION, "sha256": "$SHA",
  "author": "Ahmed M. Elhalaby", "longDescription": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$LONG_DESC"),
  "links": [{ "title": "Source", "url": "https://github.com/AhmedMElhalaby/AinkradRaven" }] }
JSON

# `--target` is NOT optional. Without it `gh release create` tags the
# repository's DEFAULT BRANCH head, not the commit this bundle was built
# from -- so the uploaded zip and its sha256 can come from code the tag does
# not contain. That shipped: the host's v0.17.1 tag landed on the previous
# release's commit while its asset held 79 newer commits.
gh release create "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" \
  --target "$(git rev-parse HEAD)" \
  --title "$NAME $VERSION" --notes "$NAME $VERSION"
echo "Released $VERSION (sha256 $SHA)"
