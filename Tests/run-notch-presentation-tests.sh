#!/bin/zsh
set -eu
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/nowlater-presentation-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
SDK_PATH="${NOWLATER_TEST_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK_PATH" ]]; then SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"; fi
TEST_SOURCES=()
for source in "$PROJECT_ROOT"/Sources/*.swift; do
  if [[ "$source" != */main.swift ]]; then TEST_SOURCES+=("$source"); fi
done
xcrun swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework SwiftUI \
  -o "$TEST_ROOT/tests" "${TEST_SOURCES[@]}" "$PROJECT_ROOT/Tests/NotchPresentationTests.swift"
"$TEST_ROOT/tests"
