#!/usr/bin/env bash
# Rebase the jkubo fork of claude-code onto anthropics/claude-code.
#
#   ./scripts/sync-upstream.sh              # fetch + rebase (no push)
#   ./scripts/sync-upstream.sh --push       # also update origin/jkubo + origin/main
#   ./scripts/sync-upstream.sh --dry-run    # report only, change nothing
#
# `main` stays a fast forward mirror of upstream and must never carry fork
# delta. `jkubo` is upstream plus local plugins and this tooling. There is no
# build step: upstream ships no CLI source, so nothing here compiles. See
# FORK.md before assuming a commit in this tree changes the `claude` binary.
#
# Deliberately NOT modelled on grok-build's `git am --3way` fallback. That
# fallback earns its keep when the delta is one product patch that must survive
# an upstream refactor. Here the delta is whole plugin directories that upstream
# does not touch, so a conflict means something genuinely surprising happened
# and a human should look at it rather than have a script force it through.
set -euo pipefail

FORK_BRANCH="${FORK_BRANCH:-jkubo}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/anthropics/claude-code.git}"

DO_PUSH=0
DO_DRY=0
ALLOW_DIRTY=0

log()  { printf 'sync-upstream: %s\n' "$*"; }
die()  { printf 'sync-upstream: ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if (( DO_DRY )); then printf 'sync-upstream: [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  echo "Flags: --push --dry-run --allow-dirty"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)        DO_PUSH=1 ;;
    --dry-run)     DO_DRY=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown flag: $1" ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ -d .git ]] || die "not a git repo: $ROOT"

# A dirty tree plus a rebase is how you lose work that was never committed.
# Exempt --dry-run: it mutates nothing, so refusing there would make the one
# command that is always safe the one command you cannot run when you most
# want it, which is mid-change.
if (( ! DO_DRY )) && (( ! ALLOW_DIRTY )) && [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty. Commit, stash, or pass --allow-dirty."
fi

# Adding the remote is idempotent so a fresh clone needs no manual setup.
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  log "adding remote $UPSTREAM_REMOTE -> $UPSTREAM_URL"
  run git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

START_BRANCH="$(git symbolic-ref --short -q HEAD || echo "$FORK_BRANCH")"

log "fetching $UPSTREAM_REMOTE and $ORIGIN_REMOTE"
run git fetch --quiet "$UPSTREAM_REMOTE"
run git fetch --quiet "$ORIGIN_REMOTE"

if (( DO_DRY )); then
  behind=$(git rev-list --count "$FORK_BRANCH..$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo '?')
  ahead=$(git rev-list --count "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH..$FORK_BRANCH" 2>/dev/null || echo '?')
  log "[dry-run] $FORK_BRANCH is $behind behind and $ahead ahead of $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  exit 0
fi

# 1. main is a pure mirror. --ff-only is the assertion that it never drifted;
#    if someone committed to main, this fails loudly instead of merging.
log "fast forwarding $MIRROR_BRANCH to $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git checkout --quiet "$MIRROR_BRANCH"
if ! git merge --ff-only --quiet "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  git checkout --quiet "$START_BRANCH" || true
  die "$MIRROR_BRANCH is not a fast forward of upstream. It carries fork delta it should not have."
fi

# 2. Replay the fork commits. On conflict, abort all the way back rather than
#    leaving a half finished rebase for the next person to discover.
log "rebasing $FORK_BRANCH onto $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git checkout --quiet "$FORK_BRANCH"
BEFORE="$(git rev-parse HEAD)"
if ! git rebase --quiet "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  git rebase --abort || true
  git checkout --quiet "$START_BRANCH" || true
  die "rebase conflicted. $FORK_BRANCH left untouched at ${BEFORE:0:12}. Resolve by hand, then re-run."
fi
AFTER="$(git rev-parse HEAD)"

if [[ "$BEFORE" == "$AFTER" ]]; then
  log "$FORK_BRANCH already current (${AFTER:0:12})"
else
  log "$FORK_BRANCH ${BEFORE:0:12} -> ${AFTER:0:12}"
fi

if (( DO_PUSH )); then
  # --force-with-lease, never --force: a rebase rewrites history, but if origin
  # moved since our fetch that is someone else's work and the push must fail.
  log "pushing $MIRROR_BRANCH and $FORK_BRANCH"
  git push --quiet "$ORIGIN_REMOTE" "$MIRROR_BRANCH"
  git push --quiet --force-with-lease "$ORIGIN_REMOTE" "$FORK_BRANCH"
  log "pushed"
else
  log "not pushed (pass --push)"
fi

git checkout --quiet "$START_BRANCH" || true
log "done"
