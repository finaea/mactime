#!/bin/bash
# Compiles and runs the checks for the pure date math (Tests/TimeMathTests).
#   tools/run-tests.sh
#
# Not a SwiftPM test target on purpose: `swift test` builds the app target too,
# and this Command Line Tools install lacks the SwiftUI macro plugin needed by
# @State. Compiling only the sources these checks exercise keeps them runnable.
set -euo pipefail

cd "$(dirname "$0")/.."

out=".build/timemath-tests"
mkdir -p .build

swiftc -swift-version 5 -target arm64-apple-macos15.0 \
    Sources/MacTime/Support/Format.swift \
    Sources/MacTime/Support/TimeMath.swift \
    Tests/TimeMathTests/main.swift \
    -o "$out"

"$out"
