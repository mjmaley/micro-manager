#!/usr/bin/env bash
# Run one Swift Testing suite with either full Xcode or recent Command Line Tools.
# CLT ships Testing.framework but may omit it from SwiftPM's search paths.
set -euo pipefail
cd "$(dirname "$0")/.."
SUITE="${1:-}"
if [[ $# != 1 || ! "$SUITE" =~ ^[A-Za-z][A-Za-z0-9]*Tests$ || ! -f "Tests/WLKitTests/$SUITE.swift" ]]; then
    echo "Usage: $0 <SwiftTestingSuiteName>" >&2
    exit 2
fi

FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
    exec swift test --filter "$SUITE"
fi

# This standalone linker uses SwiftPM's native Modules/ and WLKit.build/
# layout. Swift 6.4 defaults to swiftbuild, which has a different layout.
swift build --build-system native --target WLKit
BIN="$(swift build --build-system native --show-bin-path)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wl-swift-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/Runner.swift" <<'SWIFT'
import Darwin
import Testing
@main struct Runner {
    static func main() async {
        let code: CInt = await Testing.__swiftPMEntryPoint()
        exit(code)
    }
}
SWIFT

swiftc -parse-as-library \
    -I "$BIN/Modules" -F "$FRAMEWORKS" -framework Testing \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS/../usr/lib" \
    -plugin-path "$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing" \
    "Tests/WLKitTests/$SUITE.swift" "$TMP/Runner.swift" \
    "$BIN"/WLKit.build/*.swift.o -o "$TMP/Tests"
"$TMP/Tests"
