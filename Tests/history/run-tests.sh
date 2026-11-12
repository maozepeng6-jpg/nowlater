#!/bin/zsh
set -eu
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/nowlater-history-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
SDK_PATH="${NOWLATER_TEST_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK_PATH" ]]; then SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"; fi
xcrun swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework Combine \
  -o "$TEST_ROOT/history-tests" "$PROJECT_ROOT/Sources/Store.swift" \
  "$PROJECT_ROOT/Tests/history/HistoryStoreTests.swift"
NOWLATER_HOME="$TEST_ROOT/data" "$TEST_ROOT/history-tests"
