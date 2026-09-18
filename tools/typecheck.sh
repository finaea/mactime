#!/bin/bash
# Type-checks the whole app, the SwiftUI views included.
#   tools/typecheck.sh
#
# Why this exists: `swift build` cannot compile this project on a Command Line
# Tools install. SwiftUI's `@State` is a macro, the SwiftUIMacros plugin that
# expands it ships with Xcode, and without it every `@State` fails before the
# type checker sees any of the code — ~114 errors in debug, ~290 in release,
# none of them about anything you wrote. tools/run-tests.sh sidesteps that by
# compiling only the SwiftUI-free sources, which leaves UI/*.swift with no
# coverage whatsoever. This closes that hole.
#
# `State()` is the only macro this app uses — @StateObject, @AppStorage,
# @ObservedObject and @Published are plain property wrappers and expand fine —
# so this copies the tree, swaps `@State` for an equivalent wrapper, and
# type-checks the result. It proves the app type-checks. It does not run it,
# and where a real toolchain exists `swift build` is still the better answer.
#
# Reading the output: warnings are printed as-is and are not failures, so
# compare against a clean checkout before calling one a regression. Paths are
# rewritten back to Sources/ so they point at the real files.
#
# Keeping the shim faithful — it is only as good as these hold:
#   - `@State` is matched textually (the token followed by whitespace), so
#     `@StateObject` is deliberately left alone.
#   - wrappedValue gets a nonmutating setter and projectedValue a real Binding,
#     which is what view bodies and `$foo` actually depend on.
#   - Underscore access to the storage (`_foo = State(...)`) would not compile
#     against the shim. Nothing here does that for `@State`; DayView's
#     `_model = StateObject(...)` is a different wrapper and is untouched.
set -euo pipefail

cd "$(dirname "$0")/.."

src="Sources/MacTime"
work=".build/typecheck"

rm -rf "$work"
mkdir -p "$work"
cp -R "$src/." "$work/"

# The swap. BSD sed (this is a macOS-only project).
find "$work" -name '*.swift' -print0 | xargs -0 sed -i '' -E 's/@State([[:space:]])/@StateShim\1/g'

cat > "$work/_StateShim.swift" <<'SHIM'
import SwiftUI

/// Stands in for SwiftUI's `@State` so the views can be type-checked without
/// the macro plugin. A class box behind a nonmutating setter, because views are
/// structs that assign to their own state from non-mutating methods.
@propertyWrapper
struct StateShim<Value> {
    private final class Box {
        var value: Value
        init(_ v: Value) { value = v }
    }
    private let box: Box

    init(wrappedValue: Value) { box = Box(wrappedValue) }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}

extension StateShim {
    /// `@State private var keyMonitor: Any?` — declared with no initial value.
    init() where Value: ExpressibleByNilLiteral { self.init(wrappedValue: nil) }
}
SHIM

status=0
swiftc -typecheck -swift-version 5 -target arm64-apple-macos15.0 \
    $(find "$work" -name '*.swift' | sort) 2>&1 \
    | sed "s|$work/|$src/|g" || status=$?

if [ "$status" -eq 0 ]; then
    echo "ok — $src type-checks (SwiftUI views included)"
else
    echo "FAILED — see the errors above" >&2
fi
exit "$status"
