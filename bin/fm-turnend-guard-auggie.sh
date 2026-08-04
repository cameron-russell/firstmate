#!/usr/bin/env bash
# auggie Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# auggie Stop hooks are passive in the interactive TUI (verified, auggie 0.34.0):
# neither exit 2 nor a {"decision":"block"} JSON output forces a continuation, and
# auggie's own bundle documents that exit code 2 only blocks for PreToolUse. This
# adapter still uses the shared primary-scoped predicate in fm-turnend-guard.sh.
# When that predicate says the primary would end blind, the adapter forces one
# same-session follow-up by running `auggie --resume <conversation_id>` with a
# guard instruction. AUGGIE_TURNEND_GUARD_ACTIVE is the loop guard: the nested
# turn's own Stop hook exits without spawning another nested turn.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

[ -n "${AUGGIE_TURNEND_GUARD_ACTIVE:-}" ] && exit 0

ROOT=${AUGMENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.conversation_id // empty' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-auggie.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
fm_operational_input_encode turn-end-guard \
  "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$REASON" \
  PROMPT || exit 0

AUGGIE_TURNEND_GUARD_ACTIVE=1 \
  auggie --resume "$SESSION_ID" \
    --print --quiet \
    "$PROMPT" >/dev/null 2>&1 || true
