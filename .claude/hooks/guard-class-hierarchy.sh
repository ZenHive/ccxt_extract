#!/usr/bin/env bash
# PreToolUse guard for priv/discoveries/class_hierarchy.json.
#
# class_hierarchy.json is the ONE committed file under priv/discoveries/ —
# every other discovery file is gitignored derived state. lib/ccxt_extract/
# tiers.ex reads it at COMPILE TIME via @external_resource, and tier-flag
# expansion (family inheritance) depends on it. Hand-editing drifts it from
# the extracted corpus. CLAUDE.md flags it as "worth a manual pause when it
# drifts." This hook turns that manual pause into an explicit confirm.
#
# Degrades safe: any parse failure falls through to exit 0 (tool proceeds).

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$file_path" in
  */priv/discoveries/class_hierarchy.json)
    cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "priv/discoveries/class_hierarchy.json is the only committed discovery file — tiers.ex reads it at compile time via @external_resource and tier-flag family inheritance depends on it. Prefer regenerating it with `mix ccxt_extract.classes` over hand-editing. Confirm only if this hand-edit is intentional."
  }
}
JSON
    ;;
esac

exit 0
