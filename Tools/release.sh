#!/usr/bin/env bash
#
# release.sh — local release pipeline for Lupen.
# Author: jaden (2026/06/18)
#
# Builds a Release archive, signs it with Developer ID, notarizes + staples,
# packages a DMG, signs the DMG for Sparkle (EdDSA), and folds the new item
# into the appcast. Run from a Mac with Xcode 26 + your signing identity.
#
# ── One-time setup (see docs/RELEASING.md) ───────────────────────────────
#   1. Apple Developer ID Application certificate in your login keychain.
#   2. Notary credentials saved as a keychain profile:
#        xcrun notarytool store-credentials "<NOTARY_PROFILE>" \
#          --apple-id you@example.com --team-id <TEAMID> --password <app-pw>
#   3. Sparkle EdDSA keypair (private key stays in keychain):
#        <sparkle>/bin/generate_keys            # prints the public key
#      Pass the PUBLIC key as SPARKLE_PUBLIC_KEY — this script injects it (and
#      SUFeedURL) into the built app's Info.plist (custom keys aren't emitted
#      by GENERATE_INFOPLIST_FILE, so xcconfig INFOPLIST_KEY_* won't work).
#   4. Fill the CONFIG block below (or export the vars before running).
#
# Usage:
#   Tools/release.sh                 # uses MARKETING_VERSION from the xcconfig
#   APPCAST_BASE_URL=... Tools/release.sh
#
set -euo pipefail

# ── CONFIG — fill these (or export before running) ───────────────────────
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: YOUR NAME (TEAMID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-lupen-notary}"
# Path to Sparkle's bin/ (sign_update, generate_appcast). After an SPM
# resolve it lives under DerivedData; override SPARKLE_BIN to pin it.
SPARKLE_BIN="${SPARKLE_BIN:-}"
# Sparkle EdDSA PUBLIC key (base64). Not stored in the repo — the design
# injects it into the built app's Info.plist at build time (here; CI from a
# secret). Get it once: "$SPARKLE_BIN/generate_keys -p".
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
# Where the published appcast + release assets are served from.
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://momoraul.github.io/Lupen}"

SCHEME="Lupen"
PROJECT="Lupen.xcodeproj"
APP_NAME="Lupen"
BUNDLE_ID="com.momoraul.lupen"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_DIR="$ROOT/build/release"
APPCAST_DIR="$ROOT/build/appcast"      # stage appcast.xml + DMG here, then publish

log() { printf "\033[1;36m▸ %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ── Version ──────────────────────────────────────────────────────────────
VERSION="$(grep -E '^MARKETING_VERSION' Config/Shared.xcconfig | sed -E 's/.*= *//')"
BUILD_NUM="$(grep -E '^CURRENT_PROJECT_VERSION' Config/Shared.xcconfig | sed -E 's/.*= *//')"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from Config/Shared.xcconfig"
log "Releasing $APP_NAME $VERSION (build $BUILD_NUM)"

# ── Preflight ────────────────────────────────────────────────────────────
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no Developer ID Application identity in keychain (setup step 1)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' not found (setup step 2)"
[ -n "$SPARKLE_PUBLIC_KEY" ] \
  || die "SPARKLE_PUBLIC_KEY unset (setup step 3) — without it the build ships no Sparkle public key and updates can't be verified. Get it from: \$SPARKLE_BIN/generate_keys -p"

if [ -z "$SPARKLE_BIN" ]; then
  SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
fi
[ -x "$SPARKLE_BIN/sign_update" ] || die "Sparkle sign_update not found — set SPARKLE_BIN to <sparkle>/bin"

rm -rf "$BUILD_DIR" "$APPCAST_DIR"
mkdir -p "$BUILD_DIR" "$APPCAST_DIR"

# ── 1. Archive (Release) ─────────────────────────────────────────────────
log "Archiving…"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  >/dev/null

# ── 2. Export the signed .app ────────────────────────────────────────────
log "Exporting (Developer ID)…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$BUILD_DIR/export" >/dev/null
APP="$BUILD_DIR/export/$APP_NAME.app"
[ -d "$APP" ] || die "export produced no $APP_NAME.app"
codesign --verify --deep --strict "$APP" || die "codesign verify failed"

# ── 2b. Inject Sparkle Info.plist keys + re-sign ─────────────────────────
# GENERATE_INFOPLIST_FILE only emits Apple-known keys, so the custom Sparkle
# keys (SUFeedURL / SUPublicEDKey / SUEnableAutomaticChecks) never make it
# into the built app. Add them with PlistBuddy, then re-seal the bundle (a
# top-level Info.plist edit invalidates only the outer signature; nested code
# keeps its export-time signatures).
log "Injecting Sparkle keys + re-signing…"
PLIST="$APP/Contents/Info.plist"
SUFEED_URL="https://momoraul.github.io/Lupen/appcast.xml"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null 2>&1; }
pb "Add :SUFeedURL string $SUFEED_URL"            || pb "Set :SUFeedURL $SUFEED_URL"
pb "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" || pb "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY"
pb "Add :SUEnableAutomaticChecks bool true"        || pb "Set :SUEnableAutomaticChecks true"
pb "Add :SUEnableInstallerLauncherService bool false" || pb "Set :SUEnableInstallerLauncherService false"
codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$APP"
codesign --verify --strict "$APP" || die "re-sign verify failed"
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" >/dev/null 2>&1 \
  || die "SUFeedURL injection failed"

# ── 3. DMG (with /Applications drop target) ──────────────────────────────
log "Building DMG…"
DMG="$APPCAST_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"

# ── 4. Notarize + staple ─────────────────────────────────────────────────
log "Notarizing (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" || die "staple validation failed"

# ── 5. Sparkle signature + appcast item ──────────────────────────────────
log "Signing for Sparkle + updating appcast…"
# sign_update already emits BOTH sparkle:edSignature="…" AND length="…".
SIG_LINE="$("$SPARKLE_BIN/sign_update" "$DMG")"
PUBDATE="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ITEM="    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$APPCAST_BASE_URL/$(basename "$DMG")\" type=\"application/octet-stream\" $SIG_LINE />
    </item>"
echo "$ITEM" > "$APPCAST_DIR/item-$VERSION.xml"

cat <<DONE

✅ Built, signed, notarized, stapled:
   DMG  : $DMG
   item : $APPCAST_DIR/item-$VERSION.xml   (paste into appcast.xml's <channel>)

Next:
  1. Add the <item> above to docs/appcast.xml and publish it + the DMG to
     $APPCAST_BASE_URL (GitHub Pages or a GitHub Release the appcast points to).
  2. Create a GitHub Release tagged v$VERSION and attach the DMG.
  3. (If a Homebrew cask exists) bump its version + sha256:
       shasum -a 256 "$DMG"
DONE
