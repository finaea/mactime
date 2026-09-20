#!/bin/bash
# Builds MacTime and assembles publish/MacTime.app. Runs on the mac.
#   tools/bundle-macos.sh [debug|release]   (default release)
#
# Needs Xcode, not just the Command Line Tools: the `swift build` below fails
# without the SwiftUIMacros plugin, which CLT does not ship, so every @State in
# UI/ fails to expand. The .app bundle itself is still assembled by hand rather
# than by xcodebuild, same approach as MonitorDim's bundle-macos.sh.
#
# Signed with the hardened runtime (--options runtime): the process refuses
# injected libraries, unsigned executable memory and debugger attach, so
# nothing running as the user can borrow this app's Screen Recording and
# Accessibility grants by injecting into it. That flag blocks Apple Events
# too, which is what Safari/Chrome URL capture uses — Resources/MacTime
# .entitlements re-enables exactly that and nothing else. Works with any
# identity, self-signed included; only notarization needs a paid account.
#
# TCC permission grants (Screen Recording / Accessibility / Automation) are
# keyed to the signature. With the stable "MacTime Dev" identity they survive
# rebuilds; ad-hoc fallback means re-granting after every rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"

swift build -c "$config"

bin=".build/$config/MacTime"
app="publish/MacTime.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MacTime"
cp Resources/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
[ -f Resources/MacTime.icns ] && cp Resources/MacTime.icns "$app/Contents/Resources/"

# Prefer the stable "MacTime Dev" identity (tools/make-dev-identity.sh) so TCC
# grants survive rebuilds; fall back to ad-hoc only when it doesn't exist at all.
# When the identity exists but signing fails (errSecInternalComponent = this
# session isn't authorized to use the key, typical over ssh before
# set-key-partition-list), FAIL — a silent ad-hoc fallback would ship an app
# whose signature no longer matches the TCC grants.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "MacTime Dev"; then
    if ! codesign --force --options runtime \
                  --entitlements Resources/MacTime.entitlements \
                  -s "MacTime Dev" "$app"; then
        echo "error: signing with MacTime Dev failed (keychain not authorized in this session)." >&2
        echo "fix once, on the mac:  security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db" >&2
        rm -rf "$app"
        exit 1
    fi
    echo "signed: MacTime Dev (stable — permissions survive rebuilds)"
else
    codesign --force --options runtime \
             --entitlements Resources/MacTime.entitlements -s - "$app"
    echo "signed: ad-hoc (permissions reset every rebuild — run tools/make-dev-identity.sh once on the mac)"
fi

echo "Built: $app ($config)"
