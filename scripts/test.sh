#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ "$developer_dir" == /Library/Developer/CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
    # SwiftPM's generated runner does not inherit the test target's framework search path.
    test_flags=(-Xswiftc "-F$frameworks")
else
    test_flags=()
fi
mkdir -p .build
log="$(mktemp "$PWD/.build/oss-fix-tests-XXXXXX")"
trap 'rm -f "$log"' EXIT
swift test ${test_flags[@]+"${test_flags[@]}"} "$@" 2>&1 | tee "$log"
# XCTest の0件表示ではなく Swift Testing の実行結果を確認する。
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' "$log"; then
    echo "Swift Testing の成功したテストがありません" >&2
    exit 1
fi
