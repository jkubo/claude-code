#!/usr/bin/env bash
# Rebase the jkubo fork of claude-code onto anthropics/claude-code.
#
#   ./scripts/sync-upstream.sh              # fetch + rebase (no push)
#   ./scripts/sync-upstream.sh --push       # also update origin/jkubo + origin/main
#   ./scripts/sync-upstream.sh --dry-run    # report only, change nothing
#
# `main` stays an exact fast-forward of upstream and must never carry fork
# delta. `jkubo` is upstream plus local plugins and this tooling. There is no
# build step: upstream ships no CLI source, so nothing here compiles. See
# FORK.md before assuming a commit in this tree changes the `claude` binary.
#
# Deliberately NOT modelled on grok-build's `git am --3way` fallback. That
# fallback earns its keep when the delta is one product patch that must survive
# an upstream refactor. Here the delta is whole plugin directories that upstream
# does not touch, so a conflict means something genuinely surprising happened
# and a human should look at it rather than have a script force it through.
#
# On conflict or a rejected push, both branches are put back to the SHAs this
# run started from. The exit path prints the fork SHA after that restore.
set -euo pipefail

# Replay checks out other commits over this file. Run from a private copy so
# bash does not keep reading a path git is replacing.
if [[ -z "${SYNC_UPSTREAM_REEXEC:-}" ]]; then
  SYNC_UPSTREAM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  SYNC_UPSTREAM_REEXEC_PATH="$(mktemp)"
  cp "$0" "$SYNC_UPSTREAM_REEXEC_PATH"
  chmod +x "$SYNC_UPSTREAM_REEXEC_PATH"
  export SYNC_UPSTREAM_REEXEC=1
  export SYNC_UPSTREAM_ROOT
  export SYNC_UPSTREAM_REEXEC_PATH
  exec bash "$SYNC_UPSTREAM_REEXEC_PATH" "$@" || {
    rm -f "$SYNC_UPSTREAM_REEXEC_PATH"
    exit 1
  }
fi

FORK_BRANCH="${FORK_BRANCH:-jkubo}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/anthropics/claude-code.git}"
ROOT="${SYNC_UPSTREAM_ROOT}"

DO_PUSH=0
DO_DRY=0
ALLOW_DIRTY=0
MUTATED=0
MAIN_EXISTED=0
MAIN_CREATED=0
MAIN_BEFORE=""
FORK_BEFORE=""
FORK_LEASE=""
START_BRANCH=""

log()  { printf 'sync-upstream: %s\n' "$*"; }
die()  { printf 'sync-upstream: ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
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

restore_branches() {
  [[ "$MUTATED" -eq 1 ]] || return 0
  git rebase --abort >/dev/null 2>&1 || true
  git merge --abort >/dev/null 2>&1 || true
  if [[ -n "$FORK_BEFORE" ]]; then
    git checkout --quiet --detach "$FORK_BEFORE" >/dev/null 2>&1 || true
    git branch -f "$FORK_BRANCH" "$FORK_BEFORE" >/dev/null 2>&1 || true
  fi
  if [[ "$MAIN_EXISTED" -eq 1 && -n "$MAIN_BEFORE" ]]; then
    git branch -f "$MIRROR_BRANCH" "$MAIN_BEFORE" >/dev/null 2>&1 || true
  elif [[ "$MAIN_CREATED" -eq 1 ]]; then
    git branch -D "$MIRROR_BRANCH" >/dev/null 2>&1 || true
  fi
  if [[ -n "$START_BRANCH" ]] && git show-ref --verify --quiet "refs/heads/$START_BRANCH"; then
    git checkout --quiet "$START_BRANCH" >/dev/null 2>&1 || true
  elif [[ -n "$FORK_BEFORE" ]]; then
    git checkout --quiet "$FORK_BRANCH" >/dev/null 2>&1 || true
  fi
  MUTATED=0
}

fail_rollback() {
  restore_branches
  die "$@"
}

emit_evidence() {
  local fork_sha="" upstream_sha="" main_sha="" changed="false"
  fork_sha="$(git rev-parse "refs/heads/$FORK_BRANCH" 2>/dev/null || true)"
  upstream_sha="$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || true)"
  if [[ -n "$fork_sha" && -n "$FORK_BEFORE" && "$fork_sha" != "$FORK_BEFORE" ]]; then
    changed="true"
  fi
  log "fork sha=${fork_sha:-unknown} changed=${changed}"
  if [[ -n "$upstream_sha" ]]; then
    log "upstream sha=${upstream_sha}"
  fi
  if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
    main_sha="$(git rev-parse "refs/heads/$MIRROR_BRANCH")"
    log "main sha=${main_sha}"
  else
    log "main sha=absent"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'changed=%s\n' "$changed" >>"$GITHUB_OUTPUT"
    printf 'sha=%s\n' "$fork_sha" >>"$GITHUB_OUTPUT"
    printf 'upstream=%s\n' "$upstream_sha" >>"$GITHUB_OUTPUT"
    printf 'main=%s\n' "${main_sha:-absent}" >>"$GITHUB_OUTPUT"
  fi
}

on_exit() {
  local rc=$?
  set +e
  if [[ "$rc" -ne 0 ]]; then
    restore_branches
  fi
  emit_evidence
  if [[ -n "${SYNC_UPSTREAM_REEXEC_PATH:-}" ]]; then
    rm -f "$SYNC_UPSTREAM_REEXEC_PATH"
  fi
  exit "$rc"
}
trap on_exit EXIT

require_token() {
  local value
  if [[ "$DO_PUSH" -ne 1 || "$DO_DRY" -eq 1 ]]; then
    return 0
  fi
  if [[ "${FORK_SYNC_TOKEN_REQUIRED:-}" != "1" ]]; then
    return 0
  fi
  value="${FORK_SYNC_TOKEN:-}"
  value="${value//[[:space:]]/}"
  if [[ -z "$value" ]]; then
    die "FORK_SYNC_TOKEN is absent. Refusing to push."
  fi
}

refuse_in_progress() {
  local git_dir
  git_dir="$(git rev-parse --absolute-git-dir)"
  if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
    die "rebase already in progress; refusing to abort it"
  fi
  if [[ -f "$git_dir/MERGE_HEAD" ]]; then
    die "merge already in progress; refusing to abort it"
  fi
  # An empty multi-commit cherry-pick leaves CHERRY_PICK_HEAD and sequencer
  # while `git status --porcelain` is empty. A paused revert leaves
  # REVERT_HEAD, sequencer, or both. Checkout and rebase clear the HEAD
  # files and orphan sequencer. These operations belong to the operator.
  if [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
    die "cherry-pick already in progress; refusing to abort it"
  fi
  if [[ -f "$git_dir/REVERT_HEAD" ]]; then
    die "revert already in progress; refusing to abort it"
  fi
  if [[ -d "$git_dir/sequencer" ]]; then
    die "sequencer already in progress; refusing to abort it"
  fi
}

update_mirror() {
  local upstream_sha main_sha
  upstream_sha="$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
  if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
    git checkout --quiet "$MIRROR_BRANCH"
  else
    if ! git show-ref --verify --quiet "refs/remotes/$ORIGIN_REMOTE/$MIRROR_BRANCH"; then
      log "origin/$MIRROR_BRANCH does not exist"
      return 1
    fi
    # CI checks out only jkubo. After both remotes are fetched, a plain
    # `git checkout main` is DWIM-ambiguous. Create it from origin/main,
    # then fast-forward. Do not reset a main that already exists.
    git checkout --quiet -B "$MIRROR_BRANCH" "$ORIGIN_REMOTE/$MIRROR_BRANCH"
    MAIN_CREATED=1
  fi
  main_sha="$(git rev-parse HEAD)"
  if [[ "$main_sha" == "$upstream_sha" ]]; then
    return 0
  fi
  # `git merge --ff-only` succeeds when main is already ahead of upstream.
  # That would keep fork delta on the mirror. Require a real fast-forward
  # onto the upstream object, which lands on that exact commit.
  if ! git merge-base --is-ancestor "$main_sha" "$upstream_sha"; then
    log "$MIRROR_BRANCH is ${main_sha} and upstream is ${upstream_sha}"
    return 1
  fi
  git merge --ff-only --quiet "$upstream_sha"
}

cd "$ROOT"
[[ -d .git ]] || die "not a git repo: $ROOT"

# Before any checkout. --allow-dirty and --dry-run do not bypass this, and
# the script does not abort an operation it did not start.
refuse_in_progress

# A dirty tree plus a rebase is how you lose work that was never committed.
# Exempt --dry-run: it mutates nothing, so refusing there would make the one
# command that is always safe the one command you cannot run when you most
# want it, which is mid-change.
if [[ "$DO_DRY" -eq 0 && "$ALLOW_DIRTY" -eq 0 ]] && [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty. Commit, stash, or pass --allow-dirty."
fi

START_BRANCH="$(git symbolic-ref --short -q HEAD || echo "$FORK_BRANCH")"
git show-ref --verify --quiet "refs/heads/$FORK_BRANCH" \
  || die "local branch $FORK_BRANCH does not exist"
FORK_BEFORE="$(git rev-parse "refs/heads/$FORK_BRANCH")"
if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
  MAIN_EXISTED=1
  MAIN_BEFORE="$(git rev-parse "refs/heads/$MIRROR_BRANCH")"
fi

# Absent credential fails before fetch, rebase, or push. Local --push uses the
# operator's own credentials and does not set FORK_SYNC_TOKEN_REQUIRED.
require_token

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  if [[ "$DO_DRY" -eq 1 ]]; then
    log "[dry-run] would add remote $UPSTREAM_REMOTE -> $UPSTREAM_URL"
  else
    log "adding remote $UPSTREAM_REMOTE -> $UPSTREAM_URL"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  fi
fi

if [[ "$DO_DRY" -eq 1 ]]; then
  behind="$(git rev-list --count "$FORK_BRANCH..$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo '?')"
  ahead="$(git rev-list --count "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH..$FORK_BRANCH" 2>/dev/null || echo '?')"
  log "[dry-run] $FORK_BRANCH is $behind behind and $ahead ahead of $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  exit 0
fi

log "fetching $UPSTREAM_REMOTE and $ORIGIN_REMOTE"
git fetch --quiet "$UPSTREAM_REMOTE"
git fetch --quiet "$ORIGIN_REMOTE"

if git show-ref --verify --quiet "refs/remotes/$ORIGIN_REMOTE/$FORK_BRANCH"; then
  FORK_LEASE="$(git rev-parse "refs/remotes/$ORIGIN_REMOTE/$FORK_BRANCH")"
fi

# The lease is the fork tip this fetch just observed. It only pins the later
# atomic push. It is not permission to rebase. The fetched origin tip must
# already be an ancestor of the local fork tip recorded before the fetch.
# The same commit, and local commits the remote does not have yet, continue.
# A remote commit this local tip does not contain (the remote moved ahead
# before fetch, or the histories diverged) stops here, before MUTATED and
# before any checkout, rebase, or main update. Rebasing the older local tip
# and pushing it with a lease of that new remote SHA would delete the remote
# commit. There is no flag that picks a side.
if [[ -n "$FORK_LEASE" ]]; then
  if ! git merge-base --is-ancestor "$FORK_LEASE" "$FORK_BEFORE"; then
    die "origin/$FORK_BRANCH ${FORK_LEASE} is not an ancestor of local $FORK_BRANCH ${FORK_BEFORE}. Refusing to rebase or push. See FORK.md."
  fi
fi

# Rebase jkubo before moving main. A conflict then has nothing to undo on main.
MUTATED=1
log "rebasing $FORK_BRANCH onto $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git checkout --quiet "$FORK_BRANCH"
if ! git rebase --quiet "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  git rebase --abort >/dev/null 2>&1 || true
  fail_rollback "rebase conflicted. $FORK_BRANCH left untouched at ${FORK_BEFORE}."
fi

log "fast forwarding $MIRROR_BRANCH to $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
if ! update_mirror; then
  fail_rollback "$MIRROR_BRANCH is not an exact fast-forward of upstream. Refusing to push."
fi

if [[ "$DO_PUSH" -eq 1 ]]; then
  require_token
  if [[ -z "$FORK_LEASE" ]]; then
    fail_rollback "origin/$FORK_BRANCH is absent. Refusing to push without a fetch-time lease."
  fi
  fork_now="$(git rev-parse "refs/heads/$FORK_BRANCH")"
  main_now="$(git rev-parse "refs/heads/$MIRROR_BRANCH")"
  log "pushing $MIRROR_BRANCH and $FORK_BRANCH"
  # One atomic push. main has no force flag, so a non-fast-forward is rejected.
  # jkubo's lease is the SHA observed at fetch, not the remote-tracking ref at
  # push time. --force is never used.
  if ! git push --atomic \
      --force-with-lease="${FORK_BRANCH}:${FORK_LEASE}" \
      "$ORIGIN_REMOTE" \
      "${main_now}:refs/heads/${MIRROR_BRANCH}" \
      "${fork_now}:refs/heads/${FORK_BRANCH}"; then
    fail_rollback "push rejected. $MIRROR_BRANCH and $FORK_BRANCH restored to the SHAs from the start of this run."
  fi
  log "pushed"
else
  log "not pushed (pass --push)"
fi

if [[ -n "$START_BRANCH" ]] && git show-ref --verify --quiet "refs/heads/$START_BRANCH"; then
  git checkout --quiet "$START_BRANCH"
else
  git checkout --quiet "$FORK_BRANCH"
fi
log "done"
