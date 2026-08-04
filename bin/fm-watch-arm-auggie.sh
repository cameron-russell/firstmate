#!/usr/bin/env bash
# auggie background-notify wrapper for the firstmate watcher arm.
#
# The firstmate primary running on auggie (the Augment CLI) arms supervision by
# launching THIS wrapper as a background process (launch-process wait=false). It
# runs the shared, harness-neutral arm (bin/fm-watch-arm.sh), which blocks until
# it has an actionable wake or a failure, then prints one status/reason line and
# exits. auggie surfaces a background process's output back into the conversation
# only through the <augment-user-message>...</augment-user-message> marker (the
# documented background-notify mechanism, auggie's equivalent of Grok's synthetic
# task-completed message). This wrapper therefore captures the arm's final output
# and re-emits it inside that marker so the primary is auto-woken when the arm
# returns, instead of the wake being lost to a silently-exited background pane.
#
# It owns zero supervision policy: bin/fm-watch-arm.sh remains the single owner of
# arm/attach/verify/restart behavior. This wrapper only relays that one line and
# preserves the arm's exit status so a FAILED arm stays loud.
#
# All arguments are passed through to bin/fm-watch-arm.sh (e.g. --restart).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"

if [ ! -x "$ARM" ]; then
  printf '<augment-user-message>watcher: FAILED - bin/fm-watch-arm.sh missing; repair supervision manually</augment-user-message>\n'
  exit 1
fi

OUT=$("$ARM" "$@")
RC=$?

[ -n "$OUT" ] || OUT="watcher: FAILED - arm produced no status line"
printf '<augment-user-message>%s</augment-user-message>\n' "$OUT"
exit "$RC"
