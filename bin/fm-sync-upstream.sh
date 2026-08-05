#!/usr/bin/env bash
# Fetch firstmate's upstream (kunchenguid/firstmate) and fast-forward the
# local default branch to it, then push the result to origin (the captain's
# own fork) - keeping the captain's fork current with upstream.
#
# This is NOT what /updatefirstmate (fm-update.sh) does: that script only
# fast-forwards the LOCAL checkout from origin. This script pulls from
# upstream first, fast-forward-merges it into the local default branch, and
# then pushes that advance to origin - a fetch-upstream/merge/push chain,
# not an origin-only sync.
#
# Reuses fm-ff-lib.sh's fast-forward-only primitives (`ff_target` with a raw
# ref as its base_mode, rather than the literal "origin" - fm-ff-lib.sh's
# "origin" mode is hardcoded to fetch the "origin" remote, so a different
# remote's ref is passed as an already-fetched commit-ish instead, the same
# mode fm-spawn.sh's local-HEAD secondmate sync already uses) for the common
# case where the local default branch is a pure ancestor of upstream. Same
# guard philosophy as fm-update.sh for that path: never force, never stash;
# advance only on a clean fast-forward.
#
# A captain's fork commonly carries its own commits on top of upstream (a
# local .gitignore tweak, a past merge of upstream, this very script) - that
# makes a pure fast-forward permanently impossible even though there is
# nothing wrong, so fast-forward-only would report "diverged" forever. When
# the local branch is genuinely ahead of upstream as well as behind it, this
# script instead performs one real `git merge` of upstream into the local
# default branch (a normal merge commit, never a rebase, never --force) and
# pushes the result to origin with a plain `git push`. A merge that cannot
# apply cleanly is aborted immediately (`git merge --abort`), leaving the
# working tree exactly as it was, and reported rather than resolved.
#
# --check fetches upstream (and origin, to know both states) and reports
# ahead/behind counts without merging or pushing - always safe to run, and
# safe to run automatically. Without --check, the local branch is advanced
# by fast-forward or, when it also carries its own commits, by a real merge,
# and - only if it actually advanced - pushed to origin with a plain
# `git push` (never --force), so a push that isn't itself a clean
# fast-forward on the remote side fails loudly rather than clobbering it.
#
# Output is one parseable summary line, matching fm-crew-state.sh's
# "key: value SEP key: value SEP ..." convention (SEP = middle-dot):
#   status: already-current|would-update|would-merge|updated|merged|diverged|merge-conflict|dirty|skipped|push-failed SEP ahead: N SEP behind: N SEP <detail>
#
# Usage: fm-sync-upstream.sh [--check] [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-sync-upstream.sh [--check] [--help]" >&2; }

check_only=no
if [ "${1:-}" = "--check" ]; then
  check_only=yes
  shift
fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

SEP=' · '
report() {
  echo "status: $1$SEP""ahead: $2$SEP""behind: $3$SEP""$4"
}

if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
  report skipped 0 0 "no upstream remote configured"
  exit 0
fi

default=$(default_branch "$FM_ROOT") || {
  report skipped 0 0 "cannot determine default branch"
  exit 0
}

if ! git -C "$FM_ROOT" fetch upstream --prune --quiet 2>/dev/null; then
  report skipped 0 0 "fetch upstream failed"
  exit 0
fi
# Best-effort: also refresh origin so a push below (apply mode) starts from
# a current view of it. A failure here is not fatal to the upstream sync.
fetch_once "$FM_ROOT" >/dev/null 2>&1 || true

base="upstream/$default"
if ! git -C "$FM_ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  report skipped 0 0 "$base does not exist after fetch"
  exit 0
fi

counts=$(git -C "$FM_ROOT" rev-list --left-right --count "HEAD...$base")
ahead=$(printf '%s' "$counts" | awk '{print $1}')
behind=$(printf '%s' "$counts" | awk '{print $2}')

if [ "$check_only" = yes ]; then
  if [ "$behind" -eq 0 ]; then
    report already-current "$ahead" "$behind" "$default is level with $base"
  elif [ "$ahead" -gt 0 ]; then
    report would-merge "$ahead" "$behind" "$default carries $ahead commit(s) of its own and is $behind behind $base; run without --check to merge $base in and push to origin"
  else
    report would-update "$ahead" "$behind" "$behind commit(s) behind $base; run without --check to fast-forward $default and push to origin"
  fi
  exit 0
fi

if [ "$ahead" -eq 0 ]; then
  ff_target "$FM_ROOT" "firstmate" "$base" no no
  case "$FF_STATUS" in
    current)
      report already-current "$ahead" "$behind" "$default is level with $base"
      exit 0
      ;;
    skipped)
      report skipped "$ahead" "$behind" "fast-forward from $base was skipped (see reason above)"
      exit 0
      ;;
  esac

  # FF_STATUS = updated: the local default branch advanced - push it to
  # origin, fast-forward only (a plain `git push`, never --force).
  if push_out=$(git -C "$FM_ROOT" push origin "$default" 2>&1); then
    report updated 0 0 "fast-forwarded $default from $base and pushed to origin"
  else
    report push-failed 0 0 "fast-forwarded $default from $base locally but push to origin failed: $(first_line "$push_out")"
    exit 1
  fi
  exit 0
fi

# The local default branch carries its own commits on top of upstream (ahead >
# 0), so a fast-forward can never apply - merge upstream in instead, exactly
# like a manual `git merge upstream/<default>` on the same branch: a real
# merge commit, never --force, never rebase. Refuse up front on anything that
# would make an automatic merge unsafe to attempt.
cur_branch=$(git -C "$FM_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$cur_branch" != "$default" ]; then
  report skipped "$ahead" "$behind" "on $cur_branch, expected $default"
  exit 0
fi
if [ -n "$(dirty_status "$FM_ROOT")" ]; then
  report dirty "$ahead" "$behind" "working tree is dirty - resolve manually before syncing"
  exit 0
fi
if [ "$behind" -eq 0 ]; then
  report already-current "$ahead" "$behind" "$default already contains every commit on $base"
  exit 0
fi

before=$(git -C "$FM_ROOT" rev-parse --short HEAD)
if ! merge_out=$(git -C "$FM_ROOT" merge --no-edit "$base" 2>&1); then
  git -C "$FM_ROOT" merge --abort >/dev/null 2>&1 || true
  report merge-conflict "$ahead" "$behind" "merging $base into $default did not apply cleanly, aborted: $(first_line "$merge_out")"
  exit 1
fi
after=$(git -C "$FM_ROOT" rev-parse --short HEAD)

if push_out=$(git -C "$FM_ROOT" push origin "$default" 2>&1); then
  report merged 0 0 "merged $base into $default ($before..$after) and pushed to origin"
else
  report push-failed 0 0 "merged $base into $default locally ($before..$after) but push to origin failed: $(first_line "$push_out")"
  exit 1
fi
