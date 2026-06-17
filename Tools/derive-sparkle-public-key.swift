#!/usr/bin/env swift

// Derive a Sparkle EdDSA public key (base64) from a private key
// passed as the only argument. Used by CI to avoid committing the
// public key separately — only the private key needs to live in
// GitHub Actions secrets, and this script reproduces the matching
// public key at build time so it can be injected into the built
// `.app`'s Info.plist via PlistBuddy.
//
// Pattern borrowed from cmux's `scripts/derive_sparkle_public_key.swift`
// (https://github.com/manaflow-ai/cmux). Sparkle's `generate_keys`
// CLI emits a 32-byte Curve25519 seed as base64; CryptoKit's
// `Curve25519.Signing.PrivateKey(rawRepresentation:)` accepts that
// seed directly and exposes `.publicKey.rawRepresentation` (32 bytes
// of base64-encoded public key) — the exact format Sparkle expects
// in the `SUPublicEDKey` Info.plist entry.
//
// Older Sparkle 1.x installations sometimes carry a 96-byte legacy
// key blob where the trailing 32 bytes are the already-computed
// public key. We do not generate such keys for Lupen (we are on
// Sparkle 2 from day one), but we keep a fallback branch so that if
// a key in that historic format ever shows up the script does the
// right thing instead of failing opaquely.
//
// Usage:
//   swift Tools/derive-sparkle-public-key.swift "$SPARKLE_PRIVATE_KEY"
//
// Output: base64 public key on stdout, no trailing newline content
// other than the standard print() one. Pipe directly into PlistBuddy:
//
//   KEY=$(swift Tools/derive-sparkle-public-key.swift "$SPARKLE_PRIVATE_KEY")
//   /usr/libexec/PlistBuddy \
//     -c "Set:SUPublicEDKey $KEY" Info.plist \
//     || /usr/libexec/PlistBuddy \
//          -c "Add:SUPublicEDKey string $KEY" Info.plist

import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data(
        "usage: derive-sparkle-public-key.swift <base64-private-key>\n".utf8
    ))
    exit(2)
}

let raw = CommandLine.arguments[1]
    .trimmingCharacters(in: .whitespacesAndNewlines)

// Permit base64 strings the user may have copied without padding —
// the CLI tool sometimes pastes them this way. CryptoKit's decoder
// only accepts canonical padding.
let padded: String = {
    let remainder = raw.count % 4
    return remainder == 0 ? raw : raw + String(repeating: "=", count: 4 - remainder)
}()

guard let data = Data(base64Encoded: padded) else {
    FileHandle.standardError.write(Data(
        "error: input is not valid base64\n".utf8
    ))
    exit(1)
}

let publicKey: Data
switch data.count {
case 32:
    // Modern Sparkle 2 format: 32-byte Curve25519 seed.
    do {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        publicKey = key.publicKey.rawRepresentation
    } catch {
        FileHandle.standardError.write(Data(
            "error: CryptoKit rejected the 32-byte seed: \(error)\n".utf8
        ))
        exit(1)
    }
case 96:
    // Legacy 96-byte blob: trailing 32 bytes are the public key.
    publicKey = data.suffix(32)
default:
    FileHandle.standardError.write(Data(
        "error: unexpected key length \(data.count) bytes (expected 32 or 96)\n".utf8
    ))
    exit(1)
}

print(publicKey.base64EncodedString())
