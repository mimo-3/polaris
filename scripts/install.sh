#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${INSTALL_DIR:-/Applications}"
staging="$(mktemp -d "$destination/oss-fix-install-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto build/Polaris.app "$staging/Polaris.app"
# 同じファイルシステム内で交換する。失敗しても既存のアプリには触れない。
python3 - "$staging/Polaris.app" "$destination/Polaris.app" <<'PY'
import ctypes
import os
import sys
source, target = sys.argv[1:]
if os.path.lexists(target):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(target), 2) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), target)
else:
    os.rename(source, target)
PY
