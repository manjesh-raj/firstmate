#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned auto-arm's silent-condition diagnostic
# (bin/fm-claude-stop-autoarm.sh + bin/fm-wake-lib.sh: fm_autoarm_record_inert /
# fm_autoarm_clear_inert, docs/turnend-guard.md).
#
# The 2026-09-15 frozen-ledger episode: many consecutive Stop events left
# state/.claude-autoarm-epoch frozen byte for byte with no marker anywhere, so
# nothing on disk could say whether an identity gate was rejecting the firings
# or the hook was never firing at all. state/.claude-autoarm-inert is the record
# that answers that. These tests pin its exact behavior so the diagnostic can't
# silently regress. Split into its own file (rather than edited into
# tests/fm-claude-stop-autoarm.test.sh, which mirrors upstream) so that file stays
# byte-for-byte syncable with upstream on every future fetch.
#
# Self-contained: this file duplicates the fixture/runner boilerplate from
# tests/fm-claude-stop-autoarm.test.sh rather than sourcing it, matching this
# suite's own convention of each test file being independently runnable.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm-inert)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-inert-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture: installed per test as <dir>/bin/fm-watch-arm.sh. Only the
# "actionable" variant is needed here - these tests exercise the pre-claim
# identity gates, which exit before the arm wrapper would ever run for the
# inert cases, and run it plainly for the retired/actionable case.
write_arm_fixture() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

inert_field() {  # <dir> <field>
  sed -n "1s/^.*[ ]*$2=\\([^ ]*\\).*$/\\1/p" "$1/state/.claude-autoarm-inert" 2>/dev/null || true
}

# Hold the session lock with a genuinely foreign LIVE harness process, then fire
# the hook from <runner>. Prints nothing; sets INERT_STATUS.
run_autoarm_against_live_foreign_owner() {  # <dir> <runner>
  local dir=$1 runner=$2 other
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  INERT_STATUS=0
  # A no-op leading statement only heuristically discourages bash's tail-call
  # optimization (it turned out to still collapse this single-hop case
  # intermittently even with one). An EXIT trap is a hard guarantee instead of
  # a heuristic: bash must remain resident to run it after the last command
  # finishes, so it cannot exec the hook in place of this process and erase
  # the "claude"-named identity the ancestry walk exists to find - exactly the
  # same collapse the nested-chain test in fm-claude-stop-autoarm.test.sh
  # guards against, but here it would falsely turn a resolved-ancestry case
  # into an unresolved one.
  printf '%s\n' '{"session_id":"s"}' \
    | FM_HOME="$dir" "$runner" -c 'trap : EXIT; "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1 \
    || INERT_STATUS=$?
  INERT_OWNER_PID=$other
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
}

test_live_foreign_owner_records_a_resolved_ancestry() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/inert-foreign")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir"
  # Fired from a claude-named process: the walk resolves a real harness
  # ancestry, so the rejection is the CORRECT one - a different live session
  # genuinely owns this home.
  run_autoarm_against_live_foreign_owner "$dir" "$FAKE_CLAUDE"
  expect_code 0 "$INERT_STATUS" "a live foreign owner must still keep the hook inert"
  assert_absent "$dir/state/arm-ran" "hook armed while another live session owned the home"
  assert_absent "$dir/state/.claude-autoarm-epoch" "hook wrote an epoch while another live session owned the home"
  assert_present "$dir/state/.claude-autoarm-inert" "a silent identity rejection left no diagnosable record"
  assert_equals identity-live-owner-outside-ancestry "$(inert_field "$dir" gate)" "wrong gate recorded for a live foreign owner"
  assert_equals "lock_pid=$INERT_OWNER_PID" "$(sed -n '1s/^.*detail=//p' "$dir/state/.claude-autoarm-inert")" "the record did not name the lock pid it rejected"
  assert_not_equals none "$(inert_field "$dir" ancestry)" "a hook with a real harness ancestry recorded none"
  pass "auto-arm: a live foreign owner is recorded with the resolved harness ancestry that proves the rejection was correct"
}

test_collapsed_harness_ancestry_is_recorded_as_none() {
  local dir other waited
  dir=$(make_primary_dir "$TMP_ROOT/inert-collapsed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  # The same gate, same exit, same silence as the test above - but fired from a
  # genuinely REPARENTED process. The double fork lets the intermediate parent
  # exit immediately, so the hook is adopted by init and its walk finds no
  # harness ancestor at all: the shape a detached async hook would have. The
  # test shell itself runs under a live harness in ordinary use, so nothing
  # short of a real reparent drives this signal apart from the case above.
  printf '%s\n' '{"session_id":"s"}' > "$dir/state/payload.json"
  ( FM_HOME="$dir" /bin/bash -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$FM_HOME/state/payload.json"' >/dev/null 2>&1 & ) &
  waited=0
  until [ -e "$dir/state/.claude-autoarm-inert" ] || [ "$waited" -ge 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_absent "$dir/state/arm-ran" "hook armed with no resolvable harness ancestry"
  assert_present "$dir/state/.claude-autoarm-inert" "an unresolvable ancestry left no diagnosable record"
  assert_equals identity-live-owner-outside-ancestry "$(inert_field "$dir" gate)" "wrong gate recorded for an unresolvable ancestry"
  assert_equals none "$(inert_field "$dir" ancestry)" "a reparented hook with no harness ancestor must record ancestry=none"
  pass "auto-arm: a reparented hook whose harness ancestry cannot be resolved records ancestry=none, distinguishing it from a correct foreign-owner rejection"
}

test_repeated_identical_inert_firings_accumulate_a_bounded_count() {
  local dir first_at lines
  dir=$(make_primary_dir "$TMP_ROOT/inert-count")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir"
  printf '\n' > "$dir/state/.lock"
  printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1 || true
  assert_equals 1 "$(inert_field "$dir" count)" "the first silent firing must record count=1"
  first_at=$(inert_field "$dir" first_at)
  printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1 || true
  assert_equals 2 "$(inert_field "$dir" count)" "a repeat of the identical silent condition must accumulate"
  assert_equals "$first_at" "$(inert_field "$dir" first_at)" "the accumulating record must keep the first occurrence time"
  lines=$(wc -l < "$dir/state/.claude-autoarm-inert" | tr -d ' ')
  assert_equals 1 "$lines" "the record must stay one overwritten line no matter how often the hook fires"
  assert_equals identity-no-session-lock "$(inert_field "$dir" gate)" "an empty session lock must record its own gate"
  pass "auto-arm: repeated identical silent firings accumulate a count in one bounded line"
}

test_inert_record_is_retired_once_identity_is_proven() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/inert-cleared")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir"
  printf 'gate=identity-no-session-lock count=9 first_at=1 last_at=1 hook_pid=1 ancestry=none detail=\n' \
    > "$dir/state/.claude-autoarm-inert"
  run_autoarm "$dir" >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "an owned firing must still arm and rewake"
  assert_absent "$dir/state/.claude-autoarm-inert" "a firing that proved its identity left the stale silent-condition record behind"
  pass "auto-arm: the silent-condition record is retired once a firing proves it owns the home"
}

test_inert_record_never_written_outside_the_identity_gates() {
  local base wt afk_dir idle_dir
  base="$TMP_ROOT/inert-scope-base"
  wt="$TMP_ROOT/inert-scope-wt"
  make_crewmate_worktree_dir "$base" "$wt" >/dev/null
  : > "$wt/state/task.meta"
  write_arm_fixture "$wt"
  run_autoarm "$wt" >/dev/null 2>&1 || true
  assert_absent "$wt/state/.claude-autoarm-inert" "a child worktree outside the hook's scope must stay byte-for-byte inert"

  afk_dir=$(make_primary_dir "$TMP_ROOT/inert-scope-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  write_arm_fixture "$afk_dir"
  run_autoarm "$afk_dir" >/dev/null 2>&1 || true
  assert_absent "$afk_dir/state/.claude-autoarm-inert" "an away home must stay byte-for-byte inert"

  idle_dir=$(make_primary_dir "$TMP_ROOT/inert-scope-idle")
  write_arm_fixture "$idle_dir"
  run_autoarm "$idle_dir" >/dev/null 2>&1 || true
  assert_absent "$idle_dir/state/.claude-autoarm-inert" "an idle home must stay byte-for-byte inert"
  pass "auto-arm: the silent-condition record is confined to the identity gates and preserves scope, away, and idle inertness"
}

test_live_foreign_owner_records_a_resolved_ancestry
test_collapsed_harness_ancestry_is_recorded_as_none
test_repeated_identical_inert_firings_accumulate_a_bounded_count
test_inert_record_is_retired_once_identity_is_proven
test_inert_record_never_written_outside_the_identity_gates
