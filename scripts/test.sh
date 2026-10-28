#!/bin/zsh
# Runs `swift test`, working around the Command Line Tools toolchain flaking with
# "plugin for module 'TestingMacros' not found" (a swift-build bug seen with CLT-only installs). Loading the testing
# macros into the compiler itself avoids it; a plain rerun, or `rm -rf .build`, is the fallback.
# Usage: scripts/test.sh [swift test args...]
cd "${0:A:h}/.." || exit 1
plugin=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
extra=()
[[ -f $plugin ]] && extra=(-Xswiftc -load-plugin-library -Xswiftc $plugin)
for attempt in 1 2 3 4; do
  out=$(swift test "${extra[@]}" "$@" 2>&1); rc=$?
  if print -r -- "$out" | grep -q "plugin for module 'TestingMacros' not found"; then
    echo "[test.sh] TestingMacros plugin flake (attempt $attempt), retrying..." >&2
    [[ $attempt == 3 ]] && rm -rf .build
    continue
  fi
  print -r -- "$out" | grep -v "ld: warning"
  exit $rc
done
echo "[test.sh] gave up after repeated TestingMacros plugin failures" >&2
exit 1
