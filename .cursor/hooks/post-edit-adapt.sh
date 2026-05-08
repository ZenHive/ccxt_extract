#!/usr/bin/env bash
# Cursor postToolUse (Write / TabWrite) → marketplace post-edit-check.sh (format, compile, credo, tests, …)
# stdin:  https://cursor.com/docs/hooks — postToolUse JSON (same tool_input shape as other tool hooks)
# stdout: { additional_context?: string } or {} — Cursor injects additional_context after the tool result

set -euo pipefail

find_mix_project_root_from_file() {
  local f="$1"
  local d
  d="$(cd "$(dirname "$f")" && pwd)"
  while true; do
    if [[ -f "$d/mix.exs" ]]; then
      echo "$d"
      return 0
    fi
    [[ "$d" == "/" ]] && return 1
    d="$(dirname "$d")"
  done
}

resolve_marketplace_scripts() {
  local repo_root="$1"
  if [[ -n "${CLAUDE_MARKETPLACE_ELIXIR_SCRIPTS:-}" ]]; then
    echo "${CLAUDE_MARKETPLACE_ELIXIR_SCRIPTS%/}"
    return 0
  fi
  local sibling="${repo_root}/../claude-marketplace-elixir/plugins/elixir/scripts"
  if [[ -f "$sibling/post-edit-check.sh" ]]; then
    cd "$sibling" && pwd
    return 0
  fi
  return 1
}

RAW_INPUT=$(cat)

CLAUDE_JSON=$(echo "$RAW_INPUT" | jq -c '
  (
    .tool_input.file_path //
    .tool_input.path //
    .tool_input.file //
    .file_path //
    .path //
    ""
  ) as $fp |
  if ($fp == "") then
    { tool_input: { file_path: "" } }
  else
    { tool_input: { file_path: $fp } }
  end
')

FILE_PATH=$(echo "$CLAUDE_JSON" | jq -r '.tool_input.file_path')
if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
  echo '{}'
  exit 0
fi

REPO_ROOT=""
REPO_ROOT="$(find_mix_project_root_from_file "$FILE_PATH")" || {
  echo '{}'
  exit 0
}

if ! MP_SCRIPTS="$(resolve_marketplace_scripts "$REPO_ROOT")"; then
  jq -n \
    --arg msg "Post-edit hook: cannot find claude-marketplace-elixir scripts. Clone claude-marketplace-elixir next to this Mix project, or export CLAUDE_MARKETPLACE_ELIXIR_SCRIPTS=/path/to/plugins/elixir/scripts" \
    '{additional_context: ("❌ " + $msg)}'
  exit 0
fi

INNER_HOOK="$MP_SCRIPTS/post-edit-check.sh"
INNER_OUT=""
INNER_OUT=$(echo "$CLAUDE_JSON" | "$INNER_HOOK")

if ! echo "$INNER_OUT" | jq -e . >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

echo "$INNER_OUT" | jq '
  if .suppressOutput == true then
    {}
  elif (.hookSpecificOutput.additionalContext | type) == "string" then
    { additional_context: .hookSpecificOutput.additionalContext }
  else
    {}
  end
'

exit 0
