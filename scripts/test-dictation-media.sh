#!/usr/bin/env bash
# Compatibility shortcut for the media regression suite.
set -euo pipefail
exec "$(dirname "$0")/test-swift-suite.sh" DictationMediaTests
