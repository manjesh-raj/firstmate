#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the assumption the Stop-owned
# auto-arm's identity gate rests on (bin/fm-session-lock-lib.sh).
#
# fm_session_lock_owned_by_self proves a Stop hook belongs to the session
# holding state/.lock by walking the hook's own process ancestry for that pid.
# That is only correct while Claude Code keeps an asyncRewake hook inside the
# session's own contiguous harness process tree. Nothing in this repo controls
# that: it is the vendor's spawning and parenting behavior, so it has to be
# proven against the real installed binary rather than a stub that can only
# confirm the assumption already written into it.
#
# The 2026-09-15 frozen-ledger episode made this concrete. Its best-supported
# hypothesis was that asyncRewake detachment had started breaking that chain,
# which would make the identity gate reject the very session that owns the home
# and go silently inert. This guard is what says whether that is true on the
# installed version.
#
# It registers the real ancestry predicates as both a SessionStart and an
# asyncRewake Stop hook in an isolated project, exactly as the tracked
# registration does, and asserts the Stop hook resolves the same session pid the
# SessionStart hook recorded as the lock owner. The project and FM_HOME are
# isolated; Claude keeps using its existing managed authentication. No live
# fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $CLAUDE_PROJECT_DIR expands inside the harness, not this shell
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-asyncrewake-ancestry-live-e2e.$$"
PROJECT="$LAB/project"
OUT="$LAB/out"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude" "$OUT"

# The probe is the real predicate pair, nothing reimplemented: SessionStart
# writes the lock exactly as bin/fm-lock.sh does, and the Stop hook answers
# exactly the question bin/fm-claude-stop-autoarm.sh asks at its identity gate.
cat > "$PROJECT/probe.sh" <<PROBE
#!/usr/bin/env bash
set -u
cat >/dev/null 2>&1 || true
. "$ROOT/bin/fm-session-lock-lib.sh"
OUT="$OUT"
if [ "\$1" = start ]; then
  fm_harness_ancestry_pid > "\$OUT/.lock" 2>/dev/null || true
  exit 0
fi
{
  printf 'ancestry=%s\n' "\$(fm_harness_ancestry_pids 2>/dev/null | tr '\n' ',' | sed 's/,\$//')"
  if fm_session_lock_owned_by_self "\$OUT"; then
    printf 'owned=yes\n'
  else
    printf 'owned=no\n'
  fi
  printf 'parent=%s\n' "\$(ps -o comm= -p "\$(ps -o ppid= -p \$\$ | tr -d ' ')" 2>/dev/null)"
} > "\$OUT/stop.txt" 2>&1
exit 0
PROBE
chmod +x "$PROJECT/probe.sh"

cat > "$PROJECT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/probe.sh start" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/probe.sh stop", "asyncRewake": true, "timeout": 120 } ] }
    ]
  }
}
JSON

(
  cd "$PROJECT" || exit 1
  CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p 'Reply with exactly DONE and stop. Use no tools.' \
      --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' --effort low
) > "$LAB/claude.out" 2>&1 || fail "Claude asyncRewake ancestry session failed: $(tail -20 "$LAB/claude.out")"

# The async hook is detached by definition, so it can still be running when the
# session exits. Wait for its record rather than racing it.
waited=0
until [ -s "$OUT/stop.txt" ] || [ "$waited" -ge 60 ]; do
  sleep 1
  waited=$((waited + 1))
done

LOCK=$(cat "$OUT/.lock" 2>/dev/null || true)
[ -n "$LOCK" ] \
  || fail "Claude $CLAUDE_VERSION: SessionStart hook resolved no harness ancestry, so this home could never take its session lock"
[ -s "$OUT/stop.txt" ] \
  || fail "Claude $CLAUDE_VERSION: the asyncRewake Stop hook never produced a record - it did not fire, or did not survive session exit"

ANCESTRY=$(sed -n 's/^ancestry=//p' "$OUT/stop.txt")
OWNED=$(sed -n 's/^owned=//p' "$OUT/stop.txt")
PARENT=$(sed -n 's/^parent=//p' "$OUT/stop.txt")

[ -n "$ANCESTRY" ] \
  || fail "Claude $CLAUDE_VERSION: the asyncRewake Stop hook resolved NO harness ancestry (parent=$PARENT) - detachment has broken the contiguous chain the auto-arm identity gate depends on"
[ "$OWNED" = yes ] \
  || fail "Claude $CLAUDE_VERSION: the asyncRewake Stop hook did not recognize the session holding the lock (lock=$LOCK ancestry=$ANCESTRY parent=$PARENT) - the auto-arm would go silently inert on every Stop"

printf 'ok - Claude %s keeps an asyncRewake Stop hook inside the lock-owning session ancestry (lock=%s ancestry=%s parent=%s)\n' \
  "$CLAUDE_VERSION" "$LOCK" "$ANCESTRY" "$PARENT"
