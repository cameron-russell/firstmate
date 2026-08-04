#!/usr/bin/env bash
# Behavior tests for the verified auggie (Augment CLI) crewmate adapter:
# detection, launch template, worktree settings.json (turn-end Stop hook plus
# autonomy allow-list), secondmate autonomy, teardown cleanup, busy signature,
# composer glyph, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-auggie-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="auggie-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_auggie_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" auggie --mode no-mistakes --yolo off "$@" 2>&1
}

read_case() {
  # shellcheck disable=SC2034  # CASE_DIR is used by some callers, not all.
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR ID <<EOF
$1
EOF
}

test_auggie_launch_template_and_settings_file() {
  local rec out settings launch
  rec=$(make_spawn_case launch)
  read_case "$rec"
  out=$(run_auggie_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$ID" --model some/model --effort high)
  assert_contains "$out" "spawned $ID harness=auggie" "auggie spawn did not report success"
  settings="$WT_DIR/.augment/settings.local.json"
  assert_present "$settings" "auggie worktree .augment/settings.local.json was not written"
  assert_absent "$WT_DIR/.augment/settings.json" "auggie crew must not write the tracked primary settings.json path"
  assert_grep '"Stop"' "$settings" "auggie settings.local.json lacks the turn-end Stop hook"
  # The Stop hook path is the real (symlink-resolved) state dir, which may differ
  # from $HOME_DIR on macOS (/var -> /private/var), so assert on the task-scoped
  # turn-ended filename rather than the full home path.
  assert_grep "$ID.turn-ended" "$settings" "auggie Stop hook does not point at the task turn-end file"
  assert_grep '"toolPermissions"' "$settings" "auggie settings.local.json lacks the autonomy allow-list"
  assert_grep '"toolName":"terminal"' "$settings" "auggie allow-list lacks the terminal tool"
  assert_grep '"toolName":"launch-process"' "$settings" "auggie allow-list lacks the legacy launch-process alias"
  launch="$HOME_DIR/state/$ID.meta"
  assert_grep 'harness=auggie' "$launch" "auggie meta lost its harness"
  assert_grep 'model=some/model' "$launch" "auggie meta lost the requested model"
  assert_grep 'effort=high' "$launch" "auggie meta did not retain the unsupported effort axis"
  pass "fm-spawn: auggie writes a worktree settings.local.json with turn-end hook and autonomy allow-list"
}

test_auggie_secondmate_autonomy_branch_is_wired() {
  # The secondmate spawn path needs a provisioned firstmate home, which is out of
  # scope for a harness unit test. Assert instead that the secondmate autonomy
  # branch exists and writes an allow-list-only settings.json (no Stop hook), so
  # a regression that drops it is caught without standing up a full secondmate.
  local block
  block=$(awk '/# auggie secondmate autonomy:/{f=1} f{print} /^fi$/{if(f)exit}' "$SPAWN")
  printf '%s' "$block" | grep -Fq 'auggie*)' \
    || fail "fm-spawn lost the auggie secondmate autonomy case"
  printf '%s' "$block" | grep -Fq '.augment/settings.local.json' \
    || fail "auggie secondmate branch no longer writes the gitignored settings.local.json path"
  printf '%s' "$block" | grep -Fq 'auggie_permissions_json' \
    || fail "auggie secondmate branch no longer writes the autonomy allow-list"
  printf '%s' "$block" | grep -Fq '"Stop"' \
    && fail "auggie secondmate branch wrongly writes a turn-end Stop hook"
  # The shared allow-list owner must itself carry the tool permissions.
  grep -Fq '"toolPermissions"' "$SPAWN" \
    || fail "fm-spawn lost the auggie_permissions_json allow-list owner"
  pass "fm-spawn: auggie secondmate autonomy branch writes an allow-list without a turn-end hook"
}

test_auggie_detection_marker_and_ancestry() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  # A node interpreter frame whose args carry augment.mjs must resolve to auggie.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid= prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:5151) printf 'node\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:5151) printf '1\n' ;;
  ppid=:*) printf '5151\n' ;;
  args=:5151) printf 'node /x/node_modules/@augmentcode/auggie/augment.mjs\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u AUGMENT_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = auggie ] || fail "auggie node/augment.mjs ancestry detection returned '$out'"
  out=$(AUGMENT_AGENT=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = auggie ] || fail "AUGMENT_AGENT marker did not select auggie, got '$out'"
  out=$(CLAUDECODE=1 AUGMENT_AGENT=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: auggie is detected by AUGMENT_AGENT marker and node/augment.mjs ancestry"
}

test_auggie_busy_signature_is_scoped() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() { case "${1:-}" in capture-pane) cat "$capture" ;; *) return 0 ;; esac; }
  printf '  * esc to interrupt\n> \n' > "$capture"
  fm_pane_is_busy fake auggie || fail "auggie busy 'esc to interrupt' was not recognized"
  printf '? to show shortcuts\n> \n' > "$capture"
  if fm_pane_is_busy fake auggie; then
    fail "auggie idle footer was misread as busy"
  fi
  pass "busy detection: auggie 'esc to interrupt' is busy while its idle footer stays idle"
}

test_auggie_composer_glyph_needs_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '›')
  [ "$out" = empty ] || fail "auggie's bordered bare > composer should read empty, got '$out'"
  pass "composer classifier: auggie's › prompt glyph is already treated as an empty agent composer"
}

test_auggie_session_lock_identity() {
  local home fakebin out
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /x/@augmentcode/auggie/augment.mjs'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize auggie as a live holder"
  pass "fm-lock recognizes auggie's node/augment.mjs ancestry as a live holder"
}

test_auggie_teardown_removes_settings_file() {
  local rec out
  rec=$(make_spawn_case teardown)
  read_case "$rec"
  out=$(run_auggie_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$ID")
  assert_present "$WT_DIR/.augment/settings.local.json" "auggie spawn should write the settings file before teardown"
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$ID" --force >/dev/null 2>&1 || fail "auggie teardown failed"
  assert_absent "$WT_DIR/.augment/settings.local.json" "auggie worktree settings.local.json survived teardown"
  pass "fm-teardown: auggie worktree settings.local.json is removed on teardown"
}

test_auggie_launch_template_and_settings_file
test_auggie_secondmate_autonomy_branch_is_wired
test_auggie_teardown_removes_settings_file
test_auggie_detection_marker_and_ancestry
test_auggie_busy_signature_is_scoped
test_auggie_composer_glyph_needs_no_override
test_auggie_session_lock_identity
