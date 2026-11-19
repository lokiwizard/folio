#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then
  echo '用法: Scripts/verify.sh 普通论文.pdf 长篇图文.pdf' >&2
  exit 2
fi
mkdir -p .build/ModuleCache
cp -R Resources/Math .build/
install -m 755 Resources/PageTools/qpdf .build/qpdf
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -whole-module-optimization \
    -module-cache-path .build/ModuleCache -parse-as-library -D VERIFY Sources/*.swift Tests/Verify.swift -o .build/FolioVerify
work="$(mktemp -d "${TMPDIR:-/tmp}/folio-verify.XXXXXX")"
/usr/bin/caffeinate -di python3 - .build/FolioVerify "$work" "$1" "$2" <<'PY'
import os, sys, time, subprocess
profile = os.path.join(sys.argv[2], "home")
os.makedirs(profile)
for options in ([], ["--benchmark"]):
    env = dict(os.environ, CFFIXED_USER_HOME=profile, FOLIO_PROCESS_START=str(time.monotonic()))
    subprocess.run(sys.argv[1:] + options, env=env, check=True)
PY
