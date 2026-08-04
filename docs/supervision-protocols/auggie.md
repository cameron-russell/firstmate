Mode: auggie background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: arm with auggie's background process launcher, as its own call:

   `launch-process` with `wait: false` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm-auggie.sh`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The background arm remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's auggie hooks (`.augment/settings.json`) are active.

auggie surfaces a background process's completion by injecting its `<augment-user-message>...</augment-user-message>` output back into the conversation as a user message.
`bin/fm-watch-arm-auggie.sh` wraps the shared arm's one status/reason line in that marker so the primary is auto-woken when the arm returns.
When you receive that injected arm status line:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
3. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm-auggie.sh` call if work remains in flight or X mode still needs polling.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

auggie Stop hooks are passive: neither exit 2 nor a `{"decision":"block"}` output forces a continuation in the interactive TUI.
The primary project hook (`.augment/settings.json`) runs `bin/fm-turnend-guard-auggie.sh`, which forces at most one same-session follow-up via `auggie --resume <conversation_id>` when a turn would end blind.
That is a backstop, not the normal wake path.
After any forced follow-up, arm the watcher with the background protocol above.

Interactive TUI primary sessions are the supported supervision host.
Headless `auggie --print` runs one shot and exits, does not persist a live background wait, and does not reliably surface the injected auto-wake; do not run the primary firstmate as a one-shot headless process.
