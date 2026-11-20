---
name: claude-whip
description: Director mode for when the Claude plan runs low (ClaudeMaxxing > Claude Whip). An agent (Codex, Antigravity, OpenCode or Copilot) writes the code; Claude plans, watches git, runs the tests and sends the agent feedback until the tests pass. Use when a prompt carries the [Claude Whip] note, when a tool call is denied by Claude Whip, or when the user asks to delegate the work to other agents.
---

# Claude Whip

The Claude plan is nearly spent, so you direct and an agent writes the code. Every token you read or write costs the plan; the agent's do not. While Claude Whip is on, Edit, Write, subagents and shell commands other than git, reading, the agents and the check are blocked.

Two scripts sit in `bin/`, two folders above this skill's base directory (the `[Claude Whip]` note on each prompt gives their full paths and the agents that are on):

- `whip-run.sh <agent> [--resume]`: hands the task or feedback on stdin to the agent. It prints the agent's last answer, `git status` and `git diff --stat`. `--resume` continues the agent's last conversation, so it remembers what it did.
- `whip-check.sh "<test command>"`: prints `git status`, `git diff --stat` and the test result. On failure it prints the last 60 lines of the test output; the whole output goes to a log.

## The feedback loop

1. **Understand, cheaply.** Start with `git status` and `git diff --stat`. Find with Grep and Glob. Read only the ranges you need. Find the project's test command in CLAUDE.md, package.json or the README. Run `whip-check.sh` with it once, so you know what was already failing before the agent starts.
2. **Brief.** Write one self-contained task, since the agent has not seen this conversation:
   - the goal and why;
   - the files to change, and the ones not to touch;
   - the project's rules that apply;
   - the test command it must leave passing;
   - "do not commit or push".
3. **Agent round.** Hand the brief over in one Bash call with `run_in_background: true`, then wait for the notification:
   ```bash
   bash "<bin>/whip-run.sh" codex <<'EOF'
   <the brief>
   EOF
   ```
4. **Check.** Run `bash "<bin>/whip-check.sh" "<test command>"` yourself. Read `git diff -- <file>` for the files that matter, never the whole diff. Look for:
   - the tests: did they pass, and did anything that passed before break?
   - files touched outside the task;
   - the goal: was it actually met, beyond tests passing?
5. **Feedback.** If anything is wrong, resume the same agent with only what it needs:
   - the failing test names and the key lines of the failure (not the whole log);
   - what in the diff is wrong, as file and line;
   - what to keep.
   ```bash
   bash "<bin>/whip-run.sh" codex --resume <<'EOF'
   Tests still fail: <test> - <one-line reason>. In src/x.ts:42 you <problem>; keep <what is right>. Run <test command> before you finish.
   EOF
   ```
   Then go back to step 4.
6. **Stop.** Stop when the tests pass and the diff does what was asked, or after 3 feedback rounds. Then report to the user:
   - what the agent did;
   - the rounds, and what each one fixed;
   - the final test result;
   - what remains.

   Commit only if the user asked.

One agent per working tree at a time: two agents editing the same files overwrite each other. For parallel work, give each agent disjoint files, or a `git worktree` of its own (`cd` into it first).

## Picking an agent

- **codex**: the default for code changes; runs in the `workspace-write` sandbox.
- **agy** (Google Antigravity CLI): large changes across many files, and a second opinion.
- **opencode**, **copilot**: second opinions, or when the others are out of quota.

If an agent fails with a quota or login error, brief another agent that is on, from scratch (`--resume` only continues the same agent). If none works, tell the user.
