#!/bin/bash
# Compiles and runs the checks in Tests/ — the pure date math, the day-key and
# retention rules, the capture privacy rules, and the store's erasure paths
# against a throwaway database.
#   tools/run-tests.sh
#
# Not a SwiftPM test target on purpose: `swift test` builds the app target too,
# and this Command Line Tools install lacks the SwiftUI macro plugin needed by
# @State, so `swift build` cannot succeed here either. Compiling only the
# sources these checks exercise keeps them runnable. AppKit is fine — Format and
# ImageCache import it — the one thing that can't be in this list is SwiftUI.
#
# DataKeychain.swift is compiled but must never be *called*: the checks build
# their own key and pass it to Store, because a check run must not read the key
# the real store is sealed with, and must certainly not be what creates it.
# Settings.swift carries the same hazard and the same answer — point
# `Settings.d` at a throwaway suite before touching it, so a check run can't
# read or overwrite the user's real settings.
# tools/typecheck.sh covers the SwiftUI files this can't reach.
set -euo pipefail

cd "$(dirname "$0")/.."

out=".build/timemath-tests"
mkdir -p .build

swiftc -swift-version 5 -target arm64-apple-macos15.0 \
    Sources/MacTime/Support/Format.swift \
    Sources/MacTime/Support/DayKey.swift \
    Sources/MacTime/Support/URLPolicy.swift \
    Sources/MacTime/Support/CapturePolicy.swift \
    Sources/MacTime/Support/Settings.swift \
    Sources/MacTime/Support/TimeMath.swift \
    Sources/MacTime/Support/ImageCache.swift \
    Sources/MacTime/Store/Database.swift \
    Sources/MacTime/Store/Crypto.swift \
    Sources/MacTime/Store/DataKeychain.swift \
    Sources/MacTime/Store/Rewrap.swift \
    Sources/MacTime/Store/Store.swift \
    Sources/MacTime/Store/Erase.swift \
    Tests/TimeMathTests/main.swift \
    -o "$out"

"$out"
