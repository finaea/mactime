#!/bin/bash
# One-time setup, run BY HAND on the mac (not over ssh — it touches your login
# keychain and macOS will show a couple of confirmation dialogs):
#
#   tools/make-dev-identity.sh
#
# Why: TCC permission grants (Screen Recording, Accessibility, Automation) are
# keyed to the app's code signature. Ad-hoc signatures change on every rebuild,
# so every rebundle silently drops your grants — that's why window titles and
# screenshots kept dying during development. A self-signed "MacTime Dev"
# certificate gives every build the same identity, so grants stick.
#
# After this, tools/bundle-macos.sh picks the identity up automatically.
# When codesign first uses the key, click "Always Allow" on the keychain prompt.
set -euo pipefail

if security find-identity -v -p codesigning | grep -q "MacTime Dev"; then
    echo "MacTime Dev identity already exists and is valid — nothing to do."
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$tmp/dev.key" -out "$tmp/dev.crt" \
    -days 3650 -nodes -subj "/CN=MacTime Dev" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=CA:FALSE"

# Import key and cert as separate PEMs — NOT via pkcs12. Modern openssl exports
# p12 with SHA-256 MAC/PBES2, which SecKeychainItemImport rejects with
# "MAC verification failed during PKCS12 import (wrong password?)".
# The keychain pairs them into one identity automatically.
security import "$tmp/dev.key" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import "$tmp/dev.crt" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign

# Trust it for code signing (user trust domain — expect a confirmation dialog).
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp/dev.crt"

echo
security find-identity -v -p codesigning | grep "MacTime Dev" \
    && echo "OK — rebuild with tools/bundle-macos.sh, then re-grant permissions once." \
    || { echo "identity created but not showing as valid — tell Claude"; exit 1; }
