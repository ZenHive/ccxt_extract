#!/usr/bin/env bash
# Cursor stop hook for Elixir projects.
#
# Fires once per agent turn-end. If any .ex/.exs files were touched in this turn
# AND `mix test.json` reports failures, emit a `followup_message` containing a
# compact failure digest. Cursor auto-submits that as the next user message, so
# the agent sees the breakage in its context and gets a chance to fix it before
# the loop terminates.
#
# Skips silently (returns {}) when:
#   - status is "aborted" (user explicitly stopped — don't intrude)
#   - no mix.exs at cwd (not an Elixir project)
#   - no .ex/.exs changes in the working tree (read-only / discussion turns)
#   - mix test reports green (nothing to follow up about)
#
# Output is ALWAYS valid JSON, never crashes mid-script.

set -uo pipefail

RAW=$(cat)

STATUS=$(echo "$RAW" | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)
if [[ "$STATUS" == "aborted" ]]; then
  echo '{}'
  exit 0
fi

# Project hooks: cwd is the workspace root. User-scope hooks run from ~/.cursor/.
# Prefer CURSOR_PROJECT_DIR env var (documented as always-present for hook
# scripts); fall back to workspace_roots[0] from the input JSON.
WORKDIR="${CURSOR_PROJECT_DIR:-}"
if [[ -z "$WORKDIR" ]]; then
  WORKDIR=$(echo "$RAW" | jq -r '.workspace_roots[0] // empty' 2>/dev/null || true)
fi
if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
  cd "$WORKDIR" || true
fi

if [[ ! -f mix.exs ]]; then
  echo '{}'
  exit 0
fi

if [[ -z "$(git status --porcelain -- '*.ex' '*.exs' 2>/dev/null)" ]]; then
  echo '{}'
  exit 0
fi

# Mutex: only one stop-hook may run mix test.json at a time. macOS has no
# flock; mkdir is atomic on POSIX. Without this, multiple Cursor turn-ends
# (or the loop_limit=3 followup-message re-fire) could spawn concurrent
# BEAMs that overheat the machine. Stale locks (>10 min, double the 300s
# script timeout) are reclaimed so a SIGKILLed prior run doesn't wedge us.
LOCK_DIR="/tmp/cursor-stop-on-fail.lock"
if [[ -d "$LOCK_DIR" ]] && [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo '{}'
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

OUT_FILE="/tmp/cursor-stop-on-fail-$$.json"
mix test.json --quiet --output "$OUT_FILE" >/dev/null 2>&1 || true

if [[ ! -s "$OUT_FILE" ]]; then
  rm -f "$OUT_FILE"
  echo '{}'
  exit 0
fi

RESULT=$(jq -r '.summary.result // "unknown"' "$OUT_FILE" 2>/dev/null || echo unknown)

if [[ "$RESULT" != "failed" ]]; then
  rm -f "$OUT_FILE"
  echo '{}'
  exit 0
fi

SUMMARY=$(jq -r '"\(.summary.failed)/\(.summary.total) tests failed (seed \(.seed))"' "$OUT_FILE")
FAILURES=$(jq -r '
  .tests
  | map(select(.state == "failed"))
  | .[0:5]
  | map(
      "  - \(.module).\(.name)\n      "
      + (.failures[0].message | gsub("\n"; " // ") | .[0:240])
    )
  | join("\n")
' "$OUT_FILE")

MSG="Cursor stop hook detected mix test failures: ${SUMMARY}.

${FAILURES}

Run \`mix test.json --quiet --failed\` to iterate. Don't claim done until green."

rm -f "$OUT_FILE"

jq -n --arg m "$MSG" '{followup_message: $m}'
exit 0
