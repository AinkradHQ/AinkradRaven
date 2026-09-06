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
# Create, or repair an existing release by re-uploading its assets.
#
# `gh release create` fails outright on an existing tag, and under `set -e`
# that aborts the run BEFORE the catalog update below -- so a release that
# got as far as the tag but not the catalog could never be fixed by
# re-running the thing that made it. That is exactly what happened to
# Leyline v0.7.1. A re-run must be able to finish a half-finished release.
if gh release view "$VERSION" >/dev/null 2>&1; then
  echo "Release $VERSION exists - re-uploading assets."
  gh release upload "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" --clobber
else
  gh release create "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" \
    --target "$(git rev-parse HEAD)" \
    --title "$NAME $VERSION" --notes "$NAME $VERSION"
fi
echo "Released $VERSION (sha256 $SHA)"

# The GitHub release is NOT the release. The storefront reads catalog.json, and
# nothing else — so a run that stops at `gh release create` ships to nobody. That
# is exactly what happened to v0.7.0: published, tagged, downloadable, and
# invisible in the app for three days because the catalog still served v0.6.0.
# Updating the catalog is part of releasing, not a chore to remember afterwards.
SOURCE_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
CATALOG_REPO="AhmedMElhalaby/AinkradCatalog"
CATALOG_DIR="$(mktemp -d)"
trap 'rm -rf "$CATALOG_DIR"' EXIT

# A FRESH clone every time, never a local checkout. Editing a working copy would
# let a release publish whatever unrelated edit or stale main happened to be
# sitting in it. Not shallow: we push from this clone.
gh repo clone "$CATALOG_REPO" "$CATALOG_DIR" -- --quiet

# Edited with a real JSON parser, never sed. The entry is located by appID, and a
# missing entry is a hard error — a pattern-match that quietly matches nothing is
# the same silent no-op that let the catalog drift in the first place.
ID="$ID" VERSION="$VERSION" SHA="$SHA" API_VERSION="$API_VERSION" SOURCE_REPO="$SOURCE_REPO" \
python3 - "$CATALOG_DIR/catalog.json" <<'PY'
import json, os, sys

path = sys.argv[1]
app_id, version = os.environ["ID"], os.environ["VERSION"]
sha, api_version = os.environ["SHA"], int(os.environ["API_VERSION"])
source_repo = os.environ["SOURCE_REPO"]

original = open(path, encoding="utf-8").read()
catalog = json.loads(original)

entries = [a for a in catalog["apps"] if a.get("appID") == app_id]
if not entries:
    known = ", ".join(a.get("appID", "?") for a in catalog["apps"])
    sys.exit(f"error: no catalog entry with appID '{app_id}' (found: {known})")
if len(entries) > 1:
    sys.exit(f"error: {len(entries)} catalog entries claim appID '{app_id}'")
entry = entries[0]

previous_api = entry.get("apiVersion")
entry["version"] = version
entry["apiVersion"] = api_version
entry["sha256"] = sha
entry["downloadURL"] = (
    f"https://github.com/{source_repo}/releases/download/{version}/{app_id}.bundle.zip"
)
for link in entry.get("links", []):
    if link.get("title") == "Release notes":
        link["url"] = f"https://github.com/{source_repo}/releases/tag/{version}"

# An apiVersion move is the one change here that can make the host refuse to
# install the plugin, so it is announced rather than slipped in silently.
if previous_api != api_version:
    print(f"note: apiVersion {previous_api} -> {api_version}")

updated = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"

# Validate BEFORE touching the file, and write via a temp + atomic replace. A
# half-written catalog.json takes down the storefront for every app, not just
# this one, so the original is never truncated in place.
json.loads(updated)
if len(updated) < len(original) // 2:
    sys.exit("error: rewritten catalog is implausibly small; refusing to write")

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(updated)
os.replace(tmp, path)
PY

# Already current? Then this is a re-run, and there is nothing to push. Committing
# would fail under `set -e` and make a harmless repeat look like a broken release.
if git -C "$CATALOG_DIR" diff --quiet -- catalog.json; then
  echo "Catalog already lists $NAME $VERSION — nothing to push."
else
  git -C "$CATALOG_DIR" add catalog.json
  git -C "$CATALOG_DIR" commit -q -m "catalog: list $NAME $VERSION"
  git -C "$CATALOG_DIR" push -q origin HEAD:main
  echo "Catalog updated: $NAME $VERSION is now live in the storefront."
fi
