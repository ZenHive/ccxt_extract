#!/usr/bin/env bash
# Cursor preToolUse hook: rewrite agent Shell `mix test` → `mix test.json` inside Mix projects.
# Output matches Cursor hooks schema (permission + updated_input), not Claude hookSpecificOutput.
#
# Mirrors claude-marketplace-elixir scripts/prefer-test-json.sh detection logic without sourcing plugin lib.sh.

set -euo pipefail

RAW=$(cat)

COMMAND=$(echo "$RAW" | jq -r '.tool_input.command // empty')
if [[ -z "$COMMAND" || "$COMMAND" == "null" ]]; then
  echo '{}'
  exit 0
fi

# Use [[:space:]] — BSD grep (macOS) does not treat \s as whitespace in ERE.
if ! echo "$COMMAND" | grep -qE 'mix[[:space:]]+test([[:space:]]|$)'; then
  echo '{}'
  exit 0
fi

if echo "$COMMAND" | grep -qE 'mix[[:space:]]+test\.[a-z]'; then
  echo '{}'
  exit 0
fi

HOOK_CWD=$(echo "$RAW" | jq -r '.tool_input.working_directory // empty')
if [[ -z "$HOOK_CWD" ]]; then
  HOOK_CWD=$(echo "$RAW" | jq -r '.cwd // empty')
fi
if [[ -z "$HOOK_CWD" ]]; then
  HOOK_CWD="${CURSOR_PROJECT_DIR:-}"
fi
if [[ -z "$HOOK_CWD" ]]; then
  HOOK_CWD=$(echo "$RAW" | jq -r '.workspace_roots[0] // empty')
fi

if [[ -z "$HOOK_CWD" || ! -d "$HOOK_CWD" ]]; then
  echo '{}'
  exit 0
fi

find_mix_project_root_from_dir() {
  local dir="$1"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/mix.exs" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

if ! find_mix_project_root_from_dir "$HOOK_CWD" >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

NEW_CMD=$(echo "$COMMAND" | sed -E 's/mix test([[:space:]]|$)/mix test.json\1/')
if [[ "$NEW_CMD" == "$COMMAND" ]]; then
  echo '{}'
  exit 0
fi

echo "$RAW" | jq --arg new "$NEW_CMD" '
  ((.tool_input // {}) + {command: $new}) as $u |
  {permission: "allow", updated_input: $u}
'
