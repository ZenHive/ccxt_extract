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

# DISABLED 2026-05-09: parallel-spawn pile-up overheated machine.
# Cursor cached the old hooks.json so disabling there alone wasn't enough.
# Re-enable by removing this short-circuit AND restoring the `stop` block
# in .cursor/hooks.json. Add a flock + lower timeout before re-enabling.
echo '{}'
exit 0

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
