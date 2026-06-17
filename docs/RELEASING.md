# Releasing Lupen

Lupen ships as a notarized DMG with Sparkle auto-updates. The whole pipeline
is one script — `Tools/release.sh` — once the one-time setup below is done.

## One-time setup

### 1. Apple Developer ID
- Join the Apple Developer Program.
- Create a **Developer ID Application** certificate; install it in your login
  keychain. Confirm: `security find-identity -v -p codesigning`.

### 2. Notarization credentials
Save a keychain profile so the script can notarize non-interactively:

```bash
xcrun notarytool store-credentials "lupen-notary" \
  --apple-id "you@example.com" --team-id "<TEAMID>" \
  --password "<app-specific-password>"
```

(`<app-specific-password>` is created at appleid.apple.com → Sign-In & Security.)

### 3. Sparkle EdDSA signing key
Sparkle verifies every update with an EdDSA signature. Generate the keypair
once (the private key is stored in your keychain, never committed):

```bash
# sign_update / generate_keys live in Sparkle's artifact bundle after an
# SPM resolve, e.g.:
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' | head -1)"
"$SPARKLE_BIN/generate_keys"          # creates the keypair; prints the PUBLIC key
"$SPARKLE_BIN/generate_keys -p"       # re-print the PUBLIC key (base64) any time
```

The public key is **injected into the app's Info.plist at build time**, not
committed to `Config/Shared.xcconfig` (that's the repo's existing design — the
key lives in the build, not the source). `release.sh` reads it from
`SPARKLE_PUBLIC_KEY` and passes `INFOPLIST_KEY_SUPublicEDKey=…` to the archive.
Without it the app ships no key and Sparkle refuses every update. The private
key stays in your keychain (and, on CI, a `SPARKLE_PRIVATE_KEY` secret).

### 4. appcast hosting (GitHub Pages)
`Config/Shared.xcconfig` points the app at
`https://momoraul.github.io/Lupen/appcast.xml`. Enable **GitHub Pages** for the
repo serving from `docs/` (Settings → Pages → Source: `docs/`), so
`docs/appcast.xml` is published at that URL. Host the DMG as a **GitHub Release
asset** (large binaries don't belong in Pages) and point each appcast
`<enclosure url>` at the release asset.

## Cutting a release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in
   `Config/Shared.xcconfig`. Add a Changelog entry in `README.md`.
2. Run the pipeline (fill the CONFIG block in the script or export the vars):

   ```bash
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="lupen-notary" \
   SPARKLE_PUBLIC_KEY="<base64-public-key>" \
   APPCAST_BASE_URL="https://github.com/momoraul/Lupen/releases/download/v0.3.0" \
   Tools/release.sh
   ```

   It archives → signs → notarizes → staples → builds the DMG → signs it for
   Sparkle → emits an `<item>` snippet under `build/appcast/`.
3. Create a **GitHub Release** tagged `v<version>` and attach the DMG.
4. Paste the emitted `<item>` into `docs/appcast.xml` (newest first), fixing the
   `<enclosure url>` to the release asset URL if needed, and commit/publish.
5. (If a Homebrew cask exists) bump its `version` + `sha256`
   (`shasum -a 256 <dmg>`).

Existing users get the update via Sparkle; new users download the DMG or
`brew install --cask`.

## Packaging gotchas
- **Hardened Runtime** + `--timestamp` are required for notarization (the
  script sets them).
- The Sparkle framework's XPC services inside the bundle must be signed — the
  Developer ID export handles this; if you sign manually, sign them too.
- Keep `sparkle:minimumSystemVersion` at `26.0` so the update isn't offered to
  unsupported systems.
- Lupen opens no sockets (zero-network), so there's no ATS/entitlement work.

## Moving to CI later
Once local releases are smooth, a `release.yml` (triggered on a `v*` tag) can
do the same steps on a macOS runner — you'd move the Developer ID cert
(base64), the notary credentials, and the Sparkle private key into GitHub
Secrets. Start local; automate when the manual flow is boring.
