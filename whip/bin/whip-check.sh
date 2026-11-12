#!/usr/bin/env bash
# Claude Whip check: what the director looks at after each agent round, in a few lines: git status, diff --stat and,
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
log="$dir/$(date +%Y%m%d-%H%M%S)-check-$$.log"
bash -c "$cmd" </dev/null >"$log" 2>&1
code=$?
shown="$log"; command -v cygpath >/dev/null 2>&1 && shown=$(cygpath -w "$log")
if [ $code -eq 0 ]; then
  echo "== tests passed: $cmd"
  tail -n 5 "$log"
else
  echo "== tests FAILED (exit $code): $cmd (full output: $shown)"
  tail -n 60 "$log"
fi
exit $code
