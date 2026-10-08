#!/usr/bin/env bash
# Exercise scripts/sync-upstream.sh against disposable local Git remotes.
# The fixture runs a byte copy of this repo's script. Pushes stay inside the
# scratch remotes and go through a normal pre-push hook.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_SYNC="$ROOT/scripts/sync-upstream.sh"
WF="$ROOT/.github/workflows/sync-upstream.yml"
UPSTREAM_PIN="79babc372d64101f981bd2b52c3dbe588596dc56"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -n "${SYNC_LOG:-}" && -f "$SYNC_LOG" ]]; then
    printf '%s\n' '--- sync.out ---' >&2
    cat "$SYNC_LOG" >&2
  fi
  exit 1
}
say() { printf 'ok: %s\n' "$*"; }

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s\n got: [%s]\n want: [%s]\n' "$3" "$1" "$2" >&2
    if [[ -n "${SYNC_LOG:-}" && -f "$SYNC_LOG" ]]; then
      printf '%s\n' '--- sync.out ---' >&2
      cat "$SYNC_LOG" >&2
    fi
    exit 1
  fi
}

assert_rc() {
  if [[ "$SYNC_RC" -ne "$1" ]]; then
    fail "$2 (rc=$SYNC_RC, want $1)"
  fi
}

[[ -f "$REAL_SYNC" ]] || fail "missing $REAL_SYNC"
[[ -f "$WF" ]] || fail "missing $WF"
[[ -x "$REAL_SYNC" ]] || fail "sync script is not executable"

if grep -F -- '--no-verify' "$REAL_SYNC" "$WF"; then
  fail "delivered sync path bypasses hooks"
fi
grep -F 'token: ${{ secrets.FORK_SYNC_TOKEN }}' "$WF" >/dev/null \
  || fail "workflow checkout does not use FORK_SYNC_TOKEN"
grep -F 'contents: read' "$WF" >/dev/null \
  || fail "workflow does not keep GITHUB_TOKEN at contents: read"
if grep -F 'contents: write' "$WF"; then
  fail "workflow grants contents: write to GITHUB_TOKEN"
fi
require_line="$(grep -n 'FORK_SYNC_TOKEN is absent' "$WF" | head -n1 | cut -d: -f1)"
token_line="$(grep -n 'token: ${{ secrets.FORK_SYNC_TOKEN }}' "$WF" | head -n1 | cut -d: -f1)"
push_line="$(grep -n 'sync-upstream.sh --push' "$WF" | head -n1 | cut -d: -f1)"
[[ -n "$require_line" && -n "$token_line" && -n "$push_line" ]] \
  || fail "workflow is missing the token check, the checkout token, or the push"
[[ "$require_line" -lt "$token_line" && "$token_line" -lt "$push_line" ]] \
  || fail "token check must run before checkout and before push"
grep -F 'FORK_SYNC_TOKEN_REQUIRED' "$WF" >/dev/null \
  || fail "workflow does not require the token inside the sync step"
for inherited in auto-close-duplicates.yml lock-closed-issues.yml sweep.yml; do
  [[ -f "$ROOT/.github/workflows/$inherited" ]] \
    || fail "inherited workflow missing: $inherited"
  git -C "$ROOT" grep -F --quiet "$inherited" HEAD -- FORK.md \
    || fail "FORK.md no longer documents $inherited"
done
if git -C "$ROOT" grep -F --quiet $'\u2014' HEAD -- FORK.md scripts/sync-upstream.sh scripts/test-sync-upstream.sh .github/workflows/sync-upstream.yml; then
  fail "delivered files contain an em dash"
fi

git -C "$ROOT" cat-file -e "${UPSTREAM_PIN}^{commit}" \
  || fail "upstream pin ${UPSTREAM_PIN} is not in this clone"
git -C "$ROOT" merge-base --is-ancestor "$UPSTREAM_PIN" HEAD \
  || fail "HEAD does not contain upstream ${UPSTREAM_PIN}"
mapfile -t delivered_paths < <(git -C "$ROOT" diff --name-only "$UPSTREAM_PIN" HEAD | sort)
expected_paths=(
  .github/workflows/sync-upstream.yml
  FORK.md
  scripts/sync-upstream.sh
  scripts/test-sync-upstream.sh
)
assert_eq "$(printf '%s\n' "${delivered_paths[@]}")" "$(printf '%s\n' "${expected_paths[@]}")" \
  "fork delta paths versus ${UPSTREAM_PIN}"
mapfile -t candidate_idents < <(git -C "$ROOT" log "${UPSTREAM_PIN}..HEAD" --format='%an <%ae>%n%cn <%ce>')
[[ ${#candidate_idents[@]} -gt 0 ]] || fail "no commits after upstream"
for ident in "${candidate_idents[@]}"; do
  [[ "$ident" == "Jay Kubo <6161465+jkubo@users.noreply.github.com>" ]] \
    || fail "candidate author or committer is not the public alias: $ident"
done
if git -C "$ROOT" log "${UPSTREAM_PIN}..HEAD" --format='%B' | grep -F 'Co-Authored-By:'; then
  fail "candidate history contains a Co-Authored-By trailer"
fi
if git -C "$ROOT" log "${UPSTREAM_PIN}..HEAD" --format='%B' | grep -F $'\u2014'; then
  fail "candidate history contains an em dash"
fi
delivered_head="$(git -C "$ROOT" rev-parse HEAD)"
delivered_blob="$(git -C "$ROOT" rev-parse "HEAD:scripts/sync-upstream.sh")"
worktree_blob="$(git -C "$ROOT" hash-object "$REAL_SYNC")"
assert_eq "$delivered_blob" "$worktree_blob" "committed sync script matches the worktree"
say "exact delivered patched head ${delivered_head}"

SANDBOXES=()
CURRENT_WORK=""
SYNC_RC=0
cleanup() {
  local d
  for d in "${SANDBOXES[@]+"${SANDBOXES[@]}"}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

SB_ROOT=""
new_sandbox() {
  SB_ROOT="$(mktemp -d -t claude-sync-XXXX)"
  SANDBOXES+=("$SB_ROOT")
  git init --bare -q "$SB_ROOT/origin.git"
  git init --bare -q "$SB_ROOT/upstream.git"
  git init -q -b main "$SB_ROOT/work"
  git -C "$SB_ROOT/work" config user.name "Jay Kubo"
  git -C "$SB_ROOT/work" config user.email "6161465+jkubo@users.noreply.github.com"
  git -C "$SB_ROOT/work" config commit.gpgsign false
  git -C "$SB_ROOT/work" config core.hooksPath "$SB_ROOT/work/.git/hooks"
  git -C "$SB_ROOT/work" remote add origin "$SB_ROOT/origin.git"
  git -C "$SB_ROOT/work" remote add upstream "$SB_ROOT/upstream.git"
  mkdir -p "$SB_ROOT/work/.git/hooks"
  CURRENT_WORK="$SB_ROOT/work"
}

install_hook() {
  local work="$1"
  cat >"$work/.git/hooks/pre-push" <<'EOF'
#!/bin/bash
if [[ -n "${HOOK_MARK:-}" ]]; then
  printf 'hooked\n' >>"$HOOK_MARK"
fi
if [[ "${SPOIL_JKUBO:-}" == "1" && -n "${ORIGIN_BARE:-}" && -n "${SPOIL_SHA:-}" ]]; then
  git --git-dir="$ORIGIN_BARE" update-ref refs/heads/jkubo "$SPOIL_SHA"
  git update-ref refs/remotes/origin/jkubo "$SPOIL_SHA"
  printf 'spoiled\n' >>"${HOOK_MARK:-/dev/null}"
fi
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-push"
}

commit_tree() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

install_sync_bytes() {
  local work="$1"
  mkdir -p "$work/scripts" "$work/.github/workflows"
  cp "$REAL_SYNC" "$work/scripts/sync-upstream.sh"
  cp "$WF" "$work/.github/workflows/sync-upstream.yml"
  chmod +x "$work/scripts/sync-upstream.sh"
  cmp -s "$REAL_SYNC" "$work/scripts/sync-upstream.sh" \
    || fail "fixture script is not the real sync script"
}

# base commit on main, one fork commit on jkubo, both published.
# Leaves the worktree on jkubo at the fork tip. Local main matches base.
seed_fork() {
  local work="$1"
  mkdir -p "$work/.github/workflows"
  printf 'base\n' >"$work/README.md"
  printf 'kept-v1\n' >"$work/.github/workflows/kept.yml"
  commit_tree "$work" "base"
  SEED_BASE="$(git -C "$work" rev-parse HEAD)"
  install_sync_bytes "$work"
  printf 'fork\n' >"$work/FORK.md"
  commit_tree "$work" "fork tooling"
  SEED_TIP="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" branch jkubo "$SEED_TIP"
  git -C "$work" checkout -q jkubo
  git -C "$work" branch -f main "$SEED_BASE"
  git -C "$work" push -q origin "${SEED_BASE}:refs/heads/main"
  git -C "$work" push -q origin "${SEED_TIP}:refs/heads/jkubo"
  git -C "$work" push -q upstream "${SEED_BASE}:refs/heads/main"
  git -C "$work" fetch -q origin
  git -C "$work" fetch -q upstream
}

advance_upstream() {
  local work="$1"
  shift
  git -C "$work" checkout -q -B upscratch upstream/main
  ( cd "$work" && "$@" )
  commit_tree "$work" "upstream move"
  UP_SHA="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  git -C "$work" branch -D upscratch >/dev/null
}

run_sync() {
  local work="$1"
  shift
  cmp -s "$REAL_SYNC" "$work/scripts/sync-upstream.sh" \
    || fail "refusing to run a script that is not the real sync script"
  EVIDENCE="$SB_ROOT/github-output"
  HOOK_LOG="$SB_ROOT/hook-mark"
  SYNC_LOG="$SB_ROOT/sync.out"
  : >"$EVIDENCE"
  : >"$HOOK_LOG"
  local cmd=(env -u FORK_SYNC_TOKEN
    "HOOK_MARK=$HOOK_LOG"
    "GITHUB_OUTPUT=$EVIDENCE"
    "ORIGIN_BARE=$SB_ROOT/origin.git"
    "FORK_SYNC_TOKEN_REQUIRED=${FORK_SYNC_TOKEN_REQUIRED:-}"
  )
  if [[ -n "${SPOIL_JKUBO:-}" ]]; then
    cmd+=("SPOIL_JKUBO=$SPOIL_JKUBO" "SPOIL_SHA=${SPOIL_SHA:-}")
  fi
  if [[ -n "${PASS_TOKEN:-}" ]]; then
    cmd+=("FORK_SYNC_TOKEN=$PASS_TOKEN")
  fi
  set +e
  "${cmd[@]}" "$work/scripts/sync-upstream.sh" "$@" >"$SYNC_LOG" 2>&1
  SYNC_RC=$?
  set -e
  unset SPOIL_JKUBO SPOIL_SHA PASS_TOKEN FORK_SYNC_TOKEN_REQUIRED || true
}

out_value() {
  local key="$1" file="$2" line
  line="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  printf '%s' "${line#*=}"
}

ref_sha() {
  git --git-dir="$1" rev-parse "refs/heads/$2"
}

no_rebase_left() {
  local work="$1" git_dir
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  [[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]] \
    || fail "rebase state left behind in $git_dir"
}

# Exact refs, index, worktree, and in-progress operation snapshot.
# Remote-tracking refs are omitted: a refusing run is allowed to fetch.
capture_state() {
  local work="$1" dest="$2" git_dir name dir f hash
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  {
    echo "HEAD=$(git -C "$work" rev-parse HEAD)"
    echo "symref=$(git -C "$work" symbolic-ref -q HEAD || echo DETACHED)"
    echo "heads<<"
    git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort
    echo ">>"
    echo "origin-heads<<"
    git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort
    echo ">>"
    echo "ls-files-s<<"
    git -C "$work" ls-files -s
    echo ">>"
    echo "ls-files-u<<"
    git -C "$work" ls-files -u
    echo ">>"
    echo "porcelain<<"
    git -C "$work" status --porcelain=v1 --untracked-files=all
    echo ">>"
    echo "diff-cached<<"
    git -C "$work" diff --cached --binary
    echo ">>"
    echo "diff<<"
    git -C "$work" diff --binary
    echo ">>"
    echo "untracked<<"
    git -C "$work" ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do
          hash="$(sha256sum "$work/$f" | awk '{print $1}')"
          printf '%s %s\n' "$hash" "$f"
        done
    echo ">>"
    for name in CHERRY_PICK_HEAD REVERT_HEAD MERGE_HEAD MERGE_MSG AUTO_MERGE; do
      if [[ -f "$git_dir/$name" ]]; then
        hash="$(sha256sum "$git_dir/$name" | awk '{print $1}')"
        printf 'marker %s %s\n' "$name" "$hash"
      else
        echo "marker $name absent"
      fi
    done
    for dir in sequencer rebase-merge rebase-apply; do
      if [[ -d "$git_dir/$dir" ]]; then
        echo "dir $dir present"
        (
          cd "$git_dir/$dir" && find . -type f -print | sort | while read -r f; do
            hash="$(sha256sum "$f" | awk '{print $1}')"
            printf 'op %s %s %s\n' "$dir" "$f" "$hash"
          done
        )
      else
        echo "dir $dir absent"
      fi
    done
  } >"$dest"
}

assert_state_unchanged() {
  local work="$1" before="$2" after="$SB_ROOT/state-after"
  capture_state "$work" "$after"
  if ! cmp -s "$before" "$after"; then
    diff -u "$before" "$after" >&2 || true
    fail "refs, index, worktree, or operation state changed"
  fi
}

# Commit on a second clone and push to origin's fork branch. The fixture
# clone is not fetched, so its remote-tracking ref stays stale on purpose.
publish_side_fork() {
  local filename="$1" content="$2" message="$3" side="$SB_ROOT/side"
  rm -rf "$side"
  git clone -q -b jkubo "$SB_ROOT/origin.git" "$side"
  git -C "$side" config user.name "Jay Kubo"
  git -C "$side" config user.email "6161465+jkubo@users.noreply.github.com"
  git -C "$side" config commit.gpgsign false
  printf '%s\n' "$content" >"$side/$filename"
  git -C "$side" add -- "$filename"
  git -C "$side" commit -q -m "$message"
  SIDE_TIP="$(git -C "$side" rev-parse HEAD)"
  git -C "$side" push -q origin "HEAD:refs/heads/jkubo"
}

scenario_success() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  # CI shape: checkout is jkubo and local main does not exist yet.
  git -C "$work" branch -D main >/dev/null
  install_hook "$work"
  local origin_main_before origin_jkubo_before
  origin_main_before="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_jkubo_before="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  run_sync "$work" --push
  assert_rc 0 "success sync"
  assert_eq "$(git -C "$work" rev-parse main)" "$UP_SHA" "local main is the upstream object"
  assert_eq "$(git -C "$work" rev-parse upstream/main)" "$UP_SHA" "upstream/main"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "origin/main is the upstream object"
  [[ "$(ref_sha "$SB_ROOT/origin.git" jkubo)" != "$origin_jkubo_before" ]] \
    || fail "jkubo did not move"
  assert_eq "$(git -C "$work" rev-parse jkubo^)" "$UP_SHA" "rebased fork parent is upstream"
  assert_eq "$(git -C "$work" rev-parse origin/jkubo)" "$(git -C "$work" rev-parse jkubo)" \
    "origin/jkubo matches local jkubo"
  assert_eq "$(git -C "$work" show jkubo:README.md)" "upstream-moved" "fork picked up upstream README"
  assert_eq "$(git -C "$work" show jkubo:FORK.md)" "fork" "fork file survived"
  cmp -s <(git -C "$work" show jkubo:scripts/sync-upstream.sh) "$REAL_SYNC" \
    || fail "rebased sync script bytes differ from the delivered script"
  if git -C "$work" cat-file -e main:FORK.md 2>/dev/null; then
    fail "main contains fork delta"
  fi
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$(git -C "$work" rev-parse jkubo)" \
    "evidence sha"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" "evidence main"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "evidence upstream"
  assert_eq "$(grep -c hooked "$HOOK_LOG")" "1" "one normal pre-push hook"
  [[ "$origin_main_before" != "$UP_SHA" ]] || fail "fixture did not actually move upstream"
  grep -F "fork sha=$(git -C "$work" rev-parse jkubo) changed=true" "$SYNC_LOG" >/dev/null \
    || fail "log SHA evidence does not match jkubo"
  say "success"
}

scenario_noop() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  install_hook "$work"
  local tip main_sha
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  run_sync "$work" --push
  assert_rc 0 "no-op sync"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "jkubo SHA unchanged"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "main SHA unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "origin/jkubo unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "origin/main unchanged"
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$tip" "evidence sha is the delivered fixture head"
  say "no-op"
}

scenario_workflow_update() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'kept-v2\n' > .github/workflows/kept.yml; printf 'new\n' > .github/workflows/new.yml"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 0 "workflow update sync"
  assert_eq "$(git -C "$work" rev-parse main)" "$UP_SHA" "main matches upstream after workflow edit"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "origin/main matches upstream"
  assert_eq "$(git -C "$work" show main:.github/workflows/kept.yml)" "kept-v2" "main has upstream workflow"
  assert_eq "$(git -C "$work" show main:.github/workflows/new.yml)" "new" "main has added workflow"
  assert_eq "$(git -C "$work" show jkubo:.github/workflows/kept.yml)" "kept-v2" "jkubo has upstream workflow"
  assert_eq "$(git -C "$work" show jkubo:.github/workflows/new.yml)" "new" "jkubo has added workflow"
  assert_eq "$(git -C "$work" show jkubo:.github/workflows/sync-upstream.yml)" \
    "$(git -C "$work" show "${SEED_TIP}:.github/workflows/sync-upstream.yml")" \
    "fork workflow bytes preserved"
  if git -C "$work" cat-file -e main:FORK.md 2>/dev/null; then
    fail "workflow update put fork delta on main"
  fi
  say "upstream workflow updates"
}

scenario_rollback() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  # Fork and upstream both edit README, so the replay conflicts.
  git -C "$work" checkout -q jkubo
  printf 'fork-readme\n' >"$work/README.md"
  commit_tree "$work" "fork readme"
  local tip
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin "${tip}:refs/heads/jkubo"
  advance_upstream "$work" bash -c "printf 'upstream-readme\n' > README.md"
  local main_sha
  main_sha="$(git -C "$work" rev-parse main)"
  install_hook "$work"

  run_sync "$work" --push
  assert_rc 1 "conflict with local main"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "jkubo restored"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "main not advanced"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "origin/jkubo not pushed"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "origin/main not pushed"
  no_rebase_left "$work"
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "changed after rollback"
  assert_eq "$(out_value sha "$EVIDENCE")" "$tip" "sha after rollback"
  [[ ! -s "$HOOK_LOG" ]] || fail "push hook ran during conflict rollback"
  grep -F "left untouched at ${tip}" "$SYNC_LOG" >/dev/null \
    || fail "conflict log does not name the restored SHA"

  # Fresh CI checkout: no local main. A conflict must not leave one behind.
  git -C "$work" branch -D main >/dev/null
  run_sync "$work" --push
  assert_rc 1 "conflict without local main"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "jkubo restored in CI shape"
  if git -C "$work" show-ref --verify --quiet refs/heads/main; then
    fail "conflict created local main"
  fi
  assert_eq "$(out_value main "$EVIDENCE")" "absent" "main evidence absent"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "origin/main still unchanged"
  no_rebase_left "$work"
  say "conflict rollback"
}

scenario_pure_mirror() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'mirror\n' > README.md"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 0 "pure mirror sync"
  assert_eq "$(git -C "$work" rev-parse main)" "$(git -C "$work" rev-parse upstream/main)" \
    "local main equals upstream"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$(git -C "$work" rev-parse upstream/main)" \
    "origin/main equals upstream"
  git -C "$work" diff --exit-code main upstream/main >/dev/null \
    || fail "main tree differs from upstream"
  if git -C "$work" cat-file -e main:FORK.md 2>/dev/null; then
    fail "pure mirror contains FORK.md"
  fi

  # main already contains upstream plus an extra commit. ff-only would succeed
  # and leave the extra commit in place. The script must refuse that.
  git -C "$work" checkout -q main
  printf 'delta\n' >"$work/DELTA.md"
  commit_tree "$work" "illegal main delta"
  local dirty_main tip
  dirty_main="$(git -C "$work" rev-parse main)"
  tip="$(git -C "$work" rev-parse jkubo)"
  git -C "$work" push -q origin "${dirty_main}:refs/heads/main"
  git -C "$work" checkout -q jkubo
  run_sync "$work" --push
  assert_rc 1 "ahead main refused"
  assert_eq "$(git -C "$work" rev-parse main)" "$dirty_main" "ahead main unchanged"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "jkubo restored when main is impure"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$dirty_main" "impure origin/main not rewritten"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "origin/jkubo not pushed"
  no_rebase_left "$work"
  say "pure mirror main"
}

scenario_exact_head() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  install_hook "$work"
  local tip
  tip="$(git -C "$work" rev-parse jkubo)"
  cmp -s <(git -C "$work" show "${tip}:scripts/sync-upstream.sh") "$REAL_SYNC" \
    || fail "fixture head is not the delivered sync script"
  run_sync "$work" --push
  assert_rc 0 "exact head sync"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "fixture patched head SHA unchanged"
  assert_eq "$(out_value sha "$EVIDENCE")" "$tip" "output sha is the patched head"
  assert_eq "$(git -C "$work" rev-parse "jkubo:scripts/sync-upstream.sh")" "$delivered_blob" \
    "patched head blob is the delivered script"
  say "exact fixture patched head ${tip}"
}

scenario_dirty() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  install_hook "$work"
  local tip main_sha
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  printf 'dirty\n' >>"$work/README.md"
  run_sync "$work" --push
  assert_rc 1 "dirty tracked tree"
  grep -F 'working tree is dirty' "$SYNC_LOG" >/dev/null || fail "dirty error missing"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "dirty refusal left jkubo"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "dirty refusal left main"
  [[ ! -s "$HOOK_LOG" ]] || fail "dirty refusal pushed"
  git -C "$work" checkout -q -- README.md

  printf 'untracked\n' >"$work/untracked.txt"
  run_sync "$work"
  assert_rc 1 "dirty untracked tree"
  grep -F 'working tree is dirty' "$SYNC_LOG" >/dev/null || fail "untracked error missing"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "untracked refusal left jkubo"
  rm -f "$work/untracked.txt"

  printf 'dirty-again\n' >>"$work/README.md"
  run_sync "$work" --dry-run
  assert_rc 0 "dry-run on a dirty tree"
  grep -F '[dry-run]' "$SYNC_LOG" >/dev/null || fail "dry-run produced no report"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "dry-run left jkubo"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "dry-run left main"
  git -C "$work" checkout -q -- README.md
  say "dirty-tree refusal"
}

scenario_absent_token() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'needs-push\n' > README.md"
  install_hook "$work"
  local tip main_sha origin_main
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  FORK_SYNC_TOKEN_REQUIRED=1 run_sync "$work" --push
  assert_rc 1 "absent token"
  grep -F 'FORK_SYNC_TOKEN is absent. Refusing to push.' "$SYNC_LOG" >/dev/null \
    || fail "absent-token error missing"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "token refusal left jkubo"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "token refusal left main"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "token refusal did not push main"
  [[ ! -s "$HOOK_LOG" ]] || fail "token refusal reached the push hook"
  say "absent FORK_SYNC_TOKEN"
}

scenario_lease() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'lease\n' > README.md"
  # A side commit the hook will swing origin/jkubo to, after the script has
  # already recorded the fetch-time lease.
  git -C "$work" checkout -q -B spoiler upstream/main
  printf 'spoiler\n' >"$work/SPOILER.md"
  commit_tree "$work" "spoiler"
  local spoil tip main_sha
  spoil="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin "${spoil}:refs/heads/spoiler"
  git -C "$work" checkout -q jkubo
  git -C "$work" branch -D spoiler >/dev/null
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  install_hook "$work"
  SPOIL_JKUBO=1 SPOIL_SHA="$spoil" run_sync "$work" --push
  assert_rc 1 "lease rejection"
  grep -F spoiled "$HOOK_LOG" >/dev/null || fail "pre-push hook did not run"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "local jkubo rolled back"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "local main rolled back"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$spoil" "remote jkubo stayed at the hook's update"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "atomic push did not advance origin/main"
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "changed after push rollback"
  assert_eq "$(out_value sha "$EVIDENCE")" "$tip" "sha after push rollback"
  no_rebase_left "$work"
  say "push lease rollback"
}

scenario_remote_advanced() {
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha before
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  assert_eq "$(git -C "$work" rev-parse refs/remotes/origin/jkubo)" "$tip" \
    "fixture remote-tracking fork is the pre-fetch tip"
  publish_side_fork "REMOTE_ONLY.md" "remote-only" "remote only"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$SIDE_TIP" \
    "bare origin fork advanced before fetch"
  git -C "$SB_ROOT/side" merge-base --is-ancestor "$tip" "$SIDE_TIP" \
    || fail "remote-only commit does not contain the local tip"
  install_hook "$work"
  before="$SB_ROOT/state-before"
  capture_state "$work" "$before"
  run_sync "$work" --push
  assert_rc 1 "remote advanced before fetch"
  grep -F "is not an ancestor of local" "$SYNC_LOG" >/dev/null \
    || fail "remote-advanced error missing"
  grep -F "Refusing to rebase or push" "$SYNC_LOG" >/dev/null \
    || fail "remote-advanced refusal missing"
  assert_state_unchanged "$work" "$before"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "local jkubo not rebased"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "local main not moved"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$SIDE_TIP" "origin jkubo kept remote commit"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "origin main not pushed"
  assert_eq "$(git -C "$work" rev-parse refs/remotes/origin/jkubo)" "$SIDE_TIP" \
    "fetch observed the remote-only tip"
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" show "${SIDE_TIP}:REMOTE_ONLY.md")" \
    "remote-only" "REMOTE_ONLY.md still on origin"
  assert_eq "$(git -C "$work" show jkubo:README.md)" "base" \
    "local fork was not rebased onto upstream"
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "changed after remote-advanced refusal"
  assert_eq "$(out_value sha "$EVIDENCE")" "$tip" "sha after remote-advanced refusal"
  [[ ! -s "$HOOK_LOG" ]] || fail "remote-advanced refusal pushed"
  no_rebase_left "$work"
  say "remote advanced before fetch"
}

scenario_divergent_fork() {
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha before
  seed_fork "$work"
  main_sha="$(git -C "$work" rev-parse main)"
  printf 'local-only\n' >"$work/LOCAL_ONLY.md"
  commit_tree "$work" "local only"
  tip="$(git -C "$work" rev-parse jkubo)"
  publish_side_fork "REMOTE_ONLY.md" "remote-only" "remote only"
  git -C "$SB_ROOT/side" fetch -q "$work" "refs/heads/jkubo:refs/tmp/local-jkubo"
  if git -C "$SB_ROOT/side" merge-base --is-ancestor "$SIDE_TIP" refs/tmp/local-jkubo; then
    fail "divergent fixture: remote tip is an ancestor of local"
  fi
  if git -C "$SB_ROOT/side" merge-base --is-ancestor refs/tmp/local-jkubo "$SIDE_TIP"; then
    fail "divergent fixture: local tip is an ancestor of remote"
  fi
  install_hook "$work"
  before="$SB_ROOT/state-before"
  capture_state "$work" "$before"
  run_sync "$work" --push
  assert_rc 1 "divergent fork"
  grep -F "is not an ancestor of local" "$SYNC_LOG" >/dev/null \
    || fail "divergent error missing"
  assert_state_unchanged "$work" "$before"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "divergent local jkubo unchanged"
  assert_eq "$(git -C "$work" show jkubo:LOCAL_ONLY.md)" "local-only" \
    "local-only commit kept"
  if git -C "$work" cat-file -e "jkubo:REMOTE_ONLY.md" 2>/dev/null; then
    fail "local jkubo absorbed REMOTE_ONLY.md"
  fi
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$SIDE_TIP" \
    "origin jkubo kept the divergent commit"
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" show "${SIDE_TIP}:REMOTE_ONLY.md")" \
    "remote-only" "REMOTE_ONLY.md still on divergent origin"
  if git --git-dir="$SB_ROOT/origin.git" cat-file -e "${SIDE_TIP}:LOCAL_ONLY.md" 2>/dev/null; then
    fail "origin jkubo absorbed LOCAL_ONLY.md"
  fi
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "divergent origin main unchanged"
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "changed after divergent refusal"
  [[ ! -s "$HOOK_LOG" ]] || fail "divergent refusal pushed"
  no_rebase_left "$work"
  say "divergent fork history"
}

scenario_local_ahead() {
  new_sandbox
  local work="$SB_ROOT/work" origin_before tip
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  origin_before="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  printf 'keep\n' >"$work/LOCAL_KEEP.md"
  commit_tree "$work" "local keep"
  tip="$(git -C "$work" rev-parse jkubo)"
  git -C "$work" merge-base --is-ancestor "$origin_before" "$tip" \
    || fail "local-ahead fixture is not ahead of origin"
  [[ "$tip" != "$origin_before" ]] || fail "local-ahead fixture did not add a commit"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 0 "local ahead of origin"
  if grep -F "is not an ancestor of local" "$SYNC_LOG"; then
    fail "local-ahead sync was refused"
  fi
  assert_eq "$(git -C "$work" rev-parse jkubo~2)" "$UP_SHA" \
    "rebased local-ahead history is based on upstream"
  assert_eq "$(git -C "$work" show jkubo:LOCAL_KEEP.md)" "keep" "local commit survived rebase"
  assert_eq "$(git -C "$work" show jkubo:README.md)" "upstream-moved" \
    "local-ahead fork picked up upstream"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$(git -C "$work" rev-parse jkubo)" \
    "origin jkubo received the rebased local commit"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "local-ahead origin main"
  assert_eq "$(grep -c hooked "$HOOK_LOG")" "1" "local-ahead push used the normal hook"
  say "local fork ahead of origin"
}

scenario_paused_cherry_pick() {
  new_sandbox
  local work="$SB_ROOT/work" already extra git_dir before cp_rc
  seed_fork "$work"
  install_hook "$work"
  git -C "$work" checkout -q -b source
  printf 'already\n' >"$work/SAME.md"
  commit_tree "$work" "already"
  already="$(git -C "$work" rev-parse HEAD)"
  printf 'extra\n' >"$work/EXTRA.md"
  commit_tree "$work" "extra"
  extra="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q jkubo
  printf 'already\n' >"$work/SAME.md"
  commit_tree "$work" "preimage"
  set +e
  git -C "$work" cherry-pick "$already" "$extra" >"$SB_ROOT/cherry.out" 2>&1
  cp_rc=$?
  set -e
  [[ "$cp_rc" -ne 0 ]] || fail "empty multi cherry-pick did not stop"
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  [[ -f "$git_dir/CHERRY_PICK_HEAD" ]] || fail "paused cherry-pick has no CHERRY_PICK_HEAD"
  [[ -d "$git_dir/sequencer" ]] || fail "paused cherry-pick has no sequencer"
  [[ -z "$(git -C "$work" status --porcelain)" ]] \
    || fail "paused cherry-pick porcelain was not empty: $(git -C "$work" status --porcelain)"
  before="$SB_ROOT/state-before"
  capture_state "$work" "$before"

  run_sync "$work" --push
  assert_rc 1 "paused cherry-pick"
  grep -F "cherry-pick already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "cherry-pick refusal missing"
  assert_state_unchanged "$work" "$before"
  [[ ! -s "$HOOK_LOG" ]] || fail "cherry-pick refusal pushed"

  run_sync "$work" --allow-dirty --push
  assert_rc 1 "paused cherry-pick with --allow-dirty"
  grep -F "cherry-pick already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "allow-dirty cherry-pick refusal missing"
  assert_state_unchanged "$work" "$before"
  [[ ! -s "$HOOK_LOG" ]] || fail "allow-dirty cherry-pick refusal pushed"

  printf 'dirty\n' >>"$work/README.md"
  capture_state "$work" "$before"
  run_sync "$work" --allow-dirty --push
  assert_rc 1 "dirty paused cherry-pick with --allow-dirty"
  grep -F "cherry-pick already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "dirty allow-dirty cherry-pick refusal missing"
  assert_state_unchanged "$work" "$before"
  grep -F 'dirty' "$work/README.md" >/dev/null || fail "dirty worktree line was lost"
  [[ ! -s "$HOOK_LOG" ]] || fail "dirty cherry-pick refusal pushed"
  say "paused multi-commit cherry-pick"
}

scenario_revert_sequencer() {
  new_sandbox
  local work="$SB_ROOT/work" one two git_dir before rv_rc
  seed_fork "$work"
  install_hook "$work"
  printf 'one\n' >"$work/ONE.md"
  commit_tree "$work" "one"
  one="$(git -C "$work" rev-parse HEAD)"
  printf 'two\n' >"$work/TWO.md"
  commit_tree "$work" "two"
  two="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" rm -q ONE.md
  commit_tree "$work" "undo one"
  set +e
  git -C "$work" -c core.editor=true revert --no-edit "$one" "$two" >"$SB_ROOT/revert.out" 2>&1
  rv_rc=$?
  set -e
  [[ "$rv_rc" -ne 0 ]] || fail "empty multi revert did not stop"
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  [[ ! -f "$git_dir/REVERT_HEAD" ]] || fail "empty multi revert left REVERT_HEAD"
  [[ -d "$git_dir/sequencer" ]] || fail "empty multi revert has no sequencer"
  [[ -z "$(git -C "$work" status --porcelain)" ]] \
    || fail "paused revert porcelain was not empty: $(git -C "$work" status --porcelain)"
  before="$SB_ROOT/state-before"
  capture_state "$work" "$before"

  run_sync "$work" --push
  assert_rc 1 "paused revert sequencer"
  grep -F "sequencer already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "sequencer refusal missing"
  assert_state_unchanged "$work" "$before"
  [[ ! -s "$HOOK_LOG" ]] || fail "sequencer refusal pushed"

  run_sync "$work" --allow-dirty --push
  assert_rc 1 "paused revert sequencer with --allow-dirty"
  grep -F "sequencer already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "allow-dirty sequencer refusal missing"
  assert_state_unchanged "$work" "$before"
  [[ ! -s "$HOOK_LOG" ]] || fail "allow-dirty sequencer refusal pushed"

  # A conflicted revert has REVERT_HEAD and a dirty index, and no sequencer.
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  install_hook "$work"
  printf 'v1\n' >"$work/C.txt"
  commit_tree "$work" "c1"
  one="$(git -C "$work" rev-parse HEAD)"
  printf 'v2\n' >"$work/C.txt"
  commit_tree "$work" "c2"
  set +e
  git -C "$work" -c core.editor=true revert --no-edit "$one" >"$SB_ROOT/revert.out" 2>&1
  rv_rc=$?
  set -e
  [[ "$rv_rc" -ne 0 ]] || fail "conflicted revert did not stop"
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  [[ -f "$git_dir/REVERT_HEAD" ]] || fail "conflicted revert has no REVERT_HEAD"
  [[ -n "$(git -C "$work" status --porcelain)" ]] \
    || fail "conflicted revert porcelain was empty"
  before="$SB_ROOT/state-before"
  capture_state "$work" "$before"

  run_sync "$work" --push
  assert_rc 1 "conflicted revert"
  grep -F "revert already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "revert refusal missing"
  assert_state_unchanged "$work" "$before"
  [[ ! -s "$HOOK_LOG" ]] || fail "revert refusal pushed"

  run_sync "$work" --allow-dirty --push
  assert_rc 1 "conflicted revert with --allow-dirty"
  grep -F "revert already in progress; refusing to abort it" "$SYNC_LOG" >/dev/null \
    || fail "allow-dirty revert refusal missing"
  assert_state_unchanged "$work" "$before"
  [[ ! -s "$HOOK_LOG" ]] || fail "allow-dirty revert refusal pushed"
  say "revert and sequencer refusal"
}

scenario_success
scenario_noop
scenario_workflow_update
scenario_rollback
scenario_pure_mirror
scenario_exact_head
scenario_dirty
scenario_absent_token
scenario_lease
scenario_remote_advanced
scenario_divergent_fork
scenario_local_ahead
scenario_paused_cherry_pick
scenario_revert_sequencer
say "all scenarios passed"
