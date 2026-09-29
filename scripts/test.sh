#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ "$developer_dir" == /Library/Developer/CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
    # SwiftPM's generated runner does not inherit the test target's framework search path.
    exec swift test -Xswiftc "-F$frameworks" "$@"
fi
exec swift test "$@"
