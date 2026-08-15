#!/bin/bash
# Builds MacTime and assembles publish/MacTime.app. Runs on the mac.
#   tools/bundle-macos.sh [debug|release]   (default release)
#
# SwiftPM + CLT only — no Xcode on this machine, so the .app bundle is assembled
# by hand, same approach as MonitorDim's bundle-macos.sh. Ad-hoc signed: TCC
# permission grants (Screen Recording / Accessibility / Automation) are keyed to
# the signature, so expect to re-grant after rebuilds until there's a real
# Developer ID.
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
    if ! codesign --force -s "MacTime Dev" "$app"; then
        echo "error: signing with MacTime Dev failed (keychain not authorized in this session)." >&2
        echo "fix once, on the mac:  security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db" >&2
        rm -rf "$app"
        exit 1
    fi
    echo "signed: MacTime Dev (stable — permissions survive rebuilds)"
else
    codesign --force -s - "$app"
    echo "signed: ad-hoc (permissions reset every rebuild — run tools/make-dev-identity.sh once on the mac)"
fi

echo "Built: $app ($config)"
