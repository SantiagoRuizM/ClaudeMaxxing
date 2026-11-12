#!/usr/bin/env bash
# Claude Whip runner: hands one task (stdin, usually a heredoc) to an agent CLI in the current folder, keeps its
# whole output in a log and prints only what the director needs: the agent's last answer, git status and diff --stat.
#   bash whip-run.sh codex <<'EOF'            a new task
#   bash whip-run.sh codex --resume <<'EOF'   feedback in the agent's last conversation (it keeps what it did)
# Agents run unattended inside the working tree (Codex: sandbox workspace-write; the others: their auto-approve flag).
# shortcut: --resume picks the agent's most recent conversation (Codex: the most recent in this folder); with two
# runs of the same agent at once it may pick the other one, upgrade by saving each run's conversation id.

agent="$1"
resume=""; [ "$2" = "--resume" ] && resume=1
task=$(cat)
if [ -z "$agent" ] || [ -z "${task//[[:space:]]/}" ]; then
  echo "usage: bash whip-run.sh <codex|agy|opencode|copilot> [--resume] <<'EOF' <task or feedback> EOF" >&2
  exit 2
fi
if ! command -v "$agent" >/dev/null 2>&1; then
  echo "whip-run: $agent is not installed or not on PATH" >&2
  exit 2
fi

dir="${TMP:-/tmp}/claude-whip"
mkdir -p "$dir"
stamp="$(date +%Y%m%d-%H%M%S)-$agent-$$"
log="$dir/$stamp.log"
last="$dir/$stamp.last.txt"

case "$agent:$resume" in
  codex:)    printf '%s' "$task" | codex exec --skip-git-repo-check -s workspace-write -o "$last" - >"$log" 2>&1 ;;
  codex:1)   printf '%s' "$task" | codex exec resume --last --skip-git-repo-check -c 'sandbox_mode="workspace-write"' -o "$last" - >"$log" 2>&1 ;;
  agy:)      agy -p "$task" --dangerously-skip-permissions </dev/null >"$log" 2>&1 ;;
  agy:1)     agy -c -p "$task" --dangerously-skip-permissions </dev/null >"$log" 2>&1 ;;
  opencode:) opencode run --auto "$task" </dev/null >"$log" 2>&1 ;;
  opencode:1) opencode run --continue --auto "$task" </dev/null >"$log" 2>&1 ;;
  copilot:)  copilot -p "$task" --allow-all-tools -s --no-color </dev/null >"$log" 2>&1 ;;
  copilot:1) copilot --continue -p "$task" --allow-all-tools -s --no-color </dev/null >"$log" 2>&1 ;;
  *) echo "whip-run: unknown agent '$agent' (codex, agy, opencode, copilot)" >&2; exit 2 ;;
esac
code=$?

shown="$log"; command -v cygpath >/dev/null 2>&1 && shown=$(cygpath -w "$log")
echo "== $agent ${resume:+(resumed) }finished with exit code $code (full output: $shown)"
if [ -s "$last" ]; then tail -n 60 "$last"; else tail -n 60 "$log"; fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # stderr off: line-ending warnings would cost the director tokens for nothing.
  echo "== git status --short"
  git status --short 2>/dev/null | head -n 40
  echo "== git diff --stat"
  git diff --stat 2>/dev/null | tail -n 25
fi
exit $code
