#!/usr/bin/env bash
# Maxx Whip check: what the director looks at after each agent round, in a few lines: git status, diff --stat and,
# given a test command, its result. The whole test output stays in a log; on failure the last 60 lines are printed
# (where test runners put the failures), which is what goes back to the agent as feedback.
#   bash whip-check.sh "npm test"
#   bash whip-check.sh                  git only

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "== git status --short"
  git status --short 2>/dev/null | head -n 40
  echo "== git diff --stat"
  git diff --stat 2>/dev/null | tail -n 25
fi
[ $# -eq 0 ] && exit 0

cmd="$*"
dir="${TMP:-/tmp}/claude-whip"
mkdir -p "$dir"
find "$dir" -type f -mtime +7 -delete 2>/dev/null
log="$dir/$(date +%Y%m%d-%H%M%S)-check-$$.log"
# A runner left in watch mode would never end: stopped after 20 minutes (WHIP_CHECK_TIMEOUT, in seconds).
if command -v timeout >/dev/null 2>&1; then
  timeout "${WHIP_CHECK_TIMEOUT:-1200}" bash -c "$cmd" </dev/null >"$log" 2>&1
else
  bash -c "$cmd" </dev/null >"$log" 2>&1
fi
code=$?
[ $code -eq 124 ] && echo "(stopped after ${WHIP_CHECK_TIMEOUT:-1200} s: a test runner in watch mode? run it once, e.g. --run or CI=1)" >>"$log"
shown="$log"; command -v cygpath >/dev/null 2>&1 && shown=$(cygpath -w "$log")
if [ $code -eq 0 ]; then
  echo "== tests passed: $cmd"
  tail -n 5 "$log"
else
  echo "== tests FAILED (exit $code): $cmd (full output: $shown)"
  tail -n 60 "$log"
fi
exit $code
