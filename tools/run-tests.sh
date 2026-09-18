#!/bin/bash
# Compiles and runs the checks in Tests/ — the pure date math, the day-key and
# retention rules, and the store's erasure paths against a throwaway database.
#   tools/run-tests.sh
#
# Not a SwiftPM test target on purpose: `swift test` builds the app target too,
# and this Command Line Tools install lacks the SwiftUI macro plugin needed by
# @State, so `swift build` cannot succeed here either. Compiling only the
# sources these checks exercise keeps them runnable. AppKit is fine — Format and
# ImageCache import it — the one thing that can't be in this list is SwiftUI.
set -euo pipefail

cd "$(dirname "$0")/.."

out=".build/timemath-tests"
mkdir -p .build

swiftc -swift-version 5 -target arm64-apple-macos15.0 \
    Sources/MacTime/Support/Format.swift \
    Sources/MacTime/Support/DayKey.swift \
    Sources/MacTime/Support/TimeMath.swift \
    Sources/MacTime/Support/ImageCache.swift \
    Sources/MacTime/Store/Database.swift \
    Sources/MacTime/Store/Store.swift \
    Sources/MacTime/Store/Erase.swift \
    Tests/TimeMathTests/main.swift \
    -o "$out"

"$out"
