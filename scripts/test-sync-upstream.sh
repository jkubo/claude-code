#!/usr/bin/env bash
# Exercise scripts/sync-upstream.sh against disposable local Git remotes.
# The fixture runs a byte copy of this repo's script. Pushes stay inside the
# scratch remotes and go through a normal pre-push hook.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_SYNC="$ROOT/scripts/sync-upstream.sh"
WF="$ROOT/.github/workflows/sync-upstream.yml"
# Official commit this fixture was replayed onto. The previous public
# candidate pinned 71cdddec623889d38af14b7a489670a03186f659; the pin moved
# with that base and the four-path fork delta is unchanged.
UPSTREAM_PIN="b0b7bed9820350bb0942e32c7f00752a99ea3555"

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

# Native upload-pack child records real remote contact without replacing Git.
install_contact_remotes() {
  local work="$1"
  cat >"$SB_ROOT/contact-upload-pack" <<EOF
#!/bin/bash
printf 'upload-pack\n' >>"$SB_ROOT/git-contact"
exec /usr/bin/git-upload-pack "\$@"
EOF
  chmod +x "$SB_ROOT/contact-upload-pack"
  git -C "$work" config remote.origin.uploadpack "$SB_ROOT/contact-upload-pack"
  git -C "$work" config remote.upstream.uploadpack "$SB_ROOT/contact-upload-pack"
}

# Bare origin update hook. Rejects exactly one receive refspec. With an atomic
# push the other refspec must fail too and neither ref moves.
install_update_reject() {
  local refname="$1"
  : >"$SB_ROOT/origin.git/update-log"
  cat >"$SB_ROOT/origin.git/hooks/update" <<EOF
#!/bin/bash
printf '%s %s %s\n' "\$1" "\$2" "\$3" >>"\$GIT_DIR/update-log"
if [[ "\$1" == "$refname" ]]; then
  printf 'rejecting %s\n' "\$1" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$SB_ROOT/origin.git/hooks/update"
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
  if [[ -n "${GIT_CONTACT_LOG:-}" ]]; then
    cmd+=("GIT_CONTACT_LOG=$GIT_CONTACT_LOG")
  fi
  if [[ -n "${SYNC_GIT_CONFIG_GLOBAL:-}" ]]; then
    cmd+=("GIT_CONFIG_GLOBAL=$SYNC_GIT_CONFIG_GLOBAL")
  fi
  set +e
  "${cmd[@]}" "$work/scripts/sync-upstream.sh" "$@" >"$SYNC_LOG" 2>&1
  SYNC_RC=$?
  set -e
  unset SPOIL_JKUBO SPOIL_SHA PASS_TOKEN FORK_SYNC_TOKEN_REQUIRED \
    GIT_CONTACT_LOG SYNC_GIT_CONFIG_GLOBAL || true
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
  git -C "$work" merge-base --is-ancestor "$UP_SHA" jkubo || fail "completed local replay lost"
  local replay
  replay="$(git -C "$work" rev-parse jkubo)"
  [[ "$replay" != "$tip" ]] || fail "lease scenario did not replay"
  assert_eq "$(git -C "$work" rev-parse main)" "$UP_SHA" "local mirror retained"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$spoil" "remote jkubo stayed at the hook's update"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "atomic push did not advance origin/main"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "changed after retained replay"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "sha after retained replay"
  no_rebase_left "$work"
  say "push lease rejection retains local replay"
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

# Clean or dirty detached HEAD. Both the plain run and --allow-dirty must
# refuse before fetch or push and leave the detached commit in place.
run_detached_once() {
  local work="$1" before="$2"
  shift 2
  capture_state "$work" "$before"
  git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/remotes | sort \
    >"$SB_ROOT/remotes-before"
  : >"$SB_ROOT/git-contact"
  GIT_CONTACT_LOG="$SB_ROOT/git-contact"
  run_sync "$work" "$@"
}

scenario_detached_head() {
  new_sandbox
  local work="$SB_ROOT/work" detached tip main_sha before
  seed_fork "$work"
  install_hook "$work"
  git -C "$work" checkout -q --detach HEAD
  printf 'unique-detached-note\n' >"$work/DETACHED_NOTE.txt"
  git -C "$work" add -- DETACHED_NOTE.txt
  git -C "$work" commit -q -m "unique detached note"
  detached="$(git -C "$work" rev-parse HEAD)"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  [[ "$detached" != "$tip" && "$detached" != "$main_sha" ]] \
    || fail "detached note is not a unique commit"
  [[ -z "$(git -C "$work" for-each-ref --points-at HEAD --format='%(refname)')" ]] \
    || fail "detached commit is on a named ref"
  install_contact_remotes "$work"
  before="$SB_ROOT/state-before"

  run_detached_once "$work" "$before"
  assert_rc 1 "detached HEAD"
  grep -F "HEAD is detached. Switch to an intended named branch." "$SYNC_LOG" >/dev/null \
    || fail "detached error missing"
  [[ ! -s "$SB_ROOT/git-contact" ]] || fail "detached refusal contacted a remote: $(cat "$SB_ROOT/git-contact")"
  [[ ! -s "$HOOK_LOG" ]] || fail "detached refusal ran the push hook"
  assert_state_unchanged "$work" "$before"
  cmp -s "$SB_ROOT/remotes-before" \
    <(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/remotes | sort) \
    || fail "detached refusal moved remote-tracking refs"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$detached" "detached oid preserved"
  assert_eq "$(git -C "$work" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED" \
    "HEAD stayed detached"
  assert_eq "$(git -C "$work" show HEAD:DETACHED_NOTE.txt)" "unique-detached-note" \
    "detached file bytes preserved"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "named jkubo unchanged"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "named main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "origin jkubo unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "origin main unchanged"

  run_detached_once "$work" "$before" --push
  assert_rc 1 "detached HEAD with --push"
  grep -F "HEAD is detached. Switch to an intended named branch." "$SYNC_LOG" >/dev/null \
    || fail "push detached error missing"
  [[ ! -s "$SB_ROOT/git-contact" ]] || fail "push detached refusal contacted a remote: $(cat "$SB_ROOT/git-contact")"
  [[ ! -s "$HOOK_LOG" ]] || fail "push detached refusal ran the push hook"
  assert_state_unchanged "$work" "$before"

  printf 'dirty-detached\n' >>"$work/README.md"
  run_detached_once "$work" "$before" --allow-dirty
  assert_rc 1 "detached HEAD with --allow-dirty"
  grep -F "HEAD is detached. Switch to an intended named branch." "$SYNC_LOG" >/dev/null \
    || fail "allow-dirty detached error missing"
  [[ ! -s "$SB_ROOT/git-contact" ]] || fail "allow-dirty detached refusal contacted a remote: $(cat "$SB_ROOT/git-contact")"
  [[ ! -s "$HOOK_LOG" ]] || fail "allow-dirty detached refusal ran the push hook"
  assert_state_unchanged "$work" "$before"
  grep -F 'dirty-detached' "$work/README.md" >/dev/null || fail "dirty detached line was lost"

  run_detached_once "$work" "$before" --allow-dirty --push
  assert_rc 1 "detached HEAD with --allow-dirty --push"
  grep -F "HEAD is detached. Switch to an intended named branch." "$SYNC_LOG" >/dev/null \
    || fail "allow-dirty push detached error missing"
  [[ ! -s "$SB_ROOT/git-contact" ]] || fail "allow-dirty push detached refusal contacted a remote: $(cat "$SB_ROOT/git-contact")"
  [[ ! -s "$HOOK_LOG" ]] || fail "allow-dirty push detached refusal ran the push hook"
  assert_state_unchanged "$work" "$before"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$detached" "dirty detached oid preserved"
  assert_eq "$(git -C "$work" show HEAD:DETACHED_NOTE.txt)" "unique-detached-note" \
    "dirty detached file bytes preserved"
  say "detached HEAD refusal"
}

snapshot_attached() {
  local work="$1" dest="$2"
  {
    echo "HEAD=$(git -C "$work" rev-parse HEAD)"
    echo "symref=$(git -C "$work" symbolic-ref HEAD)"
    echo "heads<<"
    git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort
    echo ">>"
    git -C "$work" ls-files -s
    git -C "$work" status --porcelain=v1 --untracked-files=all
    git -C "$work" diff --binary
    git -C "$work" diff --cached --binary
  } >"$dest"
}

# Reject one receive refspec from a normal update hook on the bare origin.
# The other refspec is in the same atomic push and must stay unmoved too.
scenario_receive_reject() {
  local reject_ref="$1" label="$2"
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha origin_main origin_fork before after
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'recv\n' > README.md"
  install_hook "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_fork="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  # Attached start is not the fork branch. Safe cleanup must return here.
  git -C "$work" checkout -q -B operator "$tip"
  [[ "$(git -C "$work" symbolic-ref HEAD)" == "refs/heads/operator" ]] \
    || fail "$label start is not the attached operator branch"
  before="$SB_ROOT/checkout-before"
  snapshot_attached "$work" "$before"
  install_update_reject "$reject_ref"
  run_sync "$work" --push
  assert_rc 1 "$label"
  grep -F "push rejected" "$SYNC_LOG" >/dev/null \
    || fail "$label did not reach push rejection"
  grep -F "rejecting $reject_ref" "$SYNC_LOG" >/dev/null \
    || fail "$label receive hook did not reject $reject_ref"
  grep -F "hook declined" "$SYNC_LOG" >/dev/null \
    || fail "$label missing hook declined"
  grep -F "atomic push failure" "$SYNC_LOG" >/dev/null \
    || fail "$label missing atomic push failure"
  grep -F -e "-> main" "$SYNC_LOG" >/dev/null || fail "$label push did not include main"
  grep -F -e "-> jkubo" "$SYNC_LOG" >/dev/null || fail "$label push did not include jkubo"
  grep -F "$reject_ref" "$SB_ROOT/origin.git/update-log" >/dev/null \
    || fail "$label update hook did not see $reject_ref"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" \
    "$label origin main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$origin_fork" \
    "$label origin jkubo unchanged"
  local replay
  replay="$(git -C "$work" rev-parse jkubo)"
  [[ "$replay" != "$tip" ]] || fail "$label completed replay lost"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" jkubo || fail "$label upstream replay lost"
  assert_eq "$(git -C "$work" rev-parse main)" "$UP_SHA" "$label mirror update retained"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$label restored the starting branch"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$tip" "$label HEAD oid restored"
  after="$SB_ROOT/checkout-after"
  snapshot_attached "$work" "$after"
  git -C "$work" diff --quiet || fail "$label starting worktree changed"
  git -C "$work" diff --cached --quiet || fail "$label starting index changed"
  git -C "$work" diff --exit-code "$tip" -- >/dev/null || fail "$label starting checkout bytes changed"
  assert_eq "$(git -C "$work" rev-parse operator)" "$tip" "$label original operator ref preserved"
  no_rebase_left "$work"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "$label changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "$label retained replay sha"
  grep -F hooked "$HOOK_LOG" >/dev/null \
    || fail "$label skipped the normal pre-push hook"
  say "$label"
}

# upload-pack's pack-objects hook commits on the checked-out branch while
# fetch is in progress, then a normal pre-push hook rejects without writing.
scenario_fetch_commit_rejects_push() {
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha origin_main origin_fork note
  seed_fork "$work"
  # The new upstream commit is created outside this worktree. A commit made
  # here would already be local, and fetch would not run upload-pack's
  # pack-objects hook.
  git clone -q -b main "$SB_ROOT/upstream.git" "$SB_ROOT/up-side"
  git -C "$SB_ROOT/up-side" config user.name "Jay Kubo"
  git -C "$SB_ROOT/up-side" config user.email "6161465+jkubo@users.noreply.github.com"
  git -C "$SB_ROOT/up-side" config commit.gpgsign false
  printf 'upstream-moved\n' >"$SB_ROOT/up-side/README.md"
  git -C "$SB_ROOT/up-side" commit -q -am "upstream move"
  UP_SHA="$(git -C "$SB_ROOT/up-side" rev-parse HEAD)"
  git -C "$SB_ROOT/up-side" push -q origin "HEAD:refs/heads/main"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_fork="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  [[ "$(git -C "$work" rev-parse upstream/main)" != "$UP_SHA" ]] \
    || fail "worktree already has the upstream object, so fetch would not pack"
  [[ "$(git -C "$work" symbolic-ref HEAD)" == "refs/heads/jkubo" ]] \
    || fail "fetch-commit fixture is not on jkubo"
  cat >"$work/.git/hooks/pre-push" <<'EOF'
#!/bin/bash
printf 'reject-pre-push\n' >>"${HOOK_MARK:-/dev/null}"
exit 1
EOF
  chmod +x "$work/.git/hooks/pre-push"
  cat >"$SB_ROOT/pack-hook.sh" <<EOF
#!/bin/bash
printf 'hook-ran\n' >>"$SB_ROOT/pack-hook.log"
if [[ ! -f "$SB_ROOT/fetch-commit-done" ]]; then
  printf 'operator-during-fetch\n' >"$work/OPERATOR_NOTE"
  clear_git='env -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX -u GIT_IMPLICIT_WORK_TREE -u GIT_OBJECT_DIRECTORY -u GIT_QUARANTINE_PATH -u GIT_NAMESPACE -u GIT_ALTERNATE_OBJECT_DIRECTORIES'
  if \$clear_git git -C "$work" add -- OPERATOR_NOTE >>"$SB_ROOT/pack-hook.log" 2>&1 </dev/null \
    && \$clear_git git -C "$work" commit -q -m "operator note during fetch" >>"$SB_ROOT/pack-hook.log" 2>&1 </dev/null
  then
    \$clear_git git -C "$work" rev-parse HEAD >"$SB_ROOT/fetch-commit-sha" 2>>"$SB_ROOT/pack-hook.log"
    printf '1\n' >"$SB_ROOT/fetch-commit-done"
  else
    printf 'commit-failed\n' >>"$SB_ROOT/pack-hook.log"
  fi
fi
exec "\$@"
EOF
  chmod +x "$SB_ROOT/pack-hook.sh"
  git config --file "$SB_ROOT/gitconfig" uploadpack.packObjectsHook "$SB_ROOT/pack-hook.sh"
  SYNC_GIT_CONFIG_GLOBAL="$SB_ROOT/gitconfig"
  run_sync "$work" --push
  assert_rc 1 "fetch commit with rejecting pre-push"
  grep -F 'hook-ran' "$SB_ROOT/pack-hook.log" >/dev/null \
    || fail "upload-pack pack-objects hook did not run"
  [[ -s "$SB_ROOT/fetch-commit-sha" ]] || fail "upload-pack child did not commit: $(cat "$SB_ROOT/pack-hook.log" 2>/dev/null || true)"
  note="$(tr -d '[:space:]' <"$SB_ROOT/fetch-commit-sha")"
  grep -F "changed during fetch. Refusing to rebase or push." "$SYNC_LOG" >/dev/null \
    || fail "fetch-commit refusal missing"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$note" \
    "named jkubo kept the fetch commit"
  assert_eq "$(git -C "$work" rev-parse jkubo^)" "$tip" \
    "fetch commit parent is the pre-sync fork tip"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$note" "HEAD kept the fetch commit"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" "stayed on jkubo"
  assert_eq "$(git -C "$work" show "jkubo:OPERATOR_NOTE")" "operator-during-fetch" \
    "commit file preserved"
  assert_eq "$(cat "$work/OPERATOR_NOTE")" "operator-during-fetch" "worktree file preserved"
  git -C "$work" diff --quiet || fail "worktree differs from the preserved commit"
  git -C "$work" diff --cached --quiet || fail "index differs from the preserved commit"
  git -C "$work" ls-files --error-unmatch -- OPERATOR_NOTE >/dev/null \
    || fail "index lost OPERATOR_NOTE"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "local main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "origin main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$origin_fork" "origin jkubo unchanged"
  assert_eq "$(out_value sha "$EVIDENCE")" "$note" "evidence names the preserved fetch commit"
  [[ ! -s "$HOOK_LOG" ]] || fail "rejecting pre-push ran after the fetch refusal"
  say "fetch commit preserved when pre-push would reject"
}

# The pre-push hook itself commits, then rejects. The new commit stays on the
# branch that was checked out. Completed fork replay also remains. Neither
# remote target moves.
scenario_pre_push_commit_rejects() {
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha origin_main origin_fork note branch
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_fork="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  cat >"$work/.git/hooks/pre-push" <<EOF
#!/bin/bash
printf 'pre-push-commit\n' >>"\${HOOK_MARK:-/dev/null}"
printf 'operator-pre-push\n' > OPERATOR_NOTE
git add -- OPERATOR_NOTE
git commit -q -m "operator note during pre-push"
git rev-parse HEAD >"$SB_ROOT/pre-push-sha"
git symbolic-ref --short HEAD >"$SB_ROOT/pre-push-branch"
exit 1
EOF
  chmod +x "$work/.git/hooks/pre-push"
  run_sync "$work" --push
  assert_rc 1 "pre-push commit then rejection"
  [[ -s "$SB_ROOT/pre-push-sha" ]] || fail "pre-push hook did not commit"
  note="$(tr -d '[:space:]' <"$SB_ROOT/pre-push-sha")"
  branch="$(tr -d '[:space:]' <"$SB_ROOT/pre-push-branch")"
  assert_eq "$branch" "main" "pre-push commit landed on main"
  grep -F "push rejected" "$SYNC_LOG" >/dev/null || fail "pre-push rejection missing"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$note" \
    "named main kept the pre-push commit"
  assert_eq "$(git -C "$work" rev-parse "$note^")" "$UP_SHA" \
    "pre-push commit sits on the fast-forwarded mirror"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$note" "HEAD kept the pre-push commit"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/main" "stayed on main"
  assert_eq "$(git -C "$work" show "main:OPERATOR_NOTE")" "operator-pre-push" \
    "commit file preserved"
  assert_eq "$(cat "$work/OPERATOR_NOTE")" "operator-pre-push" "worktree file preserved"
  git -C "$work" diff --quiet || fail "worktree differs from the pre-push commit"
  git -C "$work" diff --cached --quiet || fail "index differs from the pre-push commit"
  git -C "$work" ls-files --error-unmatch -- OPERATOR_NOTE >/dev/null \
    || fail "index lost OPERATOR_NOTE"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" jkubo || fail "completed fork replay lost"
  local replay
  replay="$(git -C "$work" rev-parse jkubo)"
  [[ "$replay" != "$tip" ]] || fail "pre-push scenario did not replay"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" \
    "origin main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$origin_fork" \
    "origin jkubo unchanged"
  if git --git-dir="$SB_ROOT/origin.git" cat-file -e "${origin_main}:OPERATOR_NOTE" 2>/dev/null; then
    fail "origin main received OPERATOR_NOTE"
  fi
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "evidence sha is retained replay"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "changed after retained replay"
  say "pre-push commit preserved when push rejects"
}

# Atomic push publishes both targets, then the return to the attached operator
# branch fails in a normal post-checkout hook. Published local and remote tips
# stay, and the output names those uploaded commits.
scenario_published_checkout_fails() {
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha origin_main origin_fork published_fork
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_fork="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  git -C "$work" checkout -q -B operator "$tip"
  [[ "$(git -C "$work" symbolic-ref HEAD)" == "refs/heads/operator" ]] \
    || fail "checkout-fail start is not the attached operator branch"
  cat >"$work/.git/hooks/pre-push" <<'EOF'
#!/bin/bash
printf 'hooked\n' >>"${HOOK_MARK:-/dev/null}"
exit 0
EOF
  cat >"$work/.git/hooks/post-checkout" <<'EOF'
#!/bin/bash
branch="$(git symbolic-ref -q HEAD || true)"
if [[ "$branch" == "refs/heads/operator" && "${3:-}" == "1" ]]; then
  printf 'post-checkout-operator\n' >>"${HOOK_MARK:-/dev/null}"
  exit 1
fi
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-push" "$work/.git/hooks/post-checkout"
  run_sync "$work" --push
  assert_rc 1 "published push then failing post-checkout"
  grep -F "failed after the push already succeeded" "$SYNC_LOG" >/dev/null \
    || fail "checkout failure was not reported"
  grep -F "post-checkout-operator" "$HOOK_LOG" >/dev/null \
    || fail "operator post-checkout hook did not fail"
  published_fork="$(git -C "$work" rev-parse jkubo)"
  [[ "$published_fork" != "$tip" ]] || fail "local jkubo was rolled back after publish"
  assert_eq "$(git -C "$work" rev-parse jkubo^)" "$UP_SHA" \
    "published fork parent is upstream"
  assert_eq "$(git -C "$work" rev-parse main)" "$UP_SHA" "local main stayed published"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "origin main published"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$published_fork" \
    "origin jkubo matches local published fork"
  [[ "$(ref_sha "$SB_ROOT/origin.git" main)" != "$origin_main" ]] \
    || fail "origin main did not advance"
  [[ "$(ref_sha "$SB_ROOT/origin.git" jkubo)" != "$origin_fork" ]] \
    || fail "origin jkubo did not advance"
  assert_eq "$(git -C "$work" rev-parse operator)" "$tip" "operator branch tip unchanged"
  assert_eq "$(out_value sha "$EVIDENCE")" "$published_fork" "evidence sha is the uploaded fork"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" "evidence main is the uploaded mirror"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "changed after publish"
  grep -F "fork sha=${published_fork} changed=true" "$SYNC_LOG" >/dev/null \
    || fail "log SHA is not the uploaded fork"
  grep -F "main sha=${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "log main SHA is not the uploaded mirror"
  if grep -F "fork sha=${tip} " "$SYNC_LOG"; then
    fail "log reported the pre-sync fork SHA after publish"
  fi
  say "published state kept when post-checkout fails"
}

# A normal pre-push hook adds a commit, then the atomic push of the captured
# tips succeeds. Output names the uploaded fork, not the later local commit.
# The later commit remains on its named branch.
scenario_pre_push_commit_publishes() {
  new_sandbox
  local work="$SB_ROOT/work" tip later uploaded_fork
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  tip="$(git -C "$work" rev-parse jkubo)"
  cat >"$work/.git/hooks/pre-push" <<EOF
#!/bin/bash
printf 'hooked\n' >>"\${HOOK_MARK:-/dev/null}"
printf 'later-local\n' > OPERATOR_NOTE
git add -- OPERATOR_NOTE
git commit -q -m "later local operator note"
git rev-parse HEAD >"$SB_ROOT/later-sha"
git symbolic-ref --short HEAD >"$SB_ROOT/later-branch"
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-push"
  run_sync "$work" --push
  assert_rc 0 "pre-push commit then publication"
  [[ -s "$SB_ROOT/later-sha" ]] || fail "publishing pre-push hook did not commit"
  later="$(tr -d '[:space:]' <"$SB_ROOT/later-sha")"
  assert_eq "$(tr -d '[:space:]' <"$SB_ROOT/later-branch")" "main" \
    "later commit landed on main"
  uploaded_fork="$(git -C "$work" rev-parse jkubo)"
  [[ "$uploaded_fork" != "$tip" && "$uploaded_fork" != "$later" ]] \
    || fail "uploaded fork SHA is not a distinct rebased commit"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$later" \
    "named main kept the later local commit"
  assert_eq "$(git -C "$work" rev-parse "$later^")" "$UP_SHA" \
    "later commit parent is the uploaded mirror"
  assert_eq "$(git -C "$work" show "${later}:OPERATOR_NOTE")" "later-local" \
    "later commit contains the file"
  assert_eq "$(git -C "$work" ls-tree -r --name-only "$later" -- OPERATOR_NOTE)" \
    "OPERATOR_NOTE" "later commit index lists the file"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" \
    "origin main is the uploaded mirror"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$uploaded_fork" \
    "origin jkubo is the uploaded fork"
  if git --git-dir="$SB_ROOT/origin.git" cat-file -e "${UP_SHA}:OPERATOR_NOTE" 2>/dev/null; then
    fail "origin main contains the later unpushed file"
  fi
  assert_eq "$(out_value sha "$EVIDENCE")" "$uploaded_fork" \
    "evidence sha is the uploaded fork"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" \
    "evidence main is the uploaded mirror"
  [[ "$(out_value sha "$EVIDENCE")" != "$later" ]] \
    || fail "evidence sha is the later local commit"
  [[ "$(out_value main "$EVIDENCE")" != "$later" ]] \
    || fail "evidence main is the later local commit"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "changed after publication"
  grep -F "fork sha=${uploaded_fork} changed=true" "$SYNC_LOG" >/dev/null \
    || fail "log SHA is not the uploaded fork"
  grep -F "main sha=${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "log main SHA is not the uploaded mirror"
  if grep -F "$later" "$EVIDENCE"; then
    fail "GITHUB_OUTPUT contains the later unpushed commit"
  fi
  say "uploaded commit reported and later local commit kept"
}

# Ordinary hooks commit through Git, rather than moving refs with a substitute.
scenario_hook_commit_preserved() {
  local hook_name="$1" advance="$2" expected_branch="$3"
  new_sandbox
  local work="$SB_ROOT/work" tip origin_main origin_fork note
  seed_fork "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  if [[ "$advance" == yes ]]; then
    advance_upstream "$work" bash -c "printf 'new-upstream\n' > UPSTREAM_NOTE"
  fi
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_fork="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  git -C "$work" checkout -qb operator
  cat >"$work/.git/hooks/$hook_name" <<EOF
#!/bin/bash
if [[ "\$(git symbolic-ref --short -q HEAD || true)" == "$expected_branch" && ! -f "$SB_ROOT/hook-commit" ]]; then
  printf 'operator-$hook_name\n' > OPERATOR_NOTE
  git add -- OPERATOR_NOTE
  git commit -qm "operator note from $hook_name"
  git rev-parse HEAD >"$SB_ROOT/hook-commit"
fi
EOF
  if [[ "$hook_name" == pre-rebase ]]; then
    printf 'exit 1\n' >>"$work/.git/hooks/$hook_name"
  fi
  chmod +x "$work/.git/hooks/$hook_name"
  printf '#!/bin/bash\nexit 1\n' >"$work/.git/hooks/pre-push"
  chmod +x "$work/.git/hooks/pre-push"
  run_sync "$work" --push
  assert_rc 1 "$hook_name commit with rejection"
  [[ -s "$SB_ROOT/hook-commit" ]] || fail "$hook_name did not make a real commit"
  note="$(cat "$SB_ROOT/hook-commit")"
  assert_eq "$(git -C "$work" rev-parse "$expected_branch")" "$note" "$hook_name named commit retained"
  git -C "$work" for-each-ref --contains "$note" --format='%(refname)' refs/heads | grep -Fx "refs/heads/$expected_branch" >/dev/null || fail "$hook_name commit has no expected named head"
  assert_eq "$(cat "$work/OPERATOR_NOTE")" "operator-$hook_name" "$hook_name worktree bytes retained"
  assert_eq "$(git -C "$work" show :OPERATOR_NOTE)" "operator-$hook_name" "$hook_name index bytes retained"
  git -C "$work" diff --quiet || fail "$hook_name dirty worktree after commit"
  git -C "$work" diff --cached --quiet || fail "$hook_name dirty index after commit"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "$hook_name remote main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$origin_fork" "$hook_name remote fork unchanged"
  if [[ "$hook_name" == post-merge ]]; then
    grep -F 'not an exact fast-forward' "$SYNC_LOG" >/dev/null || fail "post-merge main impurity not refused"
  fi
  no_rebase_left "$work"
  say "$hook_name operator commit preserved"
}

scenario_fetch_dirty_bytes() {
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha
  seed_fork "$work"
  printf 'baseline\n' >"$work/DIRTY_NOTE"
  commit_tree "$work" "tracked dirty note"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  advance_upstream "$work" bash -c "printf 'advance\n' > UPSTREAM_NOTE"
  git -C "$work" config rebase.autostash true
  printf 'first dirty bytes\n' >"$work/DIRTY_NOTE"
  git -C "$work" status --porcelain=v1 -z >"$SB_ROOT/porcelain-before"
  cat >"$SB_ROOT/change-dirty-upload-pack" <<EOF
#!/bin/bash
printf 'second dirty bytes\n' >"$work/DIRTY_NOTE"
exec /usr/bin/git-upload-pack "\$@"
EOF
  chmod +x "$SB_ROOT/change-dirty-upload-pack"
  git -C "$work" config remote.upstream.uploadpack "$SB_ROOT/change-dirty-upload-pack"
  install_hook "$work"
  run_sync "$work" --allow-dirty --push
  assert_rc 1 "same-status dirty byte edit during fetch"
  grep -F 'changed during fetch' "$SYNC_LOG" >/dev/null || fail "fetch byte change not detected"
  cmp -s "$SB_ROOT/porcelain-before" <(git -C "$work" status --porcelain=v1 -z) || fail "dirty status changed instead of only bytes"
  assert_eq "$(cat "$work/DIRTY_NOTE")" "second dirty bytes" "changed dirty bytes preserved"
  assert_eq "$(git -C "$work" show :DIRTY_NOTE)" "baseline" "dirty-byte index preserved"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "dirty-byte fork unchanged"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "dirty-byte main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "dirty-byte remote fork unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "dirty-byte remote main unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "push hook ran after byte refusal"
  no_rebase_left "$work"
  say "same-status dirty fetch bytes refused"
}

# Removing an original conflict stage changes ownership even when surviving
# stage values and AUTO_MERGE worktree bytes still match their original trees.
scenario_conflict_stage_removed() {
  new_sandbox
  local work="$SB_ROOT/work" tip origin_main
  seed_fork "$work"
  printf 'fork-readme\n' >"$work/README.md"
  commit_tree "$work" "fork conflict edit"
  tip="$(git -C "$work" rev-parse jkubo)"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  advance_upstream "$work" bash -c "printf 'upstream-readme\n' > README.md"
  cat >"$work/.git/hooks/post-index-change" <<EOF
#!/bin/bash
set -euo pipefail
if [[ -d .git/rebase-merge && ! -e "$SB_ROOT/removed-stage" && -n "\$(git ls-files -u)" ]]; then
  printf changed >"$SB_ROOT/removed-stage"
  git ls-files -u | awk '\$3 != 1' >"$SB_ROOT/stages-23"
  printf '0 0000000000000000000000000000000000000000\\tREADME.md\\n' | git update-index --index-info
  git update-index --index-info <"$SB_ROOT/stages-23"
  git ls-files --unmerged -z >"$SB_ROOT/foreign-index"
  git hash-object --no-filters README.md >"$SB_ROOT/foreign-worktree"
fi
EOF
  chmod +x "$work/.git/hooks/post-index-change"
  run_sync "$work" --push
  assert_rc 1 "removed conflict stage"
  [[ -s "$SB_ROOT/removed-stage" && -s "$SB_ROOT/foreign-index" ]] || fail "stage removal hook did not run"
  cmp -s "$SB_ROOT/foreign-index" <(git -C "$work" ls-files --unmerged -z) || fail "foreign conflict stages were discarded"
  [[ -z "$(git -C "$work" ls-files -u | awk '$3 == 1')" ]] || fail "removed stage 1 came back"
  assert_eq "$(cat "$SB_ROOT/foreign-worktree")" "$(git -C "$work" hash-object --no-filters README.md)" "removed-stage conflict worktree preserved"
  git -C "$work" diff --quiet AUTO_MERGE -- || fail "removed-stage AUTO_MERGE bytes changed"
  [[ -d "$work/.git/rebase-merge" ]] || fail "foreign conflict operation was aborted"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "removed-stage fork ref unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "removed-stage remote fork unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "removed-stage remote main unchanged"
  grep -F 'failed rebase state is not owned' "$SYNC_LOG" >/dev/null || fail "removed stage was adopted as owned"
  say "removed original conflict stage preserved"
}

scenario_initial_hidden_index_flag() {
  local flag="$1"
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha before="$SB_ROOT/hidden-before"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'advance\n' > UPSTREAM_NOTE"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  git -C "$work" update-index "--$flag" README.md
  printf 'preexisting hidden operator bytes\n' >"$work/README.md"
  install_contact_remotes "$work"
  capture_state "$work" "$before"
  git -C "$work" ls-files -v -z >"$SB_ROOT/flags-before"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 1 "preexisting $flag"
  grep -F 'index has assume-unchanged or skip-worktree flags' "$SYNC_LOG" >/dev/null || fail "hidden index error missing"
  assert_state_unchanged "$work" "$before"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v -z) || fail "preexisting index flag changed"
  [[ ! -s "$SB_ROOT/git-contact" && ! -s "$HOOK_LOG" ]] || fail "preexisting hidden flag contacted a remote"
  run_sync "$work" --allow-dirty --push
  assert_rc 1 "allow-dirty preexisting $flag"
  assert_state_unchanged "$work" "$before"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v -z) || fail "allow-dirty changed hidden flag"
  [[ ! -s "$SB_ROOT/git-contact" && ! -s "$HOOK_LOG" ]] || fail "allow-dirty bypassed hidden flag refusal"
  assert_eq "$(cat "$work/README.md")" "preexisting hidden operator bytes" "$flag hidden bytes retained"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "$flag local fork retained"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "$flag local main retained"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$flag remote fork retained"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "$flag remote main retained"
  run_sync "$work" --dry-run
  assert_rc 0 "dry-run with $flag"
  assert_state_unchanged "$work" "$before"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v -z) || fail "dry-run changed hidden flag"
  [[ ! -s "$SB_ROOT/git-contact" && ! -s "$HOOK_LOG" ]] || fail "dry-run with hidden flag contacted remote"
  say "preexisting $flag refused before fetch"
}

scenario_fetch_hidden_index_flag() {
  local flag="$1"
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'advance\n' > UPSTREAM_NOTE"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  cat >"$SB_ROOT/set-flag-upload-pack" <<EOF
#!/bin/bash
set -euo pipefail
git -C "$work" update-index --$flag README.md
printf changed >"$SB_ROOT/fetch-flag"
git -C "$work" ls-files -v -z >"$SB_ROOT/fetch-flags"
exec /usr/bin/git-upload-pack "\$@"
EOF
  chmod +x "$SB_ROOT/set-flag-upload-pack"
  git -C "$work" config remote.upstream.uploadpack "$SB_ROOT/set-flag-upload-pack"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 1 "fetch changes $flag"
  [[ -s "$SB_ROOT/fetch-flag" ]] || fail "native upload-pack did not set hidden flag"
  grep -F 'changed during fetch' "$SYNC_LOG" >/dev/null || fail "fetch hidden flag change not detected"
  cmp -s "$SB_ROOT/fetch-flags" <(git -C "$work" ls-files -v -z) || fail "fetch-created hidden flag discarded"
  assert_eq "$(cat "$work/README.md")" "base" "fetch flag worktree unchanged"
  assert_eq "$(git -C "$work" show :README.md)" "base" "fetch flag index bytes unchanged"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "fetch flag local fork unchanged"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "fetch flag local main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "fetch flag remote fork unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "fetch flag remote main unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "push ran after fetch-created hidden flag"
  no_rebase_left "$work"
  say "native fetch $flag change preserved and refused"
}

scenario_checkout_hidden_index_flag() {
  local flag="$1"
  new_sandbox
  local work="$SB_ROOT/work" tip main_sha
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'advance\n' > UPSTREAM_NOTE"
  tip="$(git -C "$work" rev-parse jkubo)"
  main_sha="$(git -C "$work" rev-parse main)"
  git -C "$work" checkout -qb operator
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
set -euo pipefail
if [[ "\$(git symbolic-ref -q HEAD || true)" == refs/heads/jkubo && ! -e "$SB_ROOT/checkout-flag" ]]; then
  printf 'ordinary hook hidden tracked bytes\n' > README.md
  git update-index --$flag README.md
  printf changed >"$SB_ROOT/checkout-flag"
  git ls-files -v -z >"$SB_ROOT/checkout-flags"
fi
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 1 "post-checkout sets $flag and edits bytes"
  [[ -s "$SB_ROOT/checkout-flag" ]] || fail "post-checkout hidden flag hook did not run"
  grep -F 'changed during checkout' "$SYNC_LOG" >/dev/null || fail "checkout hidden flag was adopted"
  cmp -s "$SB_ROOT/checkout-flags" <(git -C "$work" ls-files -v -z) || fail "checkout-created hidden flag discarded"
  assert_eq "$(cat "$work/README.md")" "ordinary hook hidden tracked bytes" "checkout hidden bytes retained"
  assert_eq "$(git -C "$work" show :README.md)" "base" "checkout index bytes retained"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" "foreign checkout retained"
  assert_eq "$(git -C "$work" rev-parse operator)" "$tip" "starting operator ref retained"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "checkout hidden flag fork ref retained"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_sha" "checkout hidden flag main ref retained"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "checkout hidden flag remote fork retained"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$main_sha" "checkout hidden flag remote main retained"
  [[ ! -s "$HOOK_LOG" ]] || fail "push ran after checkout hidden flag"
  no_rebase_left "$work"
  say "post-checkout $flag byte edit preserved and refused"
}

# Clean conversion can make diff hide foreign raw conflict bytes. The normal
# filter and index hook run unchanged; compare exact file/index snapshots.
scenario_clean_filter_conflict() {
  local mode="$1" foreign="$2"
  new_sandbox
  local work="$SB_ROOT/work" tip origin_main
  seed_fork "$work"
  cat >"$SB_ROOT/clean-note" <<'EOF'
#!/bin/bash
sed '/^OPERATOR_LOCAL_NOTE /d'
EOF
  chmod +x "$SB_ROOT/clean-note"
  git -C "$work" config filter.local-note.clean "$SB_ROOT/clean-note"
  git -C "$work" config filter.local-note.smudge cat
  printf 'README.md filter=local-note\n' >"$work/.gitattributes"
  commit_tree "$work" "ordinary clean filter attributes"
  printf 'fork-filter-conflict\n' >"$work/README.md"
  commit_tree "$work" "fork filtered conflict"
  tip="$(git -C "$work" rev-parse jkubo)"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  advance_upstream "$work" bash -c "printf 'upstream-filter-conflict\n' > README.md"
  if [[ "$foreign" == yes ]]; then
    cat >"$work/.git/hooks/post-index-change" <<EOF
#!/bin/bash
set -euo pipefail
if [[ -d .git/rebase-merge && ! -e "$SB_ROOT/filter-hook" && -n "\$(git ls-files -u)" ]]; then
  printf changed >"$SB_ROOT/filter-hook"
  git ls-files --stage -z >"$SB_ROOT/original-index"
  cp README.md "$SB_ROOT/original-conflict-bytes"
  printf 'OPERATOR_LOCAL_NOTE unique uncommitted conflict work\n' >> README.md
  cp README.md "$SB_ROOT/foreign-conflict-bytes"
  git ls-files --stage -z >"$SB_ROOT/foreign-index"
fi
EOF
    chmod +x "$work/.git/hooks/post-index-change"
  fi
  cp "$work/README.md" "$SB_ROOT/before-replay-raw"
  git -C "$work" ls-files --stage -z >"$SB_ROOT/before-replay-stages"
  git -C "$work" ls-files -v -z >"$SB_ROOT/before-replay-flags"
  capture_state "$work" "$SB_ROOT/state-before"
  install_hook "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  assert_rc 1 "$mode ordinary filtered conflict ($foreign)"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" "$mode filtered refusal kept attached symbolic HEAD"
  assert_state_unchanged "$work" "$SB_ROOT/state-before"
  cmp -s "$SB_ROOT/before-replay-flags" <(git -C "$work" ls-files -v -z) || fail "$mode unsupported transform index flags changed"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "$mode filtered conflict named fork kept"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode filtered conflict remote fork unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "$mode filtered conflict remote main unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode push hook ran during filtered conflict"
  [[ ! -e "$SB_ROOT/filter-hook" ]] || fail "$mode unsupported transform reached native conflict hook"
  cmp -s "$SB_ROOT/before-replay-raw" "$work/README.md" || fail "$mode unsupported transform raw input changed"
  cmp -s "$SB_ROOT/before-replay-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode unsupported transform index stages changed"
  no_rebase_left "$work"
  assert_eq "$(cat "$work/README.md")" "fork-filter-conflict" "$mode unsupported transform original bytes kept"
  grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null || fail "$mode transform refusal missing"
  if [[ "$foreign" == yes ]]; then
    say "$mode filtered conflict hook prospectively refused; original input preserved"
  else
    say "$mode filtered owned-conflict input prospectively refused"
  fi
}

# A valid operator todo instruction is independent work even while the index
# and raw conflict bytes still match Git. A read-only observer snapshots the
# fully paused operation after the actual native rebase process exits.
scenario_operator_todo_conflict() {
  local mode="$1" work tip origin_main before_refs
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  printf 'fork-todo-conflict\n' >"$work/README.md"
  commit_tree "$work" "fork todo conflict"
  tip="$(git -C "$work" rev-parse jkubo)"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  advance_upstream "$work" bash -c "printf 'upstream-todo-conflict\n' > README.md"
  before_refs="$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  cat >"$work/.git/hooks/post-index-change" <<EOF
#!/bin/bash
set -euo pipefail
if [[ -d .git/rebase-merge && ! -e "$SB_ROOT/todo-hook" && -n "\$(git ls-files -u)" ]]; then
  printf changed >"$SB_ROOT/todo-hook"
  cp .git/rebase-merge/git-rebase-todo "$SB_ROOT/original-todo"
  printf 'exec printf operator-sequencer-note > "$SB_ROOT/operator-exec-ran"\n' >>.git/rebase-merge/git-rebase-todo
  cp .git/rebase-merge/git-rebase-todo "$SB_ROOT/operator-todo"
  git ls-files --stage -z >"$SB_ROOT/operator-stages"
  cp README.md "$SB_ROOT/operator-conflict"
  python3 "$SB_ROOT/operation-snapshot.py" "\$PPID" >"$SB_ROOT/snapshot-log" 2>&1 </dev/null &
fi
EOF
  chmod +x "$work/.git/hooks/post-index-change"
  cat >"$SB_ROOT/operation-snapshot.py" <<EOF
import os, pathlib, shutil, sys, time
parent=int(sys.argv[1])
while True:
    try: os.kill(parent,0)
    except ProcessLookupError: break
    time.sleep(0.005)
root=pathlib.Path("$SB_ROOT"); gd=pathlib.Path('.git')
assert (gd/'rebase-merge/stopped-sha').is_file()
saved=root/'paused-operation';saved.mkdir()
shutil.copytree(gd/'rebase-merge',saved/'rebase-merge')
for path in gd.iterdir():
    if path.name[0].isupper() and path.name not in ('FETCH_HEAD','COMMIT_EDITMSG'):
        shutil.copy2(path,saved/path.name)
shutil.copy2(gd/'index',root/'paused-index')
(root/'paused-state').write_text('captured')
EOF
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  assert_rc 1 "$mode operator todo conflict"
  local attempt
  for attempt in {1..1000}; do [[ -e "$SB_ROOT/paused-state" ]] && break; sleep 0.005; done
  [[ -s "$SB_ROOT/todo-hook" && -s "$SB_ROOT/paused-state" ]] || fail "$mode real hook or paused-state snapshot missing"
  cmp -s "$SB_ROOT/operator-todo" <(cat "$SB_ROOT/original-todo"; printf 'exec printf operator-sequencer-note > "%s/operator-exec-ran"\n' "$SB_ROOT") || fail "$mode valid single exec fixture missing"
  [[ ! -e "$SB_ROOT/operator-exec-ran" ]] || fail "$mode operator todo was executed"
  cmp -s "$SB_ROOT/operator-todo" "$work/.git/rebase-merge/git-rebase-todo" || fail "$mode operator todo discarded"
  cmp -s "$SB_ROOT/operator-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode original index stages changed"
  cmp -s "$SB_ROOT/paused-index" "$work/.git/index" || fail "$mode paused index bytes changed"
  cmp -s "$SB_ROOT/operator-conflict" "$work/README.md" || fail "$mode raw conflict file changed"
  mkdir "$SB_ROOT/final-operation"
  cp -a "$work/.git/rebase-merge" "$SB_ROOT/final-operation/"
  while IFS= read -r -d '' path; do
    cp -a -- "$path" "$SB_ROOT/final-operation/"
  done < <(find "$work/.git" -mindepth 1 -maxdepth 1 -name '[A-Z]*' ! -name FETCH_HEAD ! -name COMMIT_EDITMSG -print0)
  diff -r --no-dereference "$SB_ROOT/paused-operation" "$SB_ROOT/final-operation" >/dev/null || fail "$mode full operation entry bytes changed"
  cmp -s <(find "$SB_ROOT/paused-operation" -printf '%P\t%y\t%m\0' | sort -z) <(find "$SB_ROOT/final-operation" -printf '%P\t%y\t%m\0' | sort -z) || fail "$mode operation entry types or modes changed"
  assert_eq "$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "$before_refs" "$mode all named heads preserved"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode remote fork unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "$mode remote main unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode push hook ran during todo refusal"
  grep -F 'failed rebase state is not owned' "$SYNC_LOG" >/dev/null || fail "$mode operator operation adopted"
  say "$mode valid operator todo and full paused state preserved"
}


# Normal checkout hooks and clean filters can hide staged raw changes. Capture
# exact foreign state; a no-edit ordinary-hook control still completes.
scenario_raw_checkout_filter() {
  local mode="$1" foreign="$2" work tip before_heads origin_main
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  advance_upstream "$work" bash -c "printf 'upstream-raw-checkout\n' > README.md"
  git -C "$work" checkout -qb operator
  before_heads="$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  cat >"$SB_ROOT/normal-clean" <<EOF
#!/bin/bash
printf filtered >>"$SB_ROOT/filter-called"
sed '/^OPERATOR_LOCAL_NOTE /d'
EOF
  chmod +x "$SB_ROOT/normal-clean"
  git -C "$work" config filter.operator.clean "$SB_ROOT/normal-clean"
  git -C "$work" config filter.operator.smudge cat
  if [[ "$foreign" == yes ]]; then
    printf 'README.md filter=operator\n' >"$work/.git/info/attributes"
  else
    printf 'INACTIVE_FILTER_PATH filter=operator\n' >"$work/.git/info/attributes"
  fi
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
set -euo pipefail
if [[ "\$(git symbolic-ref -q HEAD || true)" == refs/heads/jkubo && ! -e "$SB_ROOT/checkout-hook" ]]; then
  printf observed >"$SB_ROOT/checkout-hook"
  if [[ "$foreign" == yes ]]; then
    printf 'OPERATOR_LOCAL_NOTE unique uncommitted checkout work\n' >>README.md
  fi
  cp README.md "$SB_ROOT/hook-raw"
  git diff --binary >"$SB_ROOT/hook-diff"
  git add README.md
  cp .git/index "$SB_ROOT/hook-index"
  git ls-files --stage -z >"$SB_ROOT/hook-stages"
fi
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$mode normal checkout hook did not run"
  if [[ "$foreign" == yes ]]; then
    [[ -s "$SB_ROOT/filter-called" ]] || fail "$mode active ordinary filter did not run"
  else
    [[ ! -e "$SB_ROOT/filter-called" ]] || fail "$mode genuinely inactive filter ran"
    local tree
    for tree in operator jkubo main; do
      [[ -z "$(git -C "$work" ls-tree -r --name-only "$tree" -- INACTIVE_FILTER_PATH)" ]] || fail "$mode inactive path was tracked"
    done
  fi
  [[ ! -s "$SB_ROOT/hook-diff" ]] || fail "$mode ordinary filter did not produce normalized clean diff"
  if [[ "$foreign" == yes ]]; then
    assert_rc 1 "$mode foreign raw checkout"
    cmp -s "$SB_ROOT/hook-raw" "$work/README.md" || fail "$mode hidden raw checkout bytes discarded"
    cmp -s "$SB_ROOT/hook-index" "$work/.git/index" || fail "$mode hidden raw checkout index bytes changed"
    cmp -s "$SB_ROOT/hook-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode hidden raw checkout index stages changed"
    git -C "$work" diff --quiet && git -C "$work" diff --cached --quiet || fail "$mode normalized fixture is not clean"
    assert_eq "$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "$before_heads" "$mode all named heads preserved"
    assert_eq "$(git -C "$work" symbolic-ref HEAD)" refs/heads/jkubo "$mode foreign current checkout retained"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "$mode remote main unchanged"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode remote fork unchanged"
    [[ ! -s "$HOOK_LOG" ]] || fail "$mode publication attempted after raw checkout change"
    grep -F 'changed during checkout' "$SYNC_LOG" >/dev/null || fail "$mode raw checkout refusal missing"
    no_rebase_left "$work"
    say "$mode clean-filter staged foreign raw checkout preserved"
  else
    assert_rc 0 "$mode ordinary clean raw checkout control"
    assert_eq "$(git -C "$work" symbolic-ref HEAD)" refs/heads/operator "$mode control returned to operator"
    if [[ "$mode" == push ]]; then
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "$mode control mirror published"
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$(git -C "$work" rev-parse jkubo)" "$mode control replay published"
      [[ -s "$HOOK_LOG" ]] || fail "$mode control push hook did not run"
    else
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" "$mode control remote main unchanged"
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode control remote fork unchanged"
    fi
    say "$mode genuinely inactive filter raw ownership control"
  fi
}

scenario_ignored_target_collision() {
  new_sandbox
  local work="$SB_ROOT/work" tip before_heads
  seed_fork "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  advance_upstream "$work" bash -c "printf 'upstream owned target\n' > IGNORED_COLLISION"
  printf 'IGNORED_COLLISION\n' >"$work/.git/info/exclude"
  printf 'operator ignored local bytes\n' >"$work/IGNORED_COLLISION"
  cp "$work/IGNORED_COLLISION" "$SB_ROOT/ignored-bytes"
  before_heads="$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  install_hook "$work"
  run_sync "$work" --push
  assert_rc 1 "ignored replay target collision"
  cmp -s "$SB_ROOT/ignored-bytes" "$work/IGNORED_COLLISION" || fail "ignored operator target was overwritten"
  assert_eq "$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "$before_heads" "ignored collision named heads unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "ignored collision remote main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "ignored collision remote fork unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "ignored collision publication attempted"
  no_rebase_left "$work"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" "ignored collision kept attached symbolic HEAD"
  say "ignored upstream target bytes preserved before replay"
}


# Active filters cannot be inspected between a pre-rebase hook and Git's own
# reset. Refuse that input before native replay; unfiltered native refusal
# still executes the exact staged-note hook and preserves its foreign work.
scenario_prerebase_raw_policy() {
  local mode="$1" filtered="$2" work tip before_heads
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  advance_upstream "$work" bash -c "printf 'upstream-prerebase\n' > README.md"
  git -C "$work" checkout -qb operator
  before_heads="$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  cp "$work/README.md" "$SB_ROOT/initial-raw"
  git -C "$work" ls-files --stage -z >"$SB_ROOT/initial-stages"
  git -C "$work" ls-files -v -z >"$SB_ROOT/initial-flags"
  if [[ "$filtered" == yes ]]; then
    cat >"$SB_ROOT/prerebase-clean" <<'EOF'
#!/bin/bash
sed '/^OPERATOR_LOCAL_NOTE /d'
EOF
    chmod +x "$SB_ROOT/prerebase-clean"
    git -C "$work" config filter.operator.clean "$SB_ROOT/prerebase-clean"
    git -C "$work" config filter.operator.smudge cat
    printf 'README.md filter=operator\n' >"$work/.git/info/attributes"
  fi
  cat >"$work/.git/hooks/pre-rebase" <<EOF
#!/bin/bash
set -euo pipefail
printf observed >"$SB_ROOT/prerebase-hook"
printf 'OPERATOR_LOCAL_NOTE unique pre-rebase staged raw work\n' >>README.md
cp README.md "$SB_ROOT/hook-raw"
git add README.md
git ls-files --stage -z >"$SB_ROOT/hook-stages"
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-rebase"
  install_hook "$work"
  capture_state "$work" "$SB_ROOT/state-before"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  assert_rc 1 "$mode prerebase raw policy $filtered"
  if [[ "$filtered" == yes ]]; then
    [[ ! -e "$SB_ROOT/prerebase-hook" ]] || fail "$mode unsupported native filtered hook was reached"
    cmp -s "$SB_ROOT/initial-raw" "$work/README.md" || fail "$mode unsupported initial raw state changed"
    cmp -s "$SB_ROOT/initial-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode unsupported initial index changed"
    cmp -s "$SB_ROOT/initial-flags" <(git -C "$work" ls-files -v -z) || fail "$mode unsupported initial index flags changed"
    assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$mode filtered prerebase kept attached symbolic HEAD"
    assert_state_unchanged "$work" "$SB_ROOT/state-before"
    grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null || fail "$mode prerebase transform refusal missing"
    say "$mode active-filter pre-rebase input prospectively refused"
  else
    [[ -s "$SB_ROOT/prerebase-hook" ]] || fail "$mode unfiltered normal prerebase hook did not run"
    cmp -s "$SB_ROOT/hook-raw" "$work/README.md" || fail "$mode unfiltered foreign raw work lost"
    cmp -s "$SB_ROOT/hook-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode unfiltered foreign staged work lost"
    say "$mode unfiltered native pre-rebase staged work preserved"
  fi
  assert_eq "$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "$before_heads" "$mode prerebase named heads preserved"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode prerebase remote main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode prerebase remote fork unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode prerebase publication attempted"
}

# A replay can create and remove a path that neither final tip contains.
# Existing ignored bytes must be refused before that intermediate checkout.
scenario_intermediate_replay_target() {
  local mode="$1" foreign="$2" work introduced tip before_heads
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  printf 'fork tracked transient bytes\n' >"$work/TRANSIENT_TARGET"
  commit_tree "$work" "introduce transient replay target"
  introduced="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" rm -q TRANSIENT_TARGET
  commit_tree "$work" "remove transient replay target"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  advance_upstream "$work" bash -c "printf 'upstream history advance\n' > UPSTREAM_HISTORY"
  [[ -n "$(git -C "$work" ls-tree -r --name-only "$introduced" -- TRANSIENT_TARGET)" ]] || fail "$mode intermediate target missing"
  [[ -z "$(git -C "$work" ls-tree -r --name-only "$tip" -- TRANSIENT_TARGET)" ]] || fail "$mode target present at final fork tip"
  [[ -z "$(git -C "$work" ls-tree -r --name-only "$UP_SHA" -- TRANSIENT_TARGET)" ]] || fail "$mode target present at upstream tip"
  if [[ "$foreign" == yes ]]; then
    printf 'TRANSIENT_TARGET\n' >"$work/.git/info/exclude"
    printf 'unique operator ignored transient path bytes\n' >"$work/TRANSIENT_TARGET"
    cp "$work/TRANSIENT_TARGET" "$SB_ROOT/operator-transient"
    git -C "$work" check-ignore -q TRANSIENT_TARGET || fail "$mode operator target not ignored"
  fi
  before_heads="$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  git -C "$work" ls-files --stage -z >"$SB_ROOT/initial-stages"
  git -C "$work" ls-files -v -z >"$SB_ROOT/initial-flags"
  cp "$work/.git/index" "$SB_ROOT/initial-index"
  capture_state "$work" "$SB_ROOT/state-before"
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  no_rebase_left "$work"
  if [[ "$foreign" == yes ]]; then
    assert_rc 1 "$mode intermediate ignored replay target"
    cmp -s "$SB_ROOT/operator-transient" "$work/TRANSIENT_TARGET" || fail "$mode intermediate operator bytes lost"
    cmp -s "$SB_ROOT/initial-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode intermediate initial stages changed"
    cmp -s "$SB_ROOT/initial-flags" <(git -C "$work" ls-files -v -z) || fail "$mode intermediate initial index flags changed"
    cmp -s "$SB_ROOT/initial-index" "$work/.git/index" || fail "$mode intermediate initial index bytes changed"
    assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" "$mode intermediate refusal kept attached symbolic HEAD"
    assert_state_unchanged "$work" "$SB_ROOT/state-before"
    assert_eq "$(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "$before_heads" "$mode intermediate named heads changed"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode intermediate remote main unchanged"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode intermediate remote fork unchanged"
    [[ ! -s "$HOOK_LOG" ]] || fail "$mode intermediate refusal attempted publication"
    grep -F 'an intermediate replay target collides with local work or is uncertain' "$SYNC_LOG" >/dev/null || fail "$mode intermediate collision refusal missing"
    say "$mode ignored intermediate replay target bytes and state preserved"
  else
    assert_rc 0 "$mode owned intermediate replay control"
    git -C "$work" merge-base --is-ancestor "$UP_SHA" jkubo || fail "$mode intermediate control did not replay"
    assert_eq "$(git -C "$work" rev-parse main)" "$UP_SHA" "$mode intermediate control mirror exact"
    [[ ! -e "$work/TRANSIENT_TARGET" ]] || fail "$mode owned transient target left behind"
    [[ "$(git -C "$work" rev-parse jkubo)" != "$tip" ]] || fail "$mode native intermediate commits not replayed"
    if [[ "$mode" == push ]]; then
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "$mode intermediate control main published"
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$(git -C "$work" rev-parse jkubo)" "$mode intermediate control fork published"
      [[ -s "$HOOK_LOG" ]] || fail "$mode intermediate control native push hook missing"
    else
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode intermediate control main not published"
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode intermediate control fork not published"
    fi
    say "$mode owned intermediate target native replay control"
  fi
}

# Inherited text=auto eol=lf is known before checkout. Same-commit and ahead
# operator branches must be refused before symbolic HEAD moves or an
# operator-only tracked path is deleted. An ignored intermediate path is
# present so the refusal also leaves that operator input untouched.
scenario_normalized_start() {
  local mode="$1" placement="$2" work tip
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  printf '* text=auto eol=lf\n' >"$work/.gitattributes"
  git -C "$work" add -- .gitattributes
  commit_tree "$work" "inherited text=auto eol=lf"
  printf 'fork tracked transient bytes\n' >"$work/TRANSIENT_TARGET"
  commit_tree "$work" "introduce transient replay target"
  git -C "$work" rm -q -- TRANSIENT_TARGET
  commit_tree "$work" "remove transient replay target"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  advance_upstream "$work" bash -c "printf 'upstream-normalized\n' > UPSTREAM_NORM"
  if [[ "$placement" == ahead ]]; then
    git -C "$work" checkout -q -B operator
    printf 'operator-only raw bytes\n' >"$work/OPERATOR_ONLY"
    chmod 755 "$work/OPERATOR_ONLY"
    git -C "$work" add --chmod=+x -- OPERATOR_ONLY
    commit_tree "$work" "operator ahead of normalized fork"
  else
    git -C "$work" checkout -q -B operator
  fi
  printf 'TRANSIENT_TARGET\n' >"$work/.git/info/exclude"
  printf 'unique operator ignored transient path bytes\n' >"$work/TRANSIENT_TARGET"
  cp "$work/TRANSIENT_TARGET" "$SB_ROOT/operator-transient"
  git -C "$work" check-ignore -q -- TRANSIENT_TARGET || fail "$mode $placement operator target not ignored"
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
printf 'checked-out %s\n' "\$(git symbolic-ref -q HEAD || echo DETACHED)" >"$SB_ROOT/checkout-hook"
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  if [[ "$placement" == ahead ]]; then
    cp "$work/OPERATOR_ONLY" "$SB_ROOT/operator-only"
    git -C "$work" ls-files --stage -- OPERATOR_ONLY >"$SB_ROOT/operator-mode"
  fi
  git -C "$work" ls-files -v -z >"$SB_ROOT/initial-flags"
  capture_state "$work" "$SB_ROOT/state-before"
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  assert_rc 1 "$mode normalized start $placement"
  [[ ! -e "$SB_ROOT/checkout-hook" ]] || fail "$mode $placement checkout ran before transform refusal"
  cmp -s "$SB_ROOT/operator-transient" "$work/TRANSIENT_TARGET" || fail "$mode $placement ignored intermediate bytes lost"
  cmp -s "$SB_ROOT/initial-flags" <(git -C "$work" ls-files -v -z) || fail "$mode $placement index flags changed"
  if [[ "$placement" == ahead ]]; then
    cmp -s "$SB_ROOT/operator-only" "$work/OPERATOR_ONLY" || fail "$mode $placement operator-only bytes lost"
    cmp -s "$SB_ROOT/operator-mode" <(git -C "$work" ls-files --stage -- OPERATOR_ONLY) || fail "$mode $placement operator-only mode lost"
    [[ "$(git -C "$work" ls-files --stage -- OPERATOR_ONLY)" == 100755* ]] || fail "$mode $placement operator-only mode is not executable"
  fi
  assert_state_unchanged "$work" "$SB_ROOT/state-before"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$mode $placement symbolic HEAD moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$mode $placement fork ref moved"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode $placement remote fork published"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode $placement remote main published"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode $placement publication attempted"
  no_rebase_left "$work"
  grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null || fail "$mode $placement transform refusal missing"
  say "$mode normalized start $placement preserved symbolic HEAD and operator bytes"
}

# No normalization. An ignored path that exists only in an intermediate fork
# commit must stop the run before checkout deletes an ahead operator file.
scenario_precheckout_ignored_intermediate() {
  local mode="$1" work tip
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  printf 'fork tracked transient bytes\n' >"$work/TRANSIENT_TARGET"
  commit_tree "$work" "introduce transient replay target"
  git -C "$work" rm -q -- TRANSIENT_TARGET
  commit_tree "$work" "remove transient replay target"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin HEAD:refs/heads/jkubo
  advance_upstream "$work" bash -c "printf 'upstream history advance\n' > UPSTREAM_HISTORY"
  git -C "$work" checkout -q -B operator
  printf 'operator-only raw bytes\n' >"$work/OPERATOR_ONLY"
  chmod 755 "$work/OPERATOR_ONLY"
  git -C "$work" add --chmod=+x -- OPERATOR_ONLY
  commit_tree "$work" "operator ahead"
  printf 'TRANSIENT_TARGET\n' >"$work/.git/info/exclude"
  printf 'unique operator ignored transient path bytes\n' >"$work/TRANSIENT_TARGET"
  cp "$work/TRANSIENT_TARGET" "$SB_ROOT/operator-transient"
  cp "$work/OPERATOR_ONLY" "$SB_ROOT/operator-only"
  git -C "$work" ls-files --stage -- OPERATOR_ONLY >"$SB_ROOT/operator-mode"
  git -C "$work" ls-files -v -z >"$SB_ROOT/initial-flags"
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
printf observed >"$SB_ROOT/checkout-hook"
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  capture_state "$work" "$SB_ROOT/state-before"
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  assert_rc 1 "$mode precheckout ignored intermediate"
  [[ ! -e "$SB_ROOT/checkout-hook" ]] || fail "$mode intermediate collision ran checkout"
  cmp -s "$SB_ROOT/operator-transient" "$work/TRANSIENT_TARGET" || fail "$mode intermediate ignored bytes lost"
  cmp -s "$SB_ROOT/operator-only" "$work/OPERATOR_ONLY" || fail "$mode ahead tracked bytes lost before collision refusal"
  cmp -s "$SB_ROOT/operator-mode" <(git -C "$work" ls-files --stage -- OPERATOR_ONLY) || fail "$mode ahead mode lost"
  [[ "$(git -C "$work" ls-files --stage -- OPERATOR_ONLY)" == 100755* ]] || fail "$mode ahead mode is not executable"
  cmp -s "$SB_ROOT/initial-flags" <(git -C "$work" ls-files -v -z) || fail "$mode intermediate index flags changed"
  assert_state_unchanged "$work" "$SB_ROOT/state-before"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$mode collision symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$mode collision fork ref moved"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode collision remote fork"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode collision remote main"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode collision publication"
  no_rebase_left "$work"
  grep -F 'an intermediate replay target collides with local work or is uncertain' "$SYNC_LOG" >/dev/null || fail "$mode collision refusal missing"
  say "$mode ignored intermediate refused before checkout"
}

# Unfiltered operator branch: checkout, replay, and return still run in order.
scenario_operator_replay_positive() {
  local mode="$1" work tip
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  advance_upstream "$work" bash -c "printf 'upstream-positive\n' > UPSTREAM_POSITIVE"
  git -C "$work" checkout -q -B operator
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
if [[ "\$(git symbolic-ref -q HEAD || true)" == refs/heads/jkubo ]]; then
  printf observed >"$SB_ROOT/checkout-hook"
fi
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  assert_rc 0 "$mode operator replay positive"
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$mode positive owned checkout did not run"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$mode positive did not return to operator"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" jkubo || fail "$mode positive did not replay"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" "$mode positive mirror"
  if [[ "$mode" == push ]]; then
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "$mode positive main published"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$(git -C "$work" rev-parse refs/heads/jkubo)" "$mode positive fork published"
    [[ -s "$HOOK_LOG" ]] || fail "$mode positive push hook missing"
  else
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode positive main not published"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode positive fork not published"
    [[ ! -s "$HOOK_LOG" ]] || fail "$mode positive local run published"
  fi
  no_rebase_left "$work"
  say "$mode unfiltered operator checkout and replay positive"
}

# Identity clean/smudge on README. The same commit may check out so a normal
# post-checkout hook is observed, then refusal restores that symbolic HEAD and
# the captured state. An empty commit with the same tree and a different id is
# refused before checkout. Tree equality is not the exception.
scenario_filter_same_tree_start() {
  local mode="$1" placement="$2" work tip operator_commit
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  tip="$(git -C "$work" rev-parse jkubo)"
  advance_upstream "$work" bash -c "printf 'upstream-same-tree-filter\n' > UPSTREAM_FILTER"
  git -C "$work" checkout -q -B operator
  if [[ "$placement" == ahead ]]; then
    git -C "$work" commit -q --allow-empty -m "operator empty same tree"
  fi
  operator_commit="$(git -C "$work" rev-parse HEAD)"
  [[ "$(git -C "$work" rev-parse 'HEAD^{tree}')" == "$(git -C "$work" rev-parse 'jkubo^{tree}')" ]] \
    || fail "$mode $placement fixture trees diverged"
  if [[ "$placement" == ahead ]]; then
    [[ "$operator_commit" != "$tip" ]] || fail "$mode ahead fixture commit matches the fork"
    [[ "$(git -C "$work" rev-parse 'HEAD^')" == "$tip" ]] || fail "$mode ahead empty commit parent is not the fork"
  else
    [[ "$operator_commit" == "$tip" ]] || fail "$mode same fixture is not the fork commit"
  fi
  git -C "$work" config filter.identity.clean cat
  git -C "$work" config filter.identity.smudge cat
  printf 'README.md filter=identity\n' >"$work/.git/info/attributes"
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
printf 'checked-out %s\n' "\$(git symbolic-ref -q HEAD || echo DETACHED)" >"$SB_ROOT/checkout-hook"
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  cp "$work/README.md" "$SB_ROOT/initial-raw"
  git -C "$work" ls-files --stage -z >"$SB_ROOT/initial-stages"
  git -C "$work" ls-files -v -z >"$SB_ROOT/initial-flags"
  capture_state "$work" "$SB_ROOT/state-before"
  install_hook "$work"
  if [[ "$mode" == push ]]; then run_sync "$work" --push; else run_sync "$work"; fi
  assert_rc 1 "$mode identity filter $placement"
  cmp -s "$SB_ROOT/initial-raw" "$work/README.md" || fail "$mode $placement raw bytes changed"
  cmp -s "$SB_ROOT/initial-stages" <(git -C "$work" ls-files --stage -z) || fail "$mode $placement index stages changed"
  cmp -s "$SB_ROOT/initial-flags" <(git -C "$work" ls-files -v -z) || fail "$mode $placement index flags changed"
  assert_state_unchanged "$work" "$SB_ROOT/state-before"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$mode $placement symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" "$mode $placement HEAD commit moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" "$mode $placement operator ref moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$mode $placement fork ref moved"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" "$mode $placement remote fork published"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$mode $placement remote main published"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode $placement publication attempted"
  no_rebase_left "$work"
  if [[ "$placement" == same ]]; then
    [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$mode same post-checkout hook did not run"
    assert_eq "$(cat "$SB_ROOT/checkout-hook")" "checked-out refs/heads/jkubo" "$mode same hook did not observe the fork checkout"
    grep -F 'rebasing jkubo onto upstream/main' "$SYNC_LOG" >/dev/null \
      || fail "$mode same did not reach the fork checkout"
    grep -F 'restored symbolic HEAD to operator without a transforming checkout' "$SYNC_LOG" >/dev/null \
      || fail "$mode same symbolic HEAD restore missing"
    grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null \
      || fail "$mode same transform refusal missing"
    say "$mode same commit identity filter observed the hook and restored operator state"
  else
    [[ ! -e "$SB_ROOT/checkout-hook" ]] || fail "$mode ahead checkout ran before the filter refusal"
    if grep -F 'rebasing jkubo onto upstream/main' "$SYNC_LOG" >/dev/null; then
      fail "$mode ahead reached checkout"
    fi
    grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null \
      || fail "$mode ahead transform refusal missing"
    if grep -F 'restored symbolic HEAD' "$SYNC_LOG" >/dev/null; then
      fail "$mode ahead restored a foreign checkout"
    fi
    [[ "$(git -C "$work" rev-parse 'HEAD^{tree}')" == "$(git -C "$work" rev-parse 'jkubo^{tree}')" ]] \
      || fail "$mode ahead trees diverged during refusal"
    [[ "$(git -C "$work" rev-parse HEAD)" != "$tip" ]] || fail "$mode ahead HEAD collapsed onto the fork commit"
    say "$mode ahead same-tree identity filter refused before checkout"
  fi
}

# Tracked worktree bytes and modes. A semantic snapshot, not the binary index.
raw_manifest() {
  local work="$1" dest="$2" f mode hash
  while IFS= read -r -d '' f; do
    mode="$(stat -c '%a' -- "$work/$f")"
    hash="$(sha256sum -- "$work/$f" | awk '{print $1}')"
    printf '%s %s %s\n' "$mode" "$hash" "$f"
  done < <(git -C "$work" ls-files -z | sort -z) >"$dest"
}

install_mirror_checkout_hook() {
  local work="$1"
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
printf '%s %s\n' "\$(git symbolic-ref -q HEAD || echo DETACHED)" "\$2" >>"$SB_ROOT/checkout-hook"
EOF
  chmod +x "$work/.git/hooks/post-checkout"
}

# Missing local main whose fetched origin/main is an ancestor of upstream,
# or is that same commit. Create main from that pinned object.
absent_mirror_positive() {
  local mode="$1" relation="$2" work tip origin_main origin_jkubo
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  if [[ "$relation" == equal ]]; then
    git -C "$work" push -q origin "${UP_SHA}:refs/heads/main"
  elif [[ "$relation" != ancestor ]]; then
    fail "unknown missing-main relation $relation"
  fi
  git -C "$work" branch -D main >/dev/null
  origin_main="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_jkubo="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  tip="$(git -C "$work" rev-parse refs/heads/jkubo)"
  if ! git -C "$work" merge-base --is-ancestor "$origin_main" "$UP_SHA"; then
    fail "$mode $relation fixture origin/main is not an ancestor of upstream"
  fi
  if [[ "$relation" == equal ]]; then
    assert_eq "$origin_main" "$UP_SHA" "$mode equal origin/main"
  else
    [[ "$origin_main" != "$UP_SHA" ]] || fail "$mode ancestor fixture origin/main equals upstream"
  fi
  if git --git-dir="$SB_ROOT/origin.git" cat-file -e "${origin_main}:FORK.md" 2>/dev/null; then
    fail "$mode $relation origin/main contains fork delta"
  fi
  if git -C "$work" show-ref --verify --quiet refs/heads/main; then
    fail "$mode $relation local main still exists"
  fi
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" \
    "$mode $relation starts on jkubo"
  install_mirror_checkout_hook "$work"
  install_hook "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  assert_rc 0 "$mode $relation missing main"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" \
    "$mode $relation local main is upstream"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" \
    "$mode $relation returned to jkubo"
  assert_eq "$(git -C "$work" rev-parse 'jkubo^')" "$UP_SHA" \
    "$mode $relation rebased fork parent is upstream"
  assert_eq "$(git -C "$work" show jkubo:FORK.md)" "fork" \
    "$mode $relation fork file survived"
  assert_eq "$(git -C "$work" show jkubo:README.md)" "upstream-moved" \
    "$mode $relation fork picked up upstream README"
  cmp -s <(git -C "$work" show jkubo:scripts/sync-upstream.sh) "$REAL_SYNC" \
    || fail "$mode $relation rebased sync script bytes differ"
  if git -C "$work" cat-file -e "main:FORK.md" 2>/dev/null; then
    fail "$mode $relation main contains fork delta"
  fi
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$mode $relation mirror hook produced no record"
  grep -qx "refs/heads/main ${origin_main}" "$SB_ROOT/checkout-hook" \
    || fail "$mode $relation did not create main from the pinned origin object"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "$mode $relation changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$(git -C "$work" rev-parse jkubo)" \
    "$mode $relation evidence sha"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" "$mode $relation evidence main"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "$mode $relation evidence upstream"
  if [[ "$mode" == push ]]; then
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" \
      "$mode $relation origin/main published"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$(git -C "$work" rev-parse jkubo)" \
      "$mode $relation origin/jkubo published"
    assert_eq "$(grep -c '^hooked$' "$HOOK_LOG")" "1" \
      "$mode $relation one normal pre-push hook"
  else
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main" \
      "$mode $relation origin/main not published"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$origin_jkubo" \
      "$mode $relation origin/jkubo not published"
    [[ ! -s "$HOOK_LOG" ]] || fail "$mode $relation local run published"
  fi
  no_rebase_left "$work"
  say "$mode $relation missing main pinned and fast-forwarded"
}

# origin/main is not an ancestor of upstream and carries fork delta.
# Local main stays absent. Completed replay stays named.
absent_mirror_diverged() {
  local mode="$1" work tip rejected operator_commit replay
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  printf 'operator-note\n' >"$work/NOTE"
  chmod 755 "$work/NOTE"
  git -C "$work" add --chmod=+x -- NOTE
  git -C "$work" commit -q -m "operator note"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin "${tip}:refs/heads/jkubo"
  git -C "$work" push -q origin "${tip}:refs/heads/main"
  rejected="$(ref_sha "$SB_ROOT/origin.git" main)"
  assert_eq "$rejected" "$tip" "$mode diverged origin/main is the fork tip"
  if git -C "$work" merge-base --is-ancestor "$rejected" "$UP_SHA"; then
    fail "$mode diverged fixture origin/main is an ancestor of upstream"
  fi
  git --git-dir="$SB_ROOT/origin.git" cat-file -e "${rejected}:FORK.md" \
    || fail "$mode diverged fixture origin/main lacks fork delta"
  git --git-dir="$SB_ROOT/origin.git" cat-file -e "${rejected}:NOTE" \
    || fail "$mode diverged fixture origin/main lacks the operator note"
  git -C "$work" checkout -q -B operator
  operator_commit="$(git -C "$work" rev-parse HEAD)"
  assert_eq "$operator_commit" "$tip" "$mode diverged operator is the fork tip"
  git -C "$work" branch -D main >/dev/null
  if git -C "$work" show-ref --verify --quiet refs/heads/main; then
    fail "$mode diverged local main still exists"
  fi
  [[ -z "$(git -C "$work" status --porcelain=v1)" ]] \
    || fail "$mode diverged fixture is dirty before sync"
  raw_manifest "$work" "$SB_ROOT/raw-before"
  git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-before"
  git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-before"
  git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/origin-before"
  cp "$work/.git/index" "$SB_ROOT/index-before"
  if [[ -f "$work/.git/ORIG_HEAD" ]]; then
    cp "$work/.git/ORIG_HEAD" "$SB_ROOT/orig-before"
  fi
  install_mirror_checkout_hook "$work"
  install_hook "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  assert_rc 1 "$mode diverged missing main"
  if git -C "$work" show-ref --verify --quiet refs/heads/main; then
    fail "$mode diverged created local main"
  fi
  assert_eq "$(out_value main "$EVIDENCE")" "absent" "$mode diverged main evidence"
  grep -F "main sha=absent" "$SYNC_LOG" >/dev/null \
    || fail "$mode diverged log reported a main sha"
  grep -F "main is ${rejected} and upstream is ${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "$mode diverged ancestry refusal missing"
  grep -F "main is not an exact fast-forward of upstream" "$SYNC_LOG" >/dev/null \
    || fail "$mode diverged fast-forward refusal missing"
  replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$replay" != "$tip" ]] || fail "$mode diverged replay did not move jkubo"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" \
    || fail "$mode diverged replay does not contain upstream"
  assert_eq "$(git -C "$work" show "${replay}:README.md")" "upstream-moved" \
    "$mode diverged replay README"
  assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" \
    "$mode diverged replay kept fork delta"
  assert_eq "$(git -C "$work" show "${replay}:NOTE")" "operator-note" \
    "$mode diverged replay kept the note"
  git -C "$work" ls-tree "$replay" -- NOTE | grep -q '^100755 ' \
    || fail "$mode diverged replay NOTE is not executable"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$mode diverged symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" \
    "$mode diverged HEAD commit"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" \
    "$mode diverged operator ref"
  assert_eq "$(cat "$work/README.md")" "base" "$mode diverged operator README restored"
  assert_eq "$(cat "$work/NOTE")" "operator-note" "$mode diverged operator note restored"
  [[ "$(git -C "$work" ls-files --stage -- NOTE)" == 100755\ * ]] \
    || fail "$mode diverged NOTE index mode lost"
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" \
    || fail "$mode diverged raw bytes or modes changed"
  git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-after"
  cmp -s "$SB_ROOT/stages-before" "$SB_ROOT/stages-after" \
    || fail "$mode diverged index stages changed"
  git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-after"
  cmp -s "$SB_ROOT/flags-before" "$SB_ROOT/flags-after" \
    || fail "$mode diverged index flags changed"
  [[ -z "$(git -C "$work" status --porcelain=v1)" ]] \
    || fail "$mode diverged operator worktree left dirty"
  git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/origin-after"
  cmp -s "$SB_ROOT/origin-before" "$SB_ROOT/origin-after" \
    || fail "$mode diverged origin refs changed"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$rejected" \
    "$mode diverged origin/main unchanged"
  assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" \
    "$mode diverged origin/jkubo unchanged"
  [[ ! -s "$HOOK_LOG" ]] || fail "$mode diverged publication attempted"
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$mode diverged checkout hook produced no record"
  if grep -q '^refs/heads/main ' "$SB_ROOT/checkout-hook"; then
    fail "$mode diverged mirror creation hook ran"
  fi
  if grep -F "refs/heads/main ${rejected}" "$SB_ROOT/checkout-hook" >/dev/null; then
    fail "$mode diverged hook checked out the rejected origin commit"
  fi
  assert_eq "$(out_value changed "$EVIDENCE")" "true" \
    "$mode diverged completed replay is a real fork change"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" \
    "$mode diverged evidence sha is the replay"
  no_rebase_left "$work"
  # Native replay rewrites ORIG_HEAD and can rewrite the binary index.
  # Semantic stages, flags, and raw bytes are the retention proof above.
  if cmp -s "$SB_ROOT/index-before" "$work/.git/index"; then
    say "$mode diverged binary index unchanged"
  else
    say "$mode diverged binary index changed during native replay; semantic stages and flags matched"
  fi
  if [[ -f "$SB_ROOT/orig-before" && -f "$work/.git/ORIG_HEAD" ]] \
    && cmp -s "$SB_ROOT/orig-before" "$work/.git/ORIG_HEAD"; then
    say "$mode diverged ORIG_HEAD unchanged"
  else
    say "$mode diverged ORIG_HEAD changed during native replay; operator checkout was restored"
  fi
  say "$mode absent diverged main refused before mirror creation"
}

scenario_absent_diverged_main() {
  local mode="$1"
  absent_mirror_positive "$mode" ancestor
  absent_mirror_positive "$mode" equal
  absent_mirror_diverged "$mode"
}

# One fetched upstream commit is accepted before checkout. These hooks move
# only refs/remotes/upstream/main after that acceptance: post-checkout points
# it at the original fork tip, and post-rewrite points it at the rebased fork.
# The run must still replay onto the accepted commit, fast-forward main to
# that same commit, and report that commit. The tracking ref stays where the
# hook left it.
scenario_moved_upstream_ref() {
  local hook="$1" placement="$2" mode="$3"
  local work fork_before operator_commit origin_main_before origin_jkubo_before
  local replay git_dir name
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  printf 'operator-note\n' >"$work/NOTE"
  chmod 755 "$work/NOTE"
  git -C "$work" add --chmod=+x -- NOTE
  git -C "$work" commit -q -m "operator note"
  fork_before="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -B operator
  operator_commit="$(git -C "$work" rev-parse HEAD)"
  assert_eq "$operator_commit" "$fork_before" "$hook $placement $mode operator is the fork tip"
  [[ "$(git -C "$work" symbolic-ref HEAD)" == "refs/heads/operator" ]] \
    || fail "$hook $placement $mode start is not the operator branch"
  [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] \
    || fail "$hook $placement $mode NOTE type fixture"
  [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] \
    || fail "$hook $placement $mode NOTE mode fixture"
  git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/upstream-before"
  assert_eq "$(git --git-dir="$SB_ROOT/upstream.git" rev-parse refs/heads/main)" "$UP_SHA" \
    "$hook $placement $mode bare upstream is the accepted commit"
  origin_main_before="$(ref_sha "$SB_ROOT/origin.git" main)"
  origin_jkubo_before="$(ref_sha "$SB_ROOT/origin.git" jkubo)"
  git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/origin-before"
  raw_manifest "$work" "$SB_ROOT/raw-before"
  git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-before"
  git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-before"
  while IFS= read -r -d '' f; do
    printf '%s %s %s\n' "$(stat -c '%F' -- "$work/$f")" "$(stat -c '%a' -- "$work/$f")" "$f"
  done < <(git -C "$work" ls-files -z | sort -z) | sort >"$SB_ROOT/types-before"
  if [[ "$placement" == missing ]]; then
    git -C "$work" branch -D main >/dev/null
    if git -C "$work" show-ref --verify --quiet refs/heads/main; then
      fail "$hook $placement $mode local main still exists"
    fi
  elif [[ "$placement" == existing ]]; then
    git -C "$work" show-ref --verify --quiet refs/heads/main \
      || fail "$hook $placement $mode local main is missing"
    [[ "$(git -C "$work" rev-parse refs/heads/main)" != "$UP_SHA" ]] \
      || fail "$hook $placement $mode existing main is already upstream"
  else
    fail "unknown main placement $placement"
  fi
  if [[ "$hook" == postcheckout ]]; then
    cat >"$work/.git/hooks/post-checkout" <<HOOK
#!/bin/bash
if [[ -e "$SB_ROOT/hook-fired" ]]; then
  exit 0
fi
if [[ "\$(git symbolic-ref -q HEAD || true)" == refs/heads/jkubo && "\${3:-}" == 1 ]]; then
  git update-ref refs/remotes/upstream/main HEAD
  git rev-parse refs/remotes/upstream/main >"$SB_ROOT/mutated-to"
  printf 'fired\n' >"$SB_ROOT/hook-fired"
fi
exit 0
HOOK
    chmod +x "$work/.git/hooks/post-checkout"
  elif [[ "$hook" == postrewrite ]]; then
    cat >"$work/.git/hooks/post-rewrite" <<HOOK
#!/bin/bash
if [[ "\${1:-}" != rebase ]]; then
  exit 0
fi
git update-ref refs/remotes/upstream/main HEAD
git rev-parse refs/remotes/upstream/main >"$SB_ROOT/mutated-to"
printf 'fired\n' >"$SB_ROOT/hook-fired"
exit 0
HOOK
    chmod +x "$work/.git/hooks/post-rewrite"
  else
    fail "unknown upstream hook $hook"
  fi
  install_hook "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  elif [[ "$mode" == local ]]; then
    run_sync "$work"
  else
    fail "unknown sync mode $mode"
  fi
  assert_rc 0 "$hook $placement $mode moved upstream ref"
  [[ -s "$SB_ROOT/hook-fired" && -s "$SB_ROOT/mutated-to" ]] \
    || fail "$hook $placement $mode tracking ref hook did not run"
  replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" \
    || fail "$hook $placement $mode replay does not contain accepted upstream"
  assert_eq "$(git -C "$work" rev-parse "${replay}~2")" "$UP_SHA" \
    "$hook $placement $mode replay parent is not the accepted upstream"
  assert_eq "$(git -C "$work" show "${replay}:README.md")" "upstream-moved" \
    "$hook $placement $mode replay missed upstream README"
  assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" \
    "$hook $placement $mode replay lost fork delta"
  assert_eq "$(git -C "$work" show "${replay}:NOTE")" "operator-note" \
    "$hook $placement $mode replay lost operator note"
  git -C "$work" ls-tree "$replay" -- NOTE | grep -q '^100755 ' \
    || fail "$hook $placement $mode replay NOTE is not executable"
  cmp -s <(git -C "$work" show "${replay}:scripts/sync-upstream.sh") "$REAL_SYNC" \
    || fail "$hook $placement $mode replay script bytes differ"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" \
    "$hook $placement $mode local main is not the accepted upstream"
  git -C "$work" diff --exit-code "$UP_SHA" refs/heads/main >/dev/null \
    || fail "$hook $placement $mode main tree differs from accepted upstream"
  if git -C "$work" cat-file -e "main:FORK.md" 2>/dev/null; then
    fail "$hook $placement $mode main contains fork delta"
  fi
  if git -C "$work" cat-file -e "main:NOTE" 2>/dev/null; then
    fail "$hook $placement $mode main contains the operator note"
  fi
  if [[ "$hook" == postcheckout ]]; then
    assert_eq "$(cat "$SB_ROOT/mutated-to")" "$fork_before" \
      "$hook $placement $mode hook did not adopt the original fork"
    assert_eq "$(git -C "$work" rev-parse refs/remotes/upstream/main)" "$fork_before" \
      "$hook $placement $mode tracking ref was reset or reread"
  else
    assert_eq "$(cat "$SB_ROOT/mutated-to")" "$replay" \
      "$hook $placement $mode hook did not adopt the rebased fork"
    assert_eq "$(git -C "$work" rev-parse refs/remotes/upstream/main)" "$replay" \
      "$hook $placement $mode tracking ref was reset or reread"
  fi
  [[ "$(git -C "$work" rev-parse refs/remotes/upstream/main)" != "$UP_SHA" ]] \
    || fail "$hook $placement $mode tracking ref was not left mutated"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" \
    "$hook $placement $mode changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" \
    "$hook $placement $mode evidence fork"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" \
    "$hook $placement $mode evidence main"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" \
    "$hook $placement $mode evidence upstream"
  grep -F "fork sha=${replay} changed=true" "$SYNC_LOG" >/dev/null \
    || fail "$hook $placement $mode log fork evidence"
  grep -F "upstream sha=${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "$hook $placement $mode log upstream evidence"
  grep -F "main sha=${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "$hook $placement $mode log main evidence"
  grep -F "accepted upstream commit ${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "$hook $placement $mode did not accept the upstream commit"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$hook $placement $mode symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" \
    "$hook $placement $mode HEAD commit"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" \
    "$hook $placement $mode operator ref"
  assert_eq "$(cat "$work/NOTE")" "operator-note" \
    "$hook $placement $mode operator note bytes"
  [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] \
    || fail "$hook $placement $mode operator NOTE type"
  [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] \
    || fail "$hook $placement $mode operator NOTE mode"
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" \
    || fail "$hook $placement $mode operator raw bytes or modes changed"
  while IFS= read -r -d '' f; do
    printf '%s %s %s\n' "$(stat -c '%F' -- "$work/$f")" "$(stat -c '%a' -- "$work/$f")" "$f"
  done < <(git -C "$work" ls-files -z | sort -z) | sort >"$SB_ROOT/types-after"
  cmp -s "$SB_ROOT/types-before" "$SB_ROOT/types-after" \
    || fail "$hook $placement $mode operator type or mode changed"
  git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-after"
  cmp -s "$SB_ROOT/stages-before" "$SB_ROOT/stages-after" \
    || fail "$hook $placement $mode semantic index stages changed"
  git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-after"
  cmp -s "$SB_ROOT/flags-before" "$SB_ROOT/flags-after" \
    || fail "$hook $placement $mode semantic index flags changed"
  [[ -z "$(git -C "$work" status --porcelain=v1)" ]] \
    || fail "$hook $placement $mode operator worktree left dirty"
  no_rebase_left "$work"
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  for name in CHERRY_PICK_HEAD REVERT_HEAD MERGE_HEAD AUTO_MERGE; do
    [[ ! -e "$git_dir/$name" ]] || fail "$hook $placement $mode left $name"
  done
  [[ ! -d "$git_dir/sequencer" ]] || fail "$hook $placement $mode left sequencer"
  git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/upstream-after"
  cmp -s "$SB_ROOT/upstream-before" "$SB_ROOT/upstream-after" \
    || fail "$hook $placement $mode bare upstream refs changed"
  assert_eq "$(git --git-dir="$SB_ROOT/upstream.git" rev-parse refs/heads/main)" "$UP_SHA" \
    "$hook $placement $mode bare upstream main moved"
  if [[ "$mode" == push ]]; then
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" \
      "$hook $placement $mode origin/main is not the accepted upstream"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$replay" \
      "$hook $placement $mode origin/jkubo is not the uploaded fork"
    assert_eq "$(out_value sha "$EVIDENCE")" "$(ref_sha "$SB_ROOT/origin.git" jkubo)" \
      "$hook $placement $mode evidence sha is not the uploaded fork"
    assert_eq "$(grep -c '^hooked$' "$HOOK_LOG")" "1" \
      "$hook $placement $mode pre-push hook count"
  else
    git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
      >"$SB_ROOT/origin-after"
    cmp -s "$SB_ROOT/origin-before" "$SB_ROOT/origin-after" \
      || fail "$hook $placement $mode local run published origin"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$origin_main_before" \
      "$hook $placement $mode origin/main changed"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$origin_jkubo_before" \
      "$hook $placement $mode origin/jkubo changed"
    [[ ! -s "$HOOK_LOG" ]] || fail "$hook $placement $mode local run attempted publication"
    grep -F 'not pushed (pass --push)' "$SYNC_LOG" >/dev/null \
      || fail "$hook $placement $mode local run did not stay local"
  fi
  say "$hook $placement $mode accepted upstream kept despite moved tracking ref"
}

# Lightweight tag commit. Its payload path carries text/eol, so using this
# tree as a replay or return participant is an unsupported transform.
qualified_tag_commit() {
  local work="$1" path="$2" blob attrs tree
  blob="$(printf 'tag-body %s\n' "$path" | git -C "$work" hash-object -w --stdin)"
  attrs="$(printf '%s text eol=lf\n' "$path" | git -C "$work" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\t.gitattributes\n100644 blob %s\t%s\n' "$attrs" "$blob" "$path" | git -C "$work" mktree)"
  git -C "$work" commit-tree "$tree" -m "lightweight tag $path"
}

# Operator branch one commit ahead of jkubo, with an executable file jkubo
# does not contain. Prints the operator commit.
qualified_operator_note() {
  local work="$1"
  git -C "$work" checkout -q -B operator
  printf 'operator-note\n' >"$work/NOTE"
  chmod 755 "$work/NOTE"
  git -C "$work" add --chmod=+x -- NOTE
  git -C "$work" commit -q -m "operator note"
  if git -C "$work" cat-file -e "refs/heads/jkubo:NOTE" 2>/dev/null; then
    fail "operator note landed on jkubo"
  fi
  git -C "$work" rev-parse HEAD
}

qualified_replay_sha() {
  local work="$1" label="$2" replay
  replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" \
    || fail "$label replay does not contain the accepted upstream"
  assert_eq "$(git -C "$work" rev-parse "${replay}^")" "$UP_SHA" \
    "$label replay parent is not the accepted upstream"
  assert_eq "$(git -C "$work" show "${replay}:README.md")" "upstream-moved" \
    "$label replay README"
  assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" \
    "$label replay lost fork delta"
  if git -C "$work" cat-file -e "${replay}:NOTE" 2>/dev/null; then
    fail "$label replay contains the operator-only note"
  fi
  cmp -s <(git -C "$work" show "${replay}:scripts/sync-upstream.sh") "$REAL_SYNC" \
    || fail "$label replay script bytes differ"
  printf '%s\n' "$replay"
}

assert_operator_restored() {
  local work="$1" operator_commit="$2" label="$3"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$label symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" \
    "$label HEAD commit"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" \
    "$label operator ref"
  assert_eq "$(cat "$work/NOTE")" "operator-note" "$label operator note bytes"
  [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] \
    || fail "$label operator NOTE type"
  [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] \
    || fail "$label operator NOTE mode"
  [[ "$(git -C "$work" ls-files --stage -- NOTE)" == 100755\ * ]] \
    || fail "$label NOTE index mode lost"
  assert_eq "$(cat "$work/README.md")" "base" "$label operator README"
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" \
    || fail "$label operator raw bytes or modes changed"
  git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-after"
  cmp -s "$SB_ROOT/stages-before" "$SB_ROOT/stages-after" \
    || fail "$label semantic index stages changed"
  git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-after"
  cmp -s "$SB_ROOT/flags-before" "$SB_ROOT/flags-after" \
    || fail "$label semantic index flags changed"
  [[ -z "$(git -C "$work" status --porcelain=v1)" ]] \
    || fail "$label operator worktree left dirty"
  grep -qx "refs/heads/operator ${operator_commit}" "$SB_ROOT/checkout-hook" \
    || fail "$label observer did not record the attached operator return"
}

assert_qualified_tags_and_upstream() {
  local work="$1" label="$2"
  git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/tags | sort \
    >"$SB_ROOT/tags-after"
  cmp -s "$SB_ROOT/tags-before" "$SB_ROOT/tags-after" \
    || fail "$label tag refs changed"
  git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/upstream-after"
  cmp -s "$SB_ROOT/upstream-before" "$SB_ROOT/upstream-after" \
    || fail "$label bare upstream refs changed"
  assert_eq "$(git --git-dir="$SB_ROOT/upstream.git" rev-parse refs/heads/main)" "$UP_SHA" \
    "$label bare upstream main moved"
}

assert_qualified_publication() {
  local mode="$1" work="$2" label="$3" replay="$4"
  if [[ "$mode" == push ]]; then
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" \
      "$label origin/main is not the accepted upstream"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$replay" \
      "$label origin/jkubo is not the uploaded fork"
    assert_eq "$(out_value sha "$EVIDENCE")" "$(ref_sha "$SB_ROOT/origin.git" jkubo)" \
      "$label evidence sha is not the uploaded fork"
    assert_eq "$(grep -c '^hooked$' "$HOOK_LOG")" "1" \
      "$label pre-push hook count"
  else
    git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
      >"$SB_ROOT/origin-after"
    cmp -s "$SB_ROOT/origin-before" "$SB_ROOT/origin-after" \
      || fail "$label local run published origin"
    [[ ! -s "$HOOK_LOG" ]] || fail "$label local run attempted publication"
    grep -F 'not pushed (pass --push)' "$SYNC_LOG" >/dev/null \
      || fail "$label local run did not stay local"
  fi
}

# Static lightweight tags share names with the refs the script must use.
# upstream/main, operator, jkubo, main, and origin/main are real tags with
# different commits from the qualified heads or remote-tracking refs.
scenario_qualified_ref() {
  local name="$1" mode="$2"
  local work up fork_tip operator_commit="" start_branch qualified_origin=""
  local tag_oid="" hostile="" tag_jkubo="" tag_main="" replay label
  case "$name" in
    upstream_tag|operator_tag|heads_tags|origin_main_diverged_tag|origin_main_ancestor_tag|origin_main_equal_tag) ;;
    *) fail "unknown qualified-ref scenario $name" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown qualified-ref mode $mode" ;;
  esac
  label="$name $mode"
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > README.md"
  up="$UP_SHA"
  fork_tip="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$fork_tip" != "$up" ]] || fail "$label fixture fork tip is upstream"
  if git -C "$work" merge-base --is-ancestor "$fork_tip" "$up"; then
    fail "$label fixture fork tip is an ancestor of upstream"
  fi
  case "$name" in
    upstream_tag)
      operator_commit="$(qualified_operator_note "$work")"
      git -C "$work" tag upstream/main "$fork_tip"
      tag_oid="$fork_tip"
      [[ "$(git -C "$work" cat-file -t refs/tags/upstream/main)" == commit ]] \
        || fail "$label upstream tag is not lightweight"
      git -C "$work" cat-file -e "${tag_oid}:FORK.md" \
        || fail "$label upstream tag is not fork-bearing"
      start_branch="operator"
      ;;
    operator_tag)
      operator_commit="$(qualified_operator_note "$work")"
      hostile="$(qualified_tag_commit "$work" tag-operator-only)"
      git -C "$work" tag operator "$hostile"
      tag_oid="$hostile"
      assert_eq "$(git -C "$work" symbolic-ref --short HEAD 2>/dev/null)" "heads/operator" \
        "$label short symbolic ref was not heads/operator"
      assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
        "$label full symbolic ref"
      assert_eq "$(git -C "$work" rev-parse --verify refs/tags/operator^{commit})" "$hostile" \
        "$label operator tag commit"
      assert_eq "$(git -C "$work" rev-parse operator 2>/dev/null)" "$hostile" \
        "$label ambiguous operator name did not select the tag"
      [[ "$(git -C "$work" rev-parse 'refs/tags/operator^{tree}')" != "$(git -C "$work" rev-parse 'refs/heads/operator^{tree}')" ]] \
        || fail "$label operator tag tree matches the branch"
      start_branch="operator"
      ;;
    heads_tags)
      tag_jkubo="$(qualified_tag_commit "$work" tag-jkubo-only)"
      tag_main="$(qualified_tag_commit "$work" tag-main-only)"
      git -C "$work" tag jkubo "$tag_jkubo"
      git -C "$work" tag main "$tag_main"
      assert_eq "$(git -C "$work" symbolic-ref --short HEAD 2>/dev/null)" "heads/jkubo" \
        "$label short symbolic ref was not heads/jkubo"
      assert_eq "$(git -C "$work" rev-parse jkubo 2>/dev/null)" "$tag_jkubo" \
        "$label ambiguous jkubo did not select the tag"
      assert_eq "$(git -C "$work" rev-parse main 2>/dev/null)" "$tag_main" \
        "$label ambiguous main did not select the tag"
      [[ "$(git -C "$work" rev-parse 'refs/heads/jkubo^{tree}')" != "$(git -C "$work" rev-parse 'refs/tags/jkubo^{tree}')" ]] \
        || fail "$label jkubo tag tree matches the branch"
      [[ "$(git -C "$work" rev-parse 'refs/heads/main^{tree}')" != "$(git -C "$work" rev-parse 'refs/tags/main^{tree}')" ]] \
        || fail "$label main tag tree matches the branch"
      printf 'tag-jkubo-only\n' >>"$work/.git/info/exclude"
      printf 'tag-main-only\n' >>"$work/.git/info/exclude"
      printf 'collide-jkubo\n' >"$work/tag-jkubo-only"
      printf 'collide-main\n' >"$work/tag-main-only"
      start_branch="jkubo"
      ;;
    origin_main_diverged_tag)
      operator_commit="$(qualified_operator_note "$work")"
      git -C "$work" push -q origin "${fork_tip}:refs/heads/main"
      git -C "$work" fetch -q origin
      git -C "$work" branch -D main >/dev/null
      git -C "$work" tag origin/main "$up"
      hostile="$(qualified_tag_commit "$work" tag-operator-only)"
      git -C "$work" tag operator "$hostile"
      tag_oid="$up"
      qualified_origin="$(git -C "$work" rev-parse refs/remotes/origin/main)"
      assert_eq "$qualified_origin" "$fork_tip" "$label qualified origin is not the fork tip"
      if git -C "$work" merge-base --is-ancestor "$qualified_origin" "$up"; then
        fail "$label qualified origin is an ancestor of upstream"
      fi
      assert_eq "$(git -C "$work" rev-parse refs/tags/origin/main)" "$up" \
        "$label origin tag is not the acceptable upstream"
      git -C "$work" merge-base --is-ancestor refs/tags/origin/main "$up" \
        || fail "$label origin tag does not look acceptable"
      assert_eq "$(git -C "$work" symbolic-ref --short HEAD 2>/dev/null)" "heads/operator" \
        "$label short symbolic ref was not heads/operator"
      printf 'tag-operator-only\n' >>"$work/.git/info/exclude"
      printf 'collide-operator\n' >"$work/tag-operator-only"
      start_branch="operator"
      ;;
    origin_main_ancestor_tag)
      git -C "$work" branch -D main >/dev/null
      git -C "$work" tag origin/main "$fork_tip"
      tag_oid="$fork_tip"
      qualified_origin="$(git -C "$work" rev-parse refs/remotes/origin/main)"
      assert_eq "$qualified_origin" "$SEED_BASE" "$label qualified origin is not the ancestor"
      [[ "$qualified_origin" != "$up" ]] || fail "$label ancestor fixture equals upstream"
      git -C "$work" merge-base --is-ancestor "$qualified_origin" "$up" \
        || fail "$label qualified origin is not an ancestor"
      if git -C "$work" merge-base --is-ancestor "$tag_oid" "$up"; then
        fail "$label divergent origin tag is an ancestor"
      fi
      assert_eq "$(git -C "$work" rev-parse origin/main 2>/dev/null)" "$tag_oid" \
        "$label ambiguous origin/main did not select the tag"
      start_branch="jkubo"
      ;;
    origin_main_equal_tag)
      git -C "$work" push -q origin "${up}:refs/heads/main"
      git -C "$work" fetch -q origin
      git -C "$work" branch -D main >/dev/null
      git -C "$work" tag origin/main "$fork_tip"
      tag_oid="$fork_tip"
      qualified_origin="$(git -C "$work" rev-parse refs/remotes/origin/main)"
      assert_eq "$qualified_origin" "$up" "$label qualified origin is not upstream"
      if git -C "$work" merge-base --is-ancestor "$tag_oid" "$up"; then
        fail "$label divergent origin tag is an ancestor"
      fi
      assert_eq "$(git -C "$work" rev-parse origin/main 2>/dev/null)" "$tag_oid" \
        "$label ambiguous origin/main did not select the tag"
      start_branch="jkubo"
      ;;
  esac
  if [[ "$name" == origin_main_* ]]; then
    if git -C "$work" show-ref --verify --quiet refs/heads/main; then
      fail "$label local main still exists"
    fi
  fi
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/${start_branch}" \
    "$label start branch"
  [[ -z "$(git -C "$work" status --porcelain=v1)" ]] \
    || fail "$label fixture is dirty before sync"
  if [[ -n "$operator_commit" ]]; then
    raw_manifest "$work" "$SB_ROOT/raw-before"
    git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-before"
    git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-before"
  fi
  git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/tags | sort \
    >"$SB_ROOT/tags-before"
  git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/upstream-before"
  git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
    >"$SB_ROOT/origin-before"
  install_mirror_checkout_hook "$work"
  install_hook "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  if [[ "$name" == origin_main_diverged_tag ]]; then
    assert_rc 1 "$label"
    if git -C "$work" show-ref --verify --quiet refs/heads/main; then
      fail "$label created local main"
    fi
    grep -F "main is ${qualified_origin} and upstream is ${up}" "$SYNC_LOG" >/dev/null \
      || fail "$label did not refuse the qualified origin commit"
    grep -F "main is not an exact fast-forward of upstream" "$SYNC_LOG" >/dev/null \
      || fail "$label fast-forward refusal missing"
    if grep -F 'pushing main and jkubo' "$SYNC_LOG" >/dev/null; then
      fail "$label reached publication"
    fi
    replay="$(qualified_replay_sha "$work" "$label")"
    assert_operator_restored "$work" "$operator_commit" "$label"
    assert_eq "$(cat "$work/tag-operator-only")" "collide-operator" \
      "$label operator tag collision file changed"
    if git -C "$work" ls-files --error-unmatch -- tag-operator-only >/dev/null 2>&1; then
      fail "$label operator tag path became tracked"
    fi
    if grep -q '^refs/heads/main ' "$SB_ROOT/checkout-hook"; then
      fail "$label observer saw a main checkout"
    fi
    grep -qx "refs/heads/jkubo ${fork_tip}" "$SB_ROOT/checkout-hook" \
      || fail "$label observer did not see the attached fork checkout"
    assert_eq "$(out_value main "$EVIDENCE")" "absent" "$label main evidence"
    assert_eq "$(out_value upstream "$EVIDENCE")" "$up" "$label upstream evidence"
    assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "$label evidence sha"
    assert_eq "$(out_value changed "$EVIDENCE")" "true" "$label changed"
    [[ ! -s "$HOOK_LOG" ]] || fail "$label publication attempted"
    git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort \
      >"$SB_ROOT/origin-after"
    cmp -s "$SB_ROOT/origin-before" "$SB_ROOT/origin-after" \
      || fail "$label origin refs changed"
    assert_qualified_tags_and_upstream "$work" "$label"
    assert_eq "$(git -C "$work" rev-parse refs/tags/origin/main)" "$tag_oid" \
      "$label origin tag moved"
    assert_eq "$(git -C "$work" rev-parse refs/tags/operator)" "$hostile" \
      "$label operator tag moved"
    no_rebase_left "$work"
    say "$label refused the divergent qualified origin before creating main"
    return 0
  fi
  assert_rc 0 "$label"
  replay="$(qualified_replay_sha "$work" "$label")"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$up" \
    "$label local main is not the accepted upstream"
  if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
    fail "$label main contains fork delta"
  fi
  if git -C "$work" cat-file -e "refs/heads/main:NOTE" 2>/dev/null; then
    fail "$label main contains the operator note"
  fi
  grep -F "accepted upstream commit ${up}" "$SYNC_LOG" >/dev/null \
    || fail "$label did not accept the fetched upstream commit"
  grep -F "upstream sha=${up}" "$SYNC_LOG" >/dev/null \
    || fail "$label log upstream evidence"
  grep -F "main sha=${up}" "$SYNC_LOG" >/dev/null \
    || fail "$label log main evidence"
  grep -F "fork sha=${replay} changed=true" "$SYNC_LOG" >/dev/null \
    || fail "$label log fork evidence"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$up" "$label evidence upstream"
  assert_eq "$(out_value main "$EVIDENCE")" "$up" "$label evidence main"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "$label evidence sha"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "$label changed"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/${start_branch}" \
    "$label final branch"
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$label observer hook produced no record"
  if [[ -n "$operator_commit" ]]; then
    assert_operator_restored "$work" "$operator_commit" "$label"
    grep -qx "refs/heads/jkubo ${fork_tip}" "$SB_ROOT/checkout-hook" \
      || fail "$label observer did not see the attached fork checkout"
    grep -qx "refs/heads/main ${SEED_BASE}" "$SB_ROOT/checkout-hook" \
      || fail "$label observer did not see the attached main checkout"
  else
    grep -qx "refs/heads/jkubo ${replay}" "$SB_ROOT/checkout-hook" \
      || fail "$label observer did not see the attached return to jkubo"
    [[ -z "$(git -C "$work" status --porcelain=v1)" ]] \
      || fail "$label worktree left dirty"
  fi
  if [[ "$name" == heads_tags ]]; then
    grep -qx "refs/heads/main ${SEED_BASE}" "$SB_ROOT/checkout-hook" \
      || fail "$label observer did not see the attached main checkout"
    assert_eq "$(cat "$work/tag-jkubo-only")" "collide-jkubo" \
      "$label jkubo tag collision file changed"
    assert_eq "$(cat "$work/tag-main-only")" "collide-main" \
      "$label main tag collision file changed"
    if git -C "$work" ls-files --error-unmatch -- tag-jkubo-only >/dev/null 2>&1; then
      fail "$label jkubo tag path became tracked"
    fi
    if git -C "$work" cat-file -e "refs/heads/jkubo:tag-jkubo-only" 2>/dev/null; then
      fail "$label replay contains the jkubo tag path"
    fi
    if git -C "$work" cat-file -e "refs/heads/main:tag-main-only" 2>/dev/null; then
      fail "$label main contains the main tag path"
    fi
    assert_eq "$(git -C "$work" rev-parse refs/tags/jkubo)" "$tag_jkubo" \
      "$label jkubo tag moved"
    assert_eq "$(git -C "$work" rev-parse refs/tags/main)" "$tag_main" \
      "$label main tag moved"
  elif [[ "$name" == origin_main_ancestor_tag || "$name" == origin_main_equal_tag ]]; then
    grep -qx "refs/heads/main ${qualified_origin}" "$SB_ROOT/checkout-hook" \
      || fail "$label observer did not create main from the qualified origin"
    if grep -qx "refs/heads/main ${tag_oid}" "$SB_ROOT/checkout-hook"; then
      [[ "$tag_oid" == "$qualified_origin" ]] || fail "$label observer checked out the origin tag"
    fi
    assert_eq "$(git -C "$work" rev-parse refs/tags/origin/main)" "$tag_oid" \
      "$label origin tag moved"
  elif [[ "$name" == upstream_tag ]]; then
    assert_eq "$(git -C "$work" rev-parse refs/tags/upstream/main)" "$tag_oid" \
      "$label upstream tag moved"
    assert_eq "$(git -C "$work" rev-parse refs/remotes/upstream/main)" "$up" \
      "$label tracking ref is not the fetched upstream"
    [[ "$tag_oid" != "$up" ]] || fail "$label tag collapsed onto upstream"
  elif [[ "$name" == operator_tag ]]; then
    assert_eq "$(git -C "$work" rev-parse refs/tags/operator)" "$hostile" \
      "$label operator tag moved"
    if git -C "$work" ls-files --error-unmatch -- tag-operator-only >/dev/null 2>&1; then
      fail "$label operator tag path became tracked"
    fi
  fi
  assert_qualified_tags_and_upstream "$work" "$label"
  assert_qualified_publication "$mode" "$work" "$label" "$replay"
  no_rebase_left "$work"
  say "$label qualified refs"
}

write_types() {
  local work="$1" dest="$2" f
  while IFS= read -r -d '' f; do
    printf '%s %s %s\n' "$(stat -c '%F' -- "$work/$f")" "$(stat -c '%a' -- "$work/$f")" "$f"
  done < <(git -C "$work" ls-files -z | sort -z) | sort >"$dest"
}

record_operator_snapshot() {
  local work="$1"
  git -C "$work" ls-files -v | sort >"$SB_ROOT/flags-before"
  git -C "$work" ls-files --stage | sort >"$SB_ROOT/stages-before"
  cp "$work/.git/index" "$SB_ROOT/initial-index"
  git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort >"$SB_ROOT/heads-before"
  git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort >"$SB_ROOT/upstream-before"
  git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort >"$SB_ROOT/origin-before"
  raw_manifest "$work" "$SB_ROOT/raw-before"
  write_types "$work" "$SB_ROOT/types-before"
  capture_state "$work" "$SB_ROOT/state-before"
}

install_checkout_observer() {
  local work="$1"
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
printf '%s\n' "\$(git symbolic-ref -q HEAD || echo DETACHED)" >>"$SB_ROOT/checkout-hook"
EOF
  chmod +x "$work/.git/hooks/post-checkout"
}

attach_operator_note() {
  local work="$1"
  git -C "$work" checkout -q -B operator
  printf 'operator-note\n' >"$work/NOTE"
  chmod 755 "$work/NOTE"
  git -C "$work" add --chmod=+x -- NOTE
  commit_tree "$work" "operator note"
  if git -C "$work" cat-file -e "refs/heads/jkubo:NOTE" 2>/dev/null; then
    fail "operator note landed on the fork"
  fi
  git -C "$work" rev-parse HEAD
}

prove_merge_only_unique() {
  local work="$1" label="$2"
  local -a parents=()
  read -r -a parents <<<"$(git -C "$work" rev-list --parents -n 1 HEAD)"
  [[ ${#parents[@]} -eq 3 ]] || fail "$label is not a two-parent merge"
  git -C "$work" cat-file -e "HEAD:MERGE_ONLY" || fail "$label missing MERGE_ONLY"
  if git -C "$work" cat-file -e "HEAD^1:MERGE_ONLY" 2>/dev/null; then
    fail "$label parent 1 contains MERGE_ONLY"
  fi
  if git -C "$work" cat-file -e "HEAD^2:MERGE_ONLY" 2>/dev/null; then
    fail "$label parent 2 contains MERGE_ONLY"
  fi
  git -C "$work" cat-file blob "HEAD:MERGE_ONLY" >"$SB_ROOT/merge-only-blob"
  cmp -s "$work/MERGE_ONLY" "$SB_ROOT/merge-only-blob" || fail "$label worktree MERGE_ONLY differs from the merge"
}

assert_refusal_preserved() {
  local work="$1" label="$2"
  assert_state_unchanged "$work" "$SB_ROOT/state-before"
  cmp -s "$SB_ROOT/initial-index" "$work/.git/index" || fail "$label binary index changed"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v | sort) || fail "$label index flags changed"
  cmp -s "$SB_ROOT/stages-before" <(git -C "$work" ls-files --stage | sort) || fail "$label index stages changed"
  cmp -s "$SB_ROOT/heads-before" <(git -C "$work" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) || fail "$label local heads changed"
  cmp -s "$SB_ROOT/upstream-before" <(git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) || fail "$label bare upstream changed"
  cmp -s "$SB_ROOT/origin-before" <(git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) || fail "$label bare origin changed"
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" || fail "$label raw bytes changed"
  write_types "$work" "$SB_ROOT/types-after"
  cmp -s "$SB_ROOT/types-before" "$SB_ROOT/types-after" || fail "$label type or mode changed"
  [[ ! -e "$SB_ROOT/checkout-hook" ]] || fail "$label checkout observer ran"
  [[ ! -s "$HOOK_LOG" ]] || fail "$label pre-push ran"
  if grep -F 'rebasing' "$SYNC_LOG" >/dev/null; then
    fail "$label reached rebase"
  fi
  no_rebase_left "$work"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$label symbolic HEAD"
  assert_eq "$(cat "$work/NOTE")" "operator-note" "$label operator note"
  [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] || fail "$label NOTE type"
  [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] || fail "$label NOTE mode"
}

assert_operator_kept() {
  local work="$1" operator_commit="$2" label="$3"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" "$label symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" "$label HEAD"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" "$label operator ref"
  assert_eq "$(cat "$work/NOTE")" "operator-note" "$label operator note"
  [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] || fail "$label NOTE type"
  [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] || fail "$label NOTE mode"
  [[ "$(git -C "$work" ls-files --stage -- NOTE)" == 100755* ]] || fail "$label NOTE index mode"
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" || fail "$label operator raw changed"
  write_types "$work" "$SB_ROOT/types-after"
  cmp -s "$SB_ROOT/types-before" "$SB_ROOT/types-after" || fail "$label type or mode changed"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v | sort) || fail "$label index flags changed"
  cmp -s "$SB_ROOT/stages-before" <(git -C "$work" ls-files --stage | sort) || fail "$label index stages changed"
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$label checkout observer did not run"
  grep -qx 'refs/heads/jkubo' "$SB_ROOT/checkout-hook" || fail "$label observer missed the fork checkout"
  grep -qx 'refs/heads/operator' "$SB_ROOT/checkout-hook" || fail "$label observer missed the operator return"
  no_rebase_left "$work"
}

assert_publication() {
  local mode="$1" work="$2" label="$3" replay="$4" fork_before="$5"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "$label evidence upstream"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" "$label evidence main"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "$label evidence sha"
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "$label changed"
  grep -F "fork sha=${replay} changed=true" "$SYNC_LOG" >/dev/null || fail "$label log fork"
  grep -F "upstream sha=${UP_SHA}" "$SYNC_LOG" >/dev/null || fail "$label log upstream"
  grep -F "main sha=${UP_SHA}" "$SYNC_LOG" >/dev/null || fail "$label log main"
  grep -F "accepted upstream commit ${UP_SHA}" "$SYNC_LOG" >/dev/null || fail "$label accepted upstream"
  cmp -s "$SB_ROOT/upstream-before" <(git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
    || fail "$label bare upstream changed"
  if [[ "$mode" == push ]]; then
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$UP_SHA" "$label origin main"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$replay" "$label origin fork"
    assert_eq "$(out_value sha "$EVIDENCE")" "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$label uploaded sha"
    assert_eq "$(grep -c '^hooked$' "$HOOK_LOG")" "1" "$label pre-push count"
  else
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$SEED_BASE" "$label origin main moved"
    assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$fork_before" "$label origin fork moved"
    [[ ! -s "$HOOK_LOG" ]] || fail "$label local run published"
    grep -F 'not pushed (pass --push)' "$SYNC_LOG" >/dev/null || fail "$label stayed local"
  fi
}

# Exclusive fork merges are refused before checkout. A merge already contained
# in the accepted upstream still allows a linear exclusive fork replay.
scenario_merge_history() {
  local name="$1" mode="$2"
  local work merge fork_tip operator_commit replay drop listed
  case "$name" in
    exclusive_merge|common_merge) ;;
    *) fail "unknown merge-history scenario $name" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown merge-history mode $mode" ;;
  esac
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  if [[ "$name" == exclusive_merge ]]; then
    git -C "$work" checkout -q -B side "$SEED_BASE"
    printf 'side-parent\n' >"$work/SIDE_PARENT"
    commit_tree "$work" "side parent"
    git -C "$work" checkout -q jkubo
    git -C "$work" merge --no-ff --no-commit side
    printf 'unique-merge-only-payload\n' >"$work/MERGE_ONLY"
    commit_tree "$work" "exclusive fork merge"
    prove_merge_only_unique "$work" "$name"
    merge="$(git -C "$work" rev-parse HEAD)"
    git -C "$work" branch -D side >/dev/null
    git -C "$work" push -q origin "HEAD:refs/heads/jkubo"
    git -C "$work" fetch -q origin
    advance_upstream "$work" bash -c "printf 'upstream-advanced\n' > UPSTREAM_ADVANCE"
    fork_tip="$(git -C "$work" rev-parse refs/heads/jkubo)"
    assert_eq "$fork_tip" "$merge" "$name fork tip moved off the merge"
    assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$merge" "$name origin fork is not the merge"
    listed="$(git -C "$work" rev-list --merges "${UP_SHA}..${fork_tip}")" || fail "$name rev-list failed"
    assert_eq "$listed" "$merge" "$name merge missing from the exclusive range"
    if git -C "$work" merge-base --is-ancestor "$merge" "$UP_SHA"; then
      fail "$name exclusive merge is already in upstream"
    fi
    drop="$SB_ROOT/rebase-drop"
    git clone -q --no-hardlinks -b jkubo "$work" "$drop"
    git -C "$drop" config user.name "Jay Kubo"
    git -C "$drop" config user.email "6161465+jkubo@users.noreply.github.com"
    git -C "$drop" config commit.gpgsign false
    git -C "$drop" rebase -q "$UP_SHA" || fail "$name proof rebase failed"
    if git -C "$drop" cat-file -e "HEAD:MERGE_ONLY" 2>/dev/null; then
      fail "$name plain rebase kept MERGE_ONLY"
    fi
  else
    git -C "$work" checkout -q -B topic "$SEED_BASE"
    printf 'topic-side\n' >"$work/TOPIC_SIDE"
    commit_tree "$work" "topic side"
    git -C "$work" checkout -q -B upline "$SEED_BASE"
    printf 'upline-side\n' >"$work/UPLINE_SIDE"
    commit_tree "$work" "upline side"
    git -C "$work" merge --no-ff --no-commit topic
    printf 'unique-merge-only-payload\n' >"$work/MERGE_ONLY"
    commit_tree "$work" "shared upstream merge"
    prove_merge_only_unique "$work" "$name"
    merge="$(git -C "$work" rev-parse HEAD)"
    git -C "$work" push -q upstream "HEAD:refs/heads/main"
    UP_SHA="$merge"
    git -C "$work" checkout -q jkubo
    git -C "$work" branch -D topic upline >/dev/null
    printf 'fork-delta\n' >"$work/FORK_DELTA"
    commit_tree "$work" "linear fork delta"
    fork_tip="$(git -C "$work" rev-parse HEAD)"
    if git -C "$work" rev-parse --verify --quiet "${fork_tip}^2" >/dev/null; then
      fail "$name exclusive fork tip is a merge"
    fi
    git -C "$work" merge-base --is-ancestor "$merge" "$UP_SHA" || fail "$name shared merge is not in upstream"
    listed="$(git -C "$work" rev-list --merges "${UP_SHA}..${fork_tip}")" || fail "$name rev-list failed"
    [[ -z "$listed" ]] || fail "$name shared merge is in the exclusive range"
    git -C "$work" push -q origin "HEAD:refs/heads/jkubo"
    git -C "$work" fetch -q origin
  fi
  operator_commit="$(attach_operator_note "$work")"
  install_checkout_observer "$work"
  install_hook "$work"
  record_operator_snapshot "$work"
  if [[ "$name" == exclusive_merge ]]; then
    if [[ "$mode" == push ]]; then
      run_sync "$work" --allow-dirty --push
    else
      run_sync "$work" --allow-dirty
    fi
    assert_rc 1 "$name $mode"
    grep -F 'exclusive fork merge history is unsupported for native replay' "$SYNC_LOG" >/dev/null \
      || fail "$name $mode merge refusal missing"
    assert_refusal_preserved "$work" "$name $mode"
    assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$merge" "$name $mode fork ref moved"
    assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" "$name $mode HEAD moved"
    cmp -s "$SB_ROOT/merge-only-blob" "$work/MERGE_ONLY" || fail "$name $mode MERGE_ONLY bytes changed"
    git -C "$work" cat-file -e "${merge}:MERGE_ONLY" || fail "$name $mode merge commit lost MERGE_ONLY"
    say "$name $mode refused before checkout and kept the merge payload"
  else
    if [[ "$mode" == push ]]; then
      run_sync "$work" --push
    else
      run_sync "$work"
    fi
    assert_rc 0 "$name $mode"
    replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
    git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" || fail "$name $mode replay missed upstream"
    git -C "$work" cat-file blob "${replay}:MERGE_ONLY" >"$SB_ROOT/replay-merge-only"
    cmp -s "$SB_ROOT/merge-only-blob" "$SB_ROOT/replay-merge-only" || fail "$name $mode replay lost merge payload"
    printf 'fork-delta\n' >"$SB_ROOT/fork-delta"
    git -C "$work" cat-file blob "${replay}:FORK_DELTA" >"$SB_ROOT/replay-delta"
    cmp -s "$SB_ROOT/fork-delta" "$SB_ROOT/replay-delta" || fail "$name $mode replay lost fork delta"
    assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" "$name $mode replay lost fork tooling"
    assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" "$name $mode main is not the accepted upstream"
    if git -C "$work" cat-file -e "refs/heads/main:FORK_DELTA" 2>/dev/null; then
      fail "$name $mode main contains fork delta"
    fi
    if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
      fail "$name $mode main contains fork tooling"
    fi
    git -C "$work" cat-file blob "refs/heads/main:MERGE_ONLY" >"$SB_ROOT/main-merge-only"
    cmp -s "$SB_ROOT/merge-only-blob" "$SB_ROOT/main-merge-only" || fail "$name $mode main lost shared merge payload"
    assert_operator_kept "$work" "$operator_commit" "$name $mode"
    assert_publication "$mode" "$work" "$name $mode" "$replay" "$fork_tip"
    say "$name $mode replayed the linear fork and kept the shared merge payload"
  fi
}

# Legacy crlf is not visible as text or eol. set and input normalize CRLF to
# LF on git add and must refuse before checkout. -crlf with autocrlf false
# keeps the CRLF bytes through a real replay.
scenario_legacy_crlf() {
  local name="$1" mode="$2"
  local work attr expected_crlf tip operator_commit replay active=0
  case "$name" in
    crlf_set) attr='payload.dat crlf'; expected_crlf='set'; active=1 ;;
    crlf_input) attr='payload.dat crlf=input'; expected_crlf='input'; active=1 ;;
    crlf_unset) attr='payload.dat -crlf'; expected_crlf='unset'; active=0 ;;
    *) fail "unknown legacy crlf scenario $name" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown legacy crlf mode $mode" ;;
  esac
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  git -C "$work" config core.autocrlf false
  assert_eq "$(git -C "$work" config --get core.autocrlf)" "false" "$name autocrlf"
  printf '%s\n' "$attr" >"$work/.gitattributes"
  printf 'observe\r\n' >"$work/payload.dat"
  cp "$work/payload.dat" "$SB_ROOT/original-crlf"
  git -C "$work" add -- .gitattributes payload.dat
  git -C "$work" cat-file blob :payload.dat >"$SB_ROOT/index-blob"
  assert_eq "$(git -C "$work" check-attr text -- payload.dat)" "payload.dat: text: unspecified" "$name text attr"
  assert_eq "$(git -C "$work" check-attr eol -- payload.dat)" "payload.dat: eol: unspecified" "$name eol attr"
  assert_eq "$(git -C "$work" check-attr crlf -- payload.dat)" "payload.dat: crlf: ${expected_crlf}" "$name crlf attr"
  cmp -s "$SB_ROOT/original-crlf" "$work/payload.dat" || fail "$name git add rewrote the worktree"
  if [[ "$active" -eq 1 ]]; then
    if cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/index-blob"; then
      fail "$name index kept CRLF"
    fi
    printf 'observe\n' >"$SB_ROOT/expected-lf"
    cmp -s "$SB_ROOT/expected-lf" "$SB_ROOT/index-blob" || fail "$name git add did not normalize CRLF to LF"
    # The index blob is LF while a just-added worktree can still hold CRLF
    # and look clean. Match the worktree to the blob so refusal is the crlf
    # alias, which check-attr does not surface as text or eol.
    git -C "$work" cat-file blob :payload.dat >"$work/payload.dat"
    git -C "$work" add -- payload.dat
    cmp -s "$work/payload.dat" <(git -C "$work" cat-file blob :payload.dat) || fail "$name worktree diverged from the blob"
  else
    cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/index-blob" || fail "$name -crlf normalized CRLF"
  fi
  commit_tree "$work" "legacy crlf fixture ${name}"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin "HEAD:refs/heads/jkubo"
  advance_upstream "$work" bash -c "printf 'upstream-crlf\n' > UPSTREAM_CRLF"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$name advance moved the fork"
  operator_commit="$(attach_operator_note "$work")"
  install_checkout_observer "$work"
  install_hook "$work"
  record_operator_snapshot "$work"
  if [[ "$active" -eq 1 ]]; then
    if [[ "$mode" == push ]]; then
      run_sync "$work" --allow-dirty --push
    else
      run_sync "$work" --allow-dirty
    fi
    assert_rc 1 "$name $mode"
    grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null \
      || fail "$name $mode normalization refusal missing"
    assert_refusal_preserved "$work" "$name $mode"
    assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$name $mode fork moved"
    assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" "$name $mode HEAD moved"
    cmp -s "$SB_ROOT/expected-lf" "$work/payload.dat" || fail "$name $mode payload bytes changed"
    say "$name $mode refused legacy normalization before checkout"
  else
    if [[ "$mode" == push ]]; then
      run_sync "$work" --push
    else
      run_sync "$work"
    fi
    assert_rc 0 "$name $mode"
    replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
    git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" || fail "$name $mode did not replay"
    git -C "$work" cat-file blob "${replay}:payload.dat" >"$SB_ROOT/replay-payload"
    cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/replay-payload" || fail "$name $mode replay converted CRLF"
    cmp -s "$SB_ROOT/original-crlf" "$work/payload.dat" || fail "$name $mode operator CRLF changed"
    assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" "$name $mode lost fork tooling"
    assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" "$name $mode main"
    if git -C "$work" cat-file -e "refs/heads/main:payload.dat" 2>/dev/null; then
      fail "$name $mode main contains the fork payload"
    fi
    if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
      fail "$name $mode main contains fork tooling"
    fi
    assert_operator_kept "$work" "$operator_commit" "$name $mode"
    assert_publication "$mode" "$work" "$name $mode" "$replay" "$tip"
    say "$name $mode kept literal CRLF through replay"
  fi
}

# rebase.updateRefs true and false both keep the operator branch and a
# checkpoint in the exclusive fork range. The setting itself is not rewritten.
scenario_rebase_update_refs() {
  local setting="$1" relation="$2" mode="$3"
  local work checkpoint_commit tip operator_commit replay config_value
  case "$setting" in
    true|false) ;;
    *) fail "unknown updateRefs setting $setting" ;;
  esac
  case "$relation" in
    same|ahead) ;;
    *) fail "unknown updateRefs relation $relation" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown updateRefs mode $mode" ;;
  esac
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  printf 'checkpoint-payload\n' >"$work/CHECKPOINT_PAYLOAD"
  commit_tree "$work" "checkpoint payload"
  checkpoint_commit="$(git -C "$work" rev-parse HEAD)"
  printf 'fork-tip-payload\n' >"$work/FORK_TIP_PAYLOAD"
  printf '#!/bin/sh\nprintf fork-tool\n' >"$work/FORK_TOOL"
  chmod 755 "$work/FORK_TOOL"
  git -C "$work" add -- FORK_TIP_PAYLOAD
  git -C "$work" add --chmod=+x -- FORK_TOOL
  git -C "$work" commit -q -m "fork tip payload"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" ls-tree "$tip" -- FORK_TOOL | grep -q '^100755 ' \
    || fail "$setting $relation $mode FORK_TOOL is not executable"
  git -C "$work" branch checkpoint "$checkpoint_commit"
  git -C "$work" merge-base --is-ancestor "$checkpoint_commit" "$tip" \
    || fail "$setting $relation $mode checkpoint is not in the fork"
  advance_upstream "$work" bash -c "printf 'upstream-advanced\n' > UPSTREAM_ADVANCE"
  if git -C "$work" merge-base --is-ancestor "$checkpoint_commit" "$UP_SHA"; then
    fail "$setting $relation $mode checkpoint is already upstream"
  fi
  git -C "$work" rev-list "${UP_SHA}..${tip}" | grep -qx "$checkpoint_commit" \
    || fail "$setting $relation $mode checkpoint is outside the exclusive range"
  git -C "$work" push -q origin "${tip}:refs/heads/jkubo"
  git -C "$work" config rebase.updateRefs "$setting"
  config_value="$(git -C "$work" config --get rebase.updateRefs)"
  assert_eq "$config_value" "$setting" "$setting $relation $mode config value"
  if [[ "$relation" == ahead ]]; then
    git -C "$work" checkout -q -B operator
    printf 'operator-only\n' >"$work/NOTE"
    chmod 755 "$work/NOTE"
    git -C "$work" add --chmod=+x -- NOTE
    git -C "$work" commit -q -m "operator note"
    operator_commit="$(git -C "$work" rev-parse HEAD)"
    [[ "$operator_commit" != "$tip" ]] \
      || fail "$setting $relation $mode ahead operator collapsed onto the fork"
    if git -C "$work" cat-file -e "refs/heads/jkubo:NOTE" 2>/dev/null; then
      fail "$setting $relation $mode operator note landed on jkubo"
    fi
    [[ "$(git -C "$work" ls-files --stage -- NOTE)" == 100755* ]] \
      || fail "$setting $relation $mode NOTE index mode"
  else
    git -C "$work" checkout -q -B operator "$tip"
    operator_commit="$(git -C "$work" rev-parse HEAD)"
    assert_eq "$operator_commit" "$tip" "$setting $relation $mode operator is not the fork tip"
    assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" \
      "$setting $relation $mode fork tip moved while naming operator"
  fi
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$setting $relation $mode start is not operator"
  install_checkout_observer "$work"
  install_hook "$work"
  cp "$work/.git/config" "$SB_ROOT/config-before"
  record_operator_snapshot "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  assert_rc 0 "$setting $relation $mode"
  cmp -s "$SB_ROOT/config-before" "$work/.git/config" \
    || fail "$setting $relation $mode config bytes changed"
  assert_eq "$(git -C "$work" config --get rebase.updateRefs)" "$setting" \
    "$setting $relation $mode config value changed"
  assert_eq "$(git -C "$work" rev-parse refs/heads/checkpoint)" "$checkpoint_commit" \
    "$setting $relation $mode checkpoint moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" \
    "$setting $relation $mode operator moved"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" \
    "$setting $relation $mode HEAD moved"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$setting $relation $mode symbolic HEAD"
  replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$replay" != "$tip" ]] || fail "$setting $relation $mode fork did not replay"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" \
    || fail "$setting $relation $mode replay missed upstream"
  assert_eq "$(git -C "$work" show "${replay}:UPSTREAM_ADVANCE")" "upstream-advanced" \
    "$setting $relation $mode replay missed upstream payload"
  assert_eq "$(git -C "$work" show "${replay}:CHECKPOINT_PAYLOAD")" "checkpoint-payload" \
    "$setting $relation $mode replay missed checkpoint payload"
  assert_eq "$(git -C "$work" show "${replay}:FORK_TIP_PAYLOAD")" "fork-tip-payload" \
    "$setting $relation $mode replay missed fork tip payload"
  assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" \
    "$setting $relation $mode replay lost fork tooling"
  git -C "$work" ls-tree "$replay" -- FORK_TOOL | grep -q '^100755 ' \
    || fail "$setting $relation $mode replay FORK_TOOL is not executable"
  if [[ "$relation" == ahead ]]; then
    if git -C "$work" cat-file -e "${replay}:NOTE" 2>/dev/null; then
      fail "$setting $relation $mode replay absorbed the operator note"
    fi
    assert_eq "$(cat "$work/NOTE")" "operator-only" "$setting $relation $mode NOTE bytes"
    [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] \
      || fail "$setting $relation $mode NOTE type"
    [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] \
      || fail "$setting $relation $mode NOTE mode"
    [[ "$(git -C "$work" ls-files --stage -- NOTE)" == 100755* ]] \
      || fail "$setting $relation $mode NOTE index mode lost"
  fi
  [[ "$(stat -c '%a' -- "$work/FORK_TOOL")" == "755" ]] \
    || fail "$setting $relation $mode operator FORK_TOOL mode"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" \
    "$setting $relation $mode main is not the accepted upstream"
  if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
    fail "$setting $relation $mode main contains fork tooling"
  fi
  if git -C "$work" cat-file -e "refs/heads/main:FORK_TIP_PAYLOAD" 2>/dev/null; then
    fail "$setting $relation $mode main contains fork payload"
  fi
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" \
    || fail "$setting $relation $mode operator raw changed"
  write_types "$work" "$SB_ROOT/types-after"
  cmp -s "$SB_ROOT/types-before" "$SB_ROOT/types-after" \
    || fail "$setting $relation $mode type or mode changed"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v | sort) \
    || fail "$setting $relation $mode index flags changed"
  cmp -s "$SB_ROOT/stages-before" <(git -C "$work" ls-files --stage | sort) \
    || fail "$setting $relation $mode index stages changed"
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$setting $relation $mode checkout observer did not run"
  grep -qx 'refs/heads/jkubo' "$SB_ROOT/checkout-hook" \
    || fail "$setting $relation $mode observer missed the fork checkout"
  grep -qx 'refs/heads/main' "$SB_ROOT/checkout-hook" \
    || fail "$setting $relation $mode observer missed the mirror checkout"
  grep -qx 'refs/heads/operator' "$SB_ROOT/checkout-hook" \
    || fail "$setting $relation $mode observer missed the operator return"
  no_rebase_left "$work"
  assert_publication "$mode" "$work" "$setting $relation $mode" "$replay" "$tip"
  say "$setting $relation $mode kept operator and checkpoint across updateRefs"
}

# Local main is absent. A post-rewrite hook moves refs/remotes/origin/main
# after replay. Create authority is the OID captured before checkout.
scenario_moved_origin_ref() {
  local relation="$1" mode="$2"
  local work captured tip operator_commit replay cap_line reb_line
  case "$relation" in
    divergent|ancestor|equal) ;;
    *) fail "unknown moved-origin relation $relation" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown moved-origin mode $mode" ;;
  esac
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > UPSTREAM_MOVE"
  if [[ "$relation" == divergent ]]; then
    git -C "$work" checkout -q -B odiverge "$SEED_BASE"
    printf 'origin-diverge\n' >"$work/ORIGIN_DIVERGE"
    commit_tree "$work" "divergent origin"
    captured="$(git -C "$work" rev-parse HEAD)"
    git -C "$work" push -q origin "HEAD:refs/heads/main"
    git -C "$work" checkout -q jkubo
    git -C "$work" branch -D odiverge >/dev/null
  elif [[ "$relation" == equal ]]; then
    git -C "$work" push -q origin "${UP_SHA}:refs/heads/main"
    captured="$UP_SHA"
  else
    captured="$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/main)"
  fi
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$captured" \
    "$relation $mode bare origin main is not the intended capture"
  if [[ "$relation" == divergent ]]; then
    if git -C "$work" merge-base --is-ancestor "$captured" "$UP_SHA"; then
      fail "$relation $mode fixture origin is an ancestor of upstream"
    fi
  else
    git -C "$work" merge-base --is-ancestor "$captured" "$UP_SHA" \
      || fail "$relation $mode fixture origin is not an ancestor of upstream"
  fi
  if [[ "$relation" == ancestor ]]; then
    [[ "$captured" != "$UP_SHA" ]] || fail "$relation $mode ancestor capture equals upstream"
  elif [[ "$relation" == equal ]]; then
    assert_eq "$captured" "$UP_SHA" "$relation $mode equal capture"
  fi
  tip="$(git -C "$work" rev-parse refs/heads/jkubo)"
  git -C "$work" branch -D main >/dev/null
  if git -C "$work" show-ref --verify --quiet refs/heads/main; then
    fail "$relation $mode local main still exists"
  fi
  operator_commit="$(attach_operator_note "$work")"
  [[ "$operator_commit" != "$tip" ]] || fail "$relation $mode operator is not ahead of the fork"
  cat >"$work/.git/hooks/post-checkout" <<EOF
#!/bin/bash
printf '%s\n' "\$(git symbolic-ref -q HEAD || echo DETACHED)" >>"$SB_ROOT/checkout-hook"
printf '%s %s\n' "\$(git symbolic-ref -q HEAD || echo DETACHED)" "\$2" >>"$SB_ROOT/checkout-sha"
EOF
  chmod +x "$work/.git/hooks/post-checkout"
  # Divergent moves the tracking ref onto accepted upstream, which would pass
  # a reread. Ancestor and equal move it onto the rebased fork, which would
  # fail a reread. The captured OID is what the script must use.
  if [[ "$relation" == divergent ]]; then
    cat >"$work/.git/hooks/post-rewrite" <<EOF
#!/bin/bash
if [[ "\${1:-}" != rebase ]]; then
  exit 0
fi
git update-ref refs/remotes/origin/main ${UP_SHA}
git rev-parse refs/remotes/origin/main >"$SB_ROOT/origin-moved-to"
printf 'fired\n' >"$SB_ROOT/hook-fired"
exit 0
EOF
  else
    cat >"$work/.git/hooks/post-rewrite" <<EOF
#!/bin/bash
if [[ "\${1:-}" != rebase ]]; then
  exit 0
fi
git update-ref refs/remotes/origin/main HEAD
git rev-parse refs/remotes/origin/main >"$SB_ROOT/origin-moved-to"
printf 'fired\n' >"$SB_ROOT/hook-fired"
exit 0
EOF
  fi
  chmod +x "$work/.git/hooks/post-rewrite"
  install_hook "$work"
  record_operator_snapshot "$work"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  [[ -s "$SB_ROOT/hook-fired" && -s "$SB_ROOT/origin-moved-to" ]] \
    || fail "$relation $mode post-rewrite hook did not move origin/main"
  cap_line="$(grep -n "captured origin mirror ${captured}" "$SYNC_LOG" | head -n1 | cut -d: -f1)"
  reb_line="$(grep -n 'rebasing jkubo' "$SYNC_LOG" | head -n1 | cut -d: -f1)"
  [[ -n "$cap_line" && -n "$reb_line" && "$cap_line" -lt "$reb_line" ]] \
    || fail "$relation $mode did not capture origin before replay"
  replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$replay" != "$tip" ]] || fail "$relation $mode replay did not move jkubo"
  git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" \
    || fail "$relation $mode replay missed upstream"
  assert_eq "$(git -C "$work" show "${replay}:UPSTREAM_MOVE")" "upstream-moved" \
    "$relation $mode replay missed upstream payload"
  assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" \
    "$relation $mode replay lost fork tooling"
  if git -C "$work" cat-file -e "${replay}:NOTE" 2>/dev/null; then
    fail "$relation $mode replay absorbed the operator note"
  fi
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/operator" \
    "$relation $mode symbolic HEAD"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" \
    "$relation $mode HEAD"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" \
    "$relation $mode operator ref"
  assert_eq "$(cat "$work/NOTE")" "operator-note" "$relation $mode NOTE bytes"
  [[ "$(stat -c '%F' -- "$work/NOTE")" == "regular file" ]] || fail "$relation $mode NOTE type"
  [[ "$(stat -c '%a' -- "$work/NOTE")" == "755" ]] || fail "$relation $mode NOTE mode"
  [[ "$(git -C "$work" ls-files --stage -- NOTE)" == 100755* ]] \
    || fail "$relation $mode NOTE index mode"
  raw_manifest "$work" "$SB_ROOT/raw-after"
  cmp -s "$SB_ROOT/raw-before" "$SB_ROOT/raw-after" || fail "$relation $mode operator raw changed"
  write_types "$work" "$SB_ROOT/types-after"
  cmp -s "$SB_ROOT/types-before" "$SB_ROOT/types-after" || fail "$relation $mode type or mode changed"
  cmp -s "$SB_ROOT/flags-before" <(git -C "$work" ls-files -v | sort) \
    || fail "$relation $mode index flags changed"
  cmp -s "$SB_ROOT/stages-before" <(git -C "$work" ls-files --stage | sort) \
    || fail "$relation $mode index stages changed"
  cmp -s "$SB_ROOT/upstream-before" <(git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
    || fail "$relation $mode bare upstream changed"
  no_rebase_left "$work"
  [[ -s "$SB_ROOT/checkout-hook" ]] || fail "$relation $mode fork checkout did not run"
  grep -qx 'refs/heads/jkubo' "$SB_ROOT/checkout-hook" \
    || fail "$relation $mode observer missed the fork checkout"
  if [[ "$relation" == divergent ]]; then
    assert_rc 1 "$relation $mode"
    assert_eq "$(cat "$SB_ROOT/origin-moved-to")" "$UP_SHA" \
      "$relation $mode hook did not move origin/main onto upstream"
    assert_eq "$(git -C "$work" rev-parse refs/remotes/origin/main)" "$UP_SHA" \
      "$relation $mode tracking origin was reset"
    if git -C "$work" show-ref --verify --quiet refs/heads/main; then
      fail "$relation $mode created local main"
    fi
    if grep -qx 'refs/heads/main' "$SB_ROOT/checkout-hook"; then
      fail "$relation $mode checked out main"
    fi
    grep -F "main is ${captured} and upstream is ${UP_SHA}" "$SYNC_LOG" >/dev/null \
      || fail "$relation $mode ancestry refusal missing"
    grep -F "main is not an exact fast-forward of upstream" "$SYNC_LOG" >/dev/null \
      || fail "$relation $mode fast-forward refusal missing"
    assert_eq "$(out_value main "$EVIDENCE")" "absent" "$relation $mode main evidence"
    grep -qx 'refs/heads/operator' "$SB_ROOT/checkout-hook" \
      || fail "$relation $mode did not return to operator"
    cmp -s "$SB_ROOT/origin-before" <(git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
      || fail "$relation $mode bare origin changed"
    [[ ! -s "$HOOK_LOG" ]] || fail "$relation $mode pre-push ran"
    if grep -F 'pushing' "$SYNC_LOG" >/dev/null; then
      fail "$relation $mode reached push"
    fi
    say "$relation $mode refused the moved origin before creating main"
  else
    assert_rc 0 "$relation $mode"
    assert_eq "$(cat "$SB_ROOT/origin-moved-to")" "$replay" \
      "$relation $mode hook did not move origin/main onto the rebased fork"
    [[ "$replay" != "$captured" ]] || fail "$relation $mode hook target collapsed onto the capture"
    grep -qx "refs/heads/main ${captured}" "$SB_ROOT/checkout-sha" \
      || fail "$relation $mode did not create main from the captured origin"
    assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" \
      "$relation $mode final mirror"
    if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
      fail "$relation $mode main contains fork tooling"
    fi
    grep -qx 'refs/heads/operator' "$SB_ROOT/checkout-hook" \
      || fail "$relation $mode observer missed the operator return"
    if [[ "$mode" == local ]]; then
      assert_eq "$(git -C "$work" rev-parse refs/remotes/origin/main)" "$replay" \
        "$relation $mode local tracking origin was reset off the hook"
    fi
    if [[ "$relation" == equal && "$mode" == local ]]; then
      assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "$relation $mode evidence upstream"
      assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" "$relation $mode evidence main"
      assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "$relation $mode evidence sha"
      assert_eq "$(out_value changed "$EVIDENCE")" "true" "$relation $mode changed"
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" main)" "$captured" \
        "$relation $mode origin main moved"
      assert_eq "$(ref_sha "$SB_ROOT/origin.git" jkubo)" "$tip" \
        "$relation $mode origin fork moved"
      [[ ! -s "$HOOK_LOG" ]] || fail "$relation $mode local run published"
      grep -F 'not pushed (pass --push)' "$SYNC_LOG" >/dev/null \
        || fail "$relation $mode stayed local"
    else
      assert_publication "$mode" "$work" "$relation $mode" "$replay" "$tip"
    fi
    say "$relation $mode kept the captured origin and published only when asked"
  fi
}

# Upstream carries the crlf rule and no payload. The fork carries literal CRLF
# and no attributes. The rule still applies to the absent path.
scenario_cross_tree_attrs() {
  local name="$1" mode="$2"
  local work attr expected_crlf tip operator_commit replay active=0 probe
  case "$name" in
    crlf_set) attr='*.dat crlf'; expected_crlf='set'; active=1 ;;
    crlf_input) attr='*.dat crlf=input'; expected_crlf='input'; active=1 ;;
    crlf_unset) attr='*.dat -crlf'; expected_crlf='unset'; active=0 ;;
    *) fail "unknown cross-tree scenario $name" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown cross-tree mode $mode" ;;
  esac
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  git -C "$work" config core.autocrlf false
  assert_eq "$(git -C "$work" config --get core.autocrlf)" "false" "$name autocrlf"
  printf 'observe\r\n' >"$work/payload.dat"
  cp "$work/payload.dat" "$SB_ROOT/original-crlf"
  git -C "$work" add -- payload.dat
  git -C "$work" cat-file blob :payload.dat >"$SB_ROOT/fork-index"
  cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/fork-index" \
    || fail "$name fixture add normalized CRLF without an attribute"
  commit_tree "$work" "fork crlf payload"
  tip="$(git -C "$work" rev-parse HEAD)"
  if git -C "$work" cat-file -e "${tip}:.gitattributes" 2>/dev/null; then
    fail "$name fork commit has attributes"
  fi
  git -C "$work" cat-file blob "${tip}:payload.dat" >"$SB_ROOT/fork-blob"
  cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/fork-blob" || fail "$name fork blob lost CRLF"
  git -C "$work" push -q origin "${tip}:refs/heads/jkubo"
  advance_upstream "$work" bash -c "printf '%s\n' '$attr' > .gitattributes"
  if git -C "$work" cat-file -e "${UP_SHA}:payload.dat" 2>/dev/null; then
    fail "$name upstream contains payload.dat"
  fi
  git -C "$work" cat-file -e "${UP_SHA}:.gitattributes" || fail "$name upstream lacks attributes"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$name advance moved the fork"
  assert_eq "$(git -C "$work" check-attr --source="$UP_SHA" crlf -- payload.dat)" \
    "payload.dat: crlf: ${expected_crlf}" "$name upstream crlf on absent path"
  assert_eq "$(git -C "$work" check-attr --source="$UP_SHA" text -- payload.dat)" \
    "payload.dat: text: unspecified" "$name upstream text"
  assert_eq "$(git -C "$work" check-attr --source="$UP_SHA" eol -- payload.dat)" \
    "payload.dat: eol: unspecified" "$name upstream eol"
  assert_eq "$(git -C "$work" check-attr --source="$tip" crlf -- payload.dat)" \
    "payload.dat: crlf: unspecified" "$name fork crlf"
  assert_eq "$(git -C "$work" check-attr --source="$tip" text -- payload.dat)" \
    "payload.dat: text: unspecified" "$name fork text"
  assert_eq "$(git -C "$work" check-attr --source="$tip" eol -- payload.dat)" \
    "payload.dat: eol: unspecified" "$name fork eol"
  probe="$SB_ROOT/crlf-probe"
  git init -q -b main "$probe"
  git -C "$probe" config user.name "Jay Kubo"
  git -C "$probe" config user.email "6161465+jkubo@users.noreply.github.com"
  git -C "$probe" config commit.gpgsign false
  git -C "$probe" config core.autocrlf false
  printf '%s\n' "$attr" >"$probe/.gitattributes"
  printf 'observe\r\n' >"$probe/payload.dat"
  git -C "$probe" add -- .gitattributes payload.dat
  git -C "$probe" cat-file blob :payload.dat >"$SB_ROOT/probe-blob"
  if [[ "$active" -eq 1 ]]; then
    printf 'observe\n' >"$SB_ROOT/expected-lf"
    cmp -s "$SB_ROOT/expected-lf" "$SB_ROOT/probe-blob" \
      || fail "$name separate git add did not normalize CRLF to LF"
  else
    cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/probe-blob" \
      || fail "$name separate git add normalized -crlf"
  fi
  operator_commit="$(attach_operator_note "$work")"
  install_checkout_observer "$work"
  install_hook "$work"
  record_operator_snapshot "$work"
  if [[ "$active" -eq 1 ]]; then
    if [[ "$mode" == push ]]; then
      run_sync "$work" --allow-dirty --push
    else
      run_sync "$work" --allow-dirty
    fi
    assert_rc 1 "$name $mode"
    grep -F 'tracked raw transforms are unsupported for native replay' "$SYNC_LOG" >/dev/null \
      || fail "$name $mode normalization refusal missing"
    grep -F 'captured origin mirror' "$SYNC_LOG" >/dev/null \
      || fail "$name $mode did not capture origin before refusal"
    if grep -F 'rebasing' "$SYNC_LOG" >/dev/null; then
      fail "$name $mode reached rebase"
    fi
    assert_refusal_preserved "$work" "$name $mode"
    assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$name $mode fork moved"
    assert_eq "$(git -C "$work" rev-parse HEAD)" "$operator_commit" "$name $mode HEAD moved"
    cmp -s "$SB_ROOT/original-crlf" "$work/payload.dat" || fail "$name $mode payload bytes changed"
    git -C "$work" cat-file blob "${tip}:payload.dat" >"$SB_ROOT/kept-blob"
    cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/kept-blob" || fail "$name $mode committed CRLF changed"
    say "$name $mode refused cross-tree crlf before checkout"
  else
    if [[ "$mode" == push ]]; then
      run_sync "$work" --push
    else
      run_sync "$work"
    fi
    assert_rc 0 "$name $mode"
    replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
    git -C "$work" merge-base --is-ancestor "$UP_SHA" "$replay" \
      || fail "$name $mode did not replay"
    git -C "$work" cat-file blob "${replay}:payload.dat" >"$SB_ROOT/replay-payload"
    cmp -s "$SB_ROOT/original-crlf" "$SB_ROOT/replay-payload" \
      || fail "$name $mode replay converted CRLF"
    cmp -s "$SB_ROOT/original-crlf" "$work/payload.dat" || fail "$name $mode operator CRLF changed"
    assert_eq "$(git -C "$work" show "${replay}:.gitattributes")" "$attr" \
      "$name $mode replay missed upstream attributes"
    assert_eq "$(git -C "$work" show "${replay}:FORK.md")" "fork" \
      "$name $mode lost fork tooling"
    assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" "$name $mode main"
    if git -C "$work" cat-file -e "refs/heads/main:payload.dat" 2>/dev/null; then
      fail "$name $mode main contains the fork payload"
    fi
    if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
      fail "$name $mode main contains fork tooling"
    fi
    assert_operator_kept "$work" "$operator_commit" "$name $mode"
    assert_publication "$mode" "$work" "$name $mode" "$replay" "$tip"
    say "$name $mode kept literal CRLF through cross-tree replay"
  fi
}

# Exit codes from the real Git binaries. 0 1 128 is exists, quiet verify, peel.
native_origin_read_codes() {
  local work="$1" exists_rc=0 quiet_rc=0 parse_rc=0
  if git -C "$work" show-ref --exists refs/remotes/origin/main >/dev/null 2>&1; then
    exists_rc=0
  else
    exists_rc=$?
  fi
  if git -C "$work" show-ref --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then
    quiet_rc=0
  else
    quiet_rc=$?
  fi
  if git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1; then
    parse_rc=0
  else
    parse_rc=$?
  fi
  printf '%s %s %s\n' "$exists_rc" "$quiet_rc" "$parse_rc"
}

origin_tracking_payload() {
  local work="$1" git_dir
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  cat "$git_dir/refs/remotes/origin/main"
}

# A committed origin/jkubo update during fetch points origin/main at a cycle
# or a missing ref. Existence and commit readability are different facts.
scenario_origin_ref_read_error() {
  local kind="$1" placement="$2" mode="$3"
  local work damage_target tip operator_commit label
  case "$kind" in
    cycle) damage_target="refs/remotes/origin/main" ;;
    dangling) damage_target="refs/remotes/origin/nonexistent" ;;
    *) fail "unknown origin ref read error $kind" ;;
  esac
  case "$placement" in
    existing|missing) ;;
    *) fail "unknown origin ref placement $placement" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown origin ref mode $mode" ;;
  esac
  label="$kind $placement $mode"
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > UPSTREAM_MOVE"
  tip="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$tip" == "$SEED_TIP" ]] || fail "$label advance moved the fork"
  [[ "$tip" != "$SEED_BASE" ]] || fail "$label fork is not ahead of base"
  if [[ "$placement" == missing ]]; then
    git -C "$work" branch -D main >/dev/null
    if git -C "$work" show-ref --verify --quiet refs/heads/main; then
      fail "$label local main still exists"
    fi
  else
    assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$SEED_BASE" "$label local main"
  fi
  operator_commit="$(attach_operator_note "$work")"
  [[ "$operator_commit" != "$tip" ]] || fail "$label operator is not ahead of the fork"
  install_checkout_observer "$work"
  install_hook "$work"
  cat >"$work/.git/hooks/reference-transaction" <<EOF
#!/bin/bash
state="\${1:-}"
saw_old=""
saw_new=""
while IFS=' ' read -r old new ref; do
  if [[ "\$state" == committed && "\$ref" == refs/remotes/origin/jkubo && "\$old" != "\$new" ]]; then
    saw_old="\$old"
    saw_new="\$new"
  fi
done
if [[ -n "\$saw_new" ]]; then
  git symbolic-ref refs/remotes/origin/main ${damage_target}
  printf 'corrupt %s %s %s\n' "\$saw_old" "\$saw_new" "${damage_target}" >> "$SB_ROOT/ref-hook"
fi
exit 0
EOF
  chmod +x "$work/.git/hooks/reference-transaction"
  assert_eq "$(git -C "$work" rev-parse --verify 'refs/remotes/origin/main^{commit}')" "$SEED_BASE" \
    "$label origin main before fetch"
  git -C "$work" update-ref refs/remotes/origin/jkubo "$SEED_BASE"
  assert_eq "$(git -C "$work" rev-parse --verify 'refs/remotes/origin/jkubo^{commit}')" "$SEED_BASE" \
    "$label tracking fork before fetch"
  : >"$SB_ROOT/ref-hook"
  git -C "$work" fetch --quiet origin
  assert_eq "$(grep '^corrupt ' "$SB_ROOT/ref-hook" || true)" "corrupt ${SEED_BASE} ${tip} ${damage_target}" \
    "$label probe fetch did not commit an origin/jkubo update"
  native_origin_read_codes "$work" >"$SB_ROOT/read-before"
  assert_eq "$(cat "$SB_ROOT/read-before")" "0 1 128" "$label native read before script"
  assert_eq "$(origin_tracking_payload "$work")" "ref: ${damage_target}" "$label payload before script"
  if [[ "$kind" == dangling ]]; then
    assert_eq "$(git -C "$work" symbolic-ref refs/remotes/origin/main)" "$damage_target" \
      "$label dangling target before script"
  else
    if git -C "$work" symbolic-ref refs/remotes/origin/main >/dev/null 2>&1; then
      fail "$label cycle resolved before script"
    fi
  fi
  mv "$work/.git/hooks/reference-transaction" "$work/.git/hooks/reference-transaction.off"
  git -C "$work" update-ref -d --no-deref refs/remotes/origin/main
  git -C "$work" update-ref refs/remotes/origin/main "$SEED_BASE"
  git -C "$work" update-ref refs/remotes/origin/jkubo "$SEED_BASE"
  mv "$work/.git/hooks/reference-transaction.off" "$work/.git/hooks/reference-transaction"
  : >"$SB_ROOT/ref-hook"
  assert_eq "$(git -C "$work" rev-parse --verify 'refs/remotes/origin/main^{commit}')" "$SEED_BASE" \
    "$label restored origin main"
  assert_eq "$(git -C "$work" rev-parse --verify 'refs/remotes/origin/jkubo^{commit}')" "$SEED_BASE" \
    "$label tracking fork starts at base"
  record_operator_snapshot "$work"
  cp "$work/.git/config" "$SB_ROOT/config-before"
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  assert_rc 1 "$label"
  assert_eq "$(grep '^corrupt ' "$SB_ROOT/ref-hook" || true)" "corrupt ${SEED_BASE} ${tip} ${damage_target}" \
    "$label script fetch did not commit an origin/jkubo update"
  native_origin_read_codes "$work" >"$SB_ROOT/read-after"
  assert_eq "$(cat "$SB_ROOT/read-after")" "0 1 128" "$label native read after refusal"
  assert_eq "$(origin_tracking_payload "$work")" "ref: ${damage_target}" "$label damaged tracking preserved"
  if [[ "$kind" == dangling ]]; then
    assert_eq "$(git -C "$work" symbolic-ref refs/remotes/origin/main)" "$damage_target" \
      "$label dangling target preserved"
  else
    if git -C "$work" symbolic-ref refs/remotes/origin/main >/dev/null 2>&1; then
      fail "$label cycle was replaced"
    fi
  fi
  grep -F 'fetched origin mirror exists but its commit cannot be read' "$SYNC_LOG" >/dev/null \
    || fail "$label unreadable-origin refusal missing"
  if grep -F 'captured origin mirror absent' "$SYNC_LOG"; then
    fail "$label classified the unreadable ref as absent"
  fi
  if grep -F 'pushing' "$SYNC_LOG"; then
    fail "$label reached push"
  fi
  assert_refusal_preserved "$work" "$label"
  cmp -s "$SB_ROOT/config-before" "$work/.git/config" || fail "$label config changed"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$tip" "$label fork moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" "$label operator moved"
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "$label changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$tip" "$label sha"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "$label upstream evidence"
  if [[ "$placement" == missing ]]; then
    assert_eq "$(out_value main "$EVIDENCE")" "absent" "$label main evidence"
    if git -C "$work" show-ref --verify --quiet refs/heads/main; then
      fail "$label created local main"
    fi
  else
    assert_eq "$(out_value main "$EVIDENCE")" "$SEED_BASE" "$label main evidence"
    assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$SEED_BASE" "$label local main moved"
  fi
  say "$label refused unreadable origin before checkout"
}

# BEGIN origin-tracking-absence136 fixture
# A fetched origin fork or mirror ref that is really missing is show-ref
# --exists exit 2. The qualified commit is unreadable. That is absence, not
# a read failure. Completed replay may change the binary index and ORIG_HEAD.
scenario_origin_tracking_absent() {
  local kind="$1" mode="$2"
  local work operator_commit operator_tree fork_before label target_ref bare_ref
  local bare_exists=0 replay push_n exists_field exists_code
  local -a exists_codes=()
  tracking_read_codes() {
    local ref="$1" exists_rc=0 quiet_rc=0 parse_rc=0
    if git -C "$work" show-ref --exists "$ref" >/dev/null 2>&1; then
      exists_rc=0
    else
      exists_rc=$?
    fi
    if git -C "$work" show-ref --verify --quiet "$ref" >/dev/null 2>&1; then
      quiet_rc=0
    else
      quiet_rc=$?
    fi
    if git -C "$work" rev-parse --verify --end-of-options "${ref}^{commit}" >/dev/null 2>&1; then
      parse_rc=0
    else
      parse_rc=$?
    fi
    printf '%s %s %s\n' "$exists_rc" "$quiet_rc" "$parse_rc"
  }
  trace_capture() {
    python3 - "$SB_ROOT/git-trace" "$target_ref" <<'PY'
import json, sys
path, ref = sys.argv[1], sys.argv[2]
by = {}
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    sid = obj.get("sid")
    if not sid:
        continue
    rec = by.setdefault(sid, {})
    if obj.get("event") == "start":
        rec["argv"] = obj.get("argv") or []
    elif obj.get("event") == "exit":
        rec["code"] = obj.get("code")
exists = []
pushes = []
for rec in by.values():
    argv = rec.get("argv") or []
    if "show-ref" in argv and "--exists" in argv and ref in argv and "code" in rec:
        exists.append(str(rec["code"]))
    if len(argv) >= 2 and argv[1] == "push" and "--atomic" in argv and "code" in rec:
        pushes.append(" ".join(argv))
sys.stdout.write("exists=" + ",".join(exists) + "\n")
sys.stdout.write("pushes=" + str(len(pushes)) + "\n")
for i, item in enumerate(pushes):
    sys.stdout.write("push%d=%s\n" % (i, item))
PY
  }
  case "$kind" in
    fork|mirror) ;;
    *) fail "unknown origin tracking absence $kind" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown origin tracking absence mode $mode" ;;
  esac
  label="absent $kind $mode"
  if [[ "$kind" == fork ]]; then
    target_ref="refs/remotes/origin/jkubo"
    bare_ref="refs/heads/jkubo"
  else
    target_ref="refs/remotes/origin/main"
    bare_ref="refs/heads/main"
  fi
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > UPSTREAM_MOVE"
  fork_before="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$fork_before" != "$UP_SHA" ]] || fail "$label upstream did not advance past the fork"
  git -C "$work" merge-base --is-ancestor "$SEED_BASE" "$UP_SHA" \
    || fail "$label upstream is not ahead of the fork base"
  assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/jkubo^{commit}')" \
    "$fork_before" "$label stale fork tracking before deletion"
  assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/main^{commit}')" \
    "$SEED_BASE" "$label origin/main before deletion"
  git --git-dir="$SB_ROOT/origin.git" update-ref -d "$bare_ref"
  git -C "$work" update-ref -d "$target_ref"
  if git --git-dir="$SB_ROOT/origin.git" show-ref --exists "$bare_ref" >/dev/null 2>&1; then
    bare_exists=0
  else
    bare_exists=$?
  fi
  assert_eq "$bare_exists" "2" "$label bare origin ref is not genuinely absent"
  assert_eq "$(tracking_read_codes "$target_ref")" "2 1 128" \
    "$label native missing before fetch"
  if git -C "$work" for-each-ref --format='%(refname)' "$target_ref" | grep -q .; then
    fail "$label stale target tracking ref remains"
  fi
  operator_commit="$(attach_operator_note "$work")"
  operator_tree="$(git -C "$work" rev-parse "${operator_commit}^{tree}")"
  [[ "$operator_commit" != "$fork_before" ]] || fail "$label operator is not its own commit"
  install_checkout_observer "$work"
  install_hook "$work"
  cat >"$work/.git/hooks/pre-rebase" <<EOF
#!/bin/bash
exists_rc=0
quiet_rc=0
parse_rc=0
if git show-ref --exists "$target_ref" </dev/null >/dev/null 2>&1; then
  exists_rc=0
else
  exists_rc=\$?
fi
if git show-ref --verify --quiet "$target_ref" </dev/null >/dev/null 2>&1; then
  quiet_rc=0
else
  quiet_rc=\$?
fi
if git rev-parse --verify --end-of-options '${target_ref}^{commit}' </dev/null >/dev/null 2>&1; then
  parse_rc=0
else
  parse_rc=\$?
fi
printf '%s %s %s\n' "\$exists_rc" "\$quiet_rc" "\$parse_rc" >"$SB_ROOT/capture-read"
printf 'pre-rebase\n' >>"$SB_ROOT/rebase-hook"
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-rebase"
  if [[ "$kind" == mirror && "$mode" == push ]]; then
    cat >"$work/.git/hooks/pre-push" <<EOF
#!/bin/bash
cat >"$SB_ROOT/pre-push-stdin"
if [[ -n "\${HOOK_MARK:-}" ]]; then
  printf 'hooked\n' >>"\$HOOK_MARK"
fi
exists_rc=0
quiet_rc=0
parse_rc=0
if git show-ref --exists refs/remotes/origin/main </dev/null >/dev/null 2>&1; then
  exists_rc=0
else
  exists_rc=\$?
fi
if git show-ref --verify --quiet refs/remotes/origin/main </dev/null >/dev/null 2>&1; then
  quiet_rc=0
else
  quiet_rc=\$?
fi
if git rev-parse --verify --end-of-options 'refs/remotes/origin/main^{commit}' </dev/null >/dev/null 2>&1; then
  parse_rc=0
else
  parse_rc=\$?
fi
printf '%s %s %s\n' "\$exists_rc" "\$quiet_rc" "\$parse_rc" >"$SB_ROOT/push-read"
exit 0
EOF
    chmod +x "$work/.git/hooks/pre-push"
  fi
  record_operator_snapshot "$work"
  cp "$work/.git/config" "$SB_ROOT/config-before"
  if [[ "$mode" == push ]]; then
    GIT_TRACE2_EVENT="$SB_ROOT/git-trace" run_sync "$work" --push
  else
    GIT_TRACE2_EVENT="$SB_ROOT/git-trace" run_sync "$work"
  fi
  [[ -s "$SB_ROOT/capture-read" ]] || fail "$label pre-rebase did not observe capture state"
  assert_eq "$(cat "$SB_ROOT/capture-read")" "2 1 128" \
    "$label native missing and unreadable commit during capture"
  [[ -s "$SB_ROOT/rebase-hook" ]] || fail "$label pre-rebase did not run"
  trace_capture >"$SB_ROOT/trace-summary"
  exists_field="$(grep '^exists=' "$SB_ROOT/trace-summary" | cut -d= -f2-)"
  [[ -n "$exists_field" ]] || fail "$label script did not run show-ref --exists"
  IFS=',' read -r -a exists_codes <<<"$exists_field"
  for exists_code in "${exists_codes[@]}"; do
    [[ "$exists_code" == 2 ]] || fail "$label show-ref --exists returned $exists_code"
  done
  push_n="$(grep '^pushes=' "$SB_ROOT/trace-summary" | cut -d= -f2)"
  grep -F "captured origin ${kind} absent" "$SYNC_LOG" >/dev/null \
    || fail "$label did not record absence"
  grep -F 'rebasing' "$SYNC_LOG" >/dev/null || fail "$label did not replay"
  grep -F 'fast forwarding' "$SYNC_LOG" >/dev/null || fail "$label did not update the mirror"
  if grep -F 'existence could not be read' "$SYNC_LOG"; then
    fail "$label treated helper exit 2 as a read failure"
  fi
  if grep -F 'exists but its commit cannot be read' "$SYNC_LOG"; then
    fail "$label treated absence as an unreadable ref"
  fi
  cmp -s "$SB_ROOT/config-before" "$work/.git/config" || fail "$label config changed"
  assert_operator_kept "$work" "$operator_commit" "$label"
  assert_eq "$(git -C "$work" rev-parse "refs/heads/operator^{tree}")" "$operator_tree" \
    "$label operator tree changed"
  assert_eq "$(git -C "$work" rev-parse "refs/heads/operator^{commit}")" "$operator_commit" \
    "$label operator commit changed"
  replay="$(git -C "$work" rev-parse refs/heads/jkubo)"
  [[ "$replay" != "$fork_before" ]] || fail "$label fork was not replayed"
  assert_eq "$(git -C "$work" rev-parse 'refs/heads/jkubo^')" "$UP_SHA" \
    "$label replayed fork parent"
  assert_eq "$(git -C "$work" show "refs/heads/jkubo:UPSTREAM_MOVE")" "upstream-moved" \
    "$label replay missed the upstream file"
  assert_eq "$(git -C "$work" show "refs/heads/jkubo:FORK.md")" "fork" \
    "$label replay missed the fork file"
  cmp -s <(git -C "$work" show "refs/heads/jkubo:scripts/sync-upstream.sh") "$REAL_SYNC" \
    || fail "$label replayed sync script bytes differ"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$UP_SHA" \
    "$label local mirror"
  if git -C "$work" cat-file -e "refs/heads/main:FORK.md" 2>/dev/null; then
    fail "$label mirror contains fork delta"
  fi
  assert_eq "$(out_value changed "$EVIDENCE")" "true" "$label changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$replay" "$label evidence sha"
  assert_eq "$(out_value main "$EVIDENCE")" "$UP_SHA" "$label evidence main"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "$label evidence upstream"
  grep -F "fork sha=${replay} changed=true" "$SYNC_LOG" >/dev/null \
    || fail "$label log changed"
  grep -F "accepted upstream commit ${UP_SHA}" "$SYNC_LOG" >/dev/null \
    || fail "$label accepted upstream"
  cmp -s "$SB_ROOT/upstream-before" <(git --git-dir="$SB_ROOT/upstream.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
    || fail "$label bare upstream changed"
  # Completed replay updates the binary index and ORIG_HEAD. Those bytes are
  # not required to match the pre-run snapshot.
  if [[ "$kind" == fork && "$mode" == local ]]; then
    assert_rc 0 "$label"
    assert_eq "$push_n" "0" "$label local run pushed"
    grep -F 'not pushed (pass --push)' "$SYNC_LOG" >/dev/null || fail "$label stayed local"
    if grep -F 'pushing' "$SYNC_LOG"; then
      fail "$label reached push"
    fi
    if grep -F 'Refusing to push without a fetch-time lease' "$SYNC_LOG"; then
      fail "$label local run took the missing-lease refusal"
    fi
    [[ ! -s "$HOOK_LOG" ]] || fail "$label pre-push ran"
    assert_eq "$(tracking_read_codes "$target_ref")" "2 1 128" \
      "$label fork tracking ref was recreated"
    cmp -s "$SB_ROOT/origin-before" <(git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
      || fail "$label bare origin changed"
    grep -F "captured origin mirror ${SEED_BASE}" "$SYNC_LOG" >/dev/null \
      || fail "$label mirror was not peeled"
  elif [[ "$kind" == fork && "$mode" == push ]]; then
    assert_rc 1 "$label"
    assert_eq "$push_n" "0" "$label missing lease still pushed"
    grep -F 'origin/jkubo is absent. Refusing to push without a fetch-time lease.' "$SYNC_LOG" >/dev/null \
      || fail "$label missing-lease refusal missing"
    if grep -F 'pushing' "$SYNC_LOG"; then
      fail "$label reached push"
    fi
    [[ ! -s "$HOOK_LOG" ]] || fail "$label pre-push ran"
    assert_eq "$(tracking_read_codes "$target_ref")" "2 1 128" \
      "$label fork tracking ref was recreated"
    if git --git-dir="$SB_ROOT/origin.git" show-ref --exists refs/heads/jkubo >/dev/null 2>&1; then
      fail "$label bare fork was published"
    else
      bare_exists=$?
    fi
    assert_eq "$bare_exists" "2" "$label bare fork is no longer absent"
    assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$SEED_BASE" \
      "$label bare main moved"
    cmp -s "$SB_ROOT/origin-before" <(git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
      || fail "$label bare origin changed"
    grep -F "captured origin mirror ${SEED_BASE}" "$SYNC_LOG" >/dev/null \
      || fail "$label mirror was not peeled"
  elif [[ "$kind" == mirror && "$mode" == local ]]; then
    assert_rc 0 "$label"
    assert_eq "$push_n" "0" "$label local run pushed"
    grep -F 'not pushed (pass --push)' "$SYNC_LOG" >/dev/null || fail "$label stayed local"
    if grep -F 'pushing' "$SYNC_LOG"; then
      fail "$label reached push"
    fi
    [[ ! -s "$HOOK_LOG" ]] || fail "$label pre-push ran"
    assert_eq "$(tracking_read_codes "$target_ref")" "2 1 128" \
      "$label mirror tracking ref was recreated"
    assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/jkubo^{commit}')" \
      "$fork_before" "$label fork lease tracking moved"
    cmp -s "$SB_ROOT/origin-before" <(git --git-dir="$SB_ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort) \
      || fail "$label bare origin changed"
    grep -F "captured origin fork ${fork_before}" "$SYNC_LOG" >/dev/null \
      || fail "$label fork lease was not peeled"
  elif [[ "$kind" == mirror && "$mode" == push ]]; then
    assert_rc 0 "$label"
    assert_eq "$push_n" "1" "$label push count"
    grep -F -- "--atomic" "$SB_ROOT/trace-summary" >/dev/null \
      || fail "$label push was not atomic"
    grep -F -- "--force-with-lease=jkubo:${fork_before}" "$SB_ROOT/trace-summary" >/dev/null \
      || fail "$label push lease was not the fetched fork"
    assert_eq "$(grep -c '^hooked$' "$HOOK_LOG")" "1" "$label pre-push count"
    assert_eq "$(cat "$SB_ROOT/push-read")" "2 1 128" \
      "$label mirror tracking existed before the push"
    [[ "$(grep -c . "$SB_ROOT/pre-push-stdin")" -eq 2 ]] || fail "$label push ref count"
    grep -F 'refs/heads/main' "$SB_ROOT/pre-push-stdin" >/dev/null \
      || fail "$label push missed main"
    grep -F 'refs/heads/jkubo' "$SB_ROOT/pre-push-stdin" >/dev/null \
      || fail "$label push missed fork"
    grep -F "$UP_SHA" "$SB_ROOT/pre-push-stdin" >/dev/null \
      || fail "$label push missed the mirror object"
    grep -F "$replay" "$SB_ROOT/pre-push-stdin" >/dev/null \
      || fail "$label push missed the replayed fork"
    grep -F 'pushed' "$SYNC_LOG" >/dev/null || fail "$label did not finish the push"
    if grep -F 'Refusing to push without a fetch-time lease' "$SYNC_LOG"; then
      fail "$label valid fork lease was treated as missing"
    fi
    assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$UP_SHA" \
      "$label bare main"
    assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$replay" \
      "$label bare fork"
    assert_eq "$(tracking_read_codes refs/remotes/origin/main)" "0 0 0" \
      "$label origin/main afterread"
    assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/main^{commit}')" \
      "$UP_SHA" "$label origin/main afterread commit"
    assert_eq "$(tracking_read_codes refs/remotes/origin/jkubo)" "0 0 0" \
      "$label origin/jkubo afterread"
    assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/jkubo^{commit}')" \
      "$replay" "$label origin/jkubo afterread commit"
    grep -F "captured origin fork ${fork_before}" "$SYNC_LOG" >/dev/null \
      || fail "$label fork lease was not peeled"
  else
    fail "unhandled origin tracking absence $label"
  fi
  say "$label"
}
# END origin-tracking-absence136 fixture
# BEGIN origin-fork-read132 fixture
# A committed origin/jkubo update during fetch points that tracking ref at a
# cycle or a missing ref. Existence and commit readability are different facts.
scenario_origin_fork_read_error() {
  local kind="$1" relation="$2" mode="$3"
  local work damage_target local_tip operator_commit tracked_old label
  fork_read_codes() {
    local exists_rc=0 quiet_rc=0 parse_rc=0
    if git -C "$work" show-ref --exists refs/remotes/origin/jkubo >/dev/null 2>&1; then
      exists_rc=0
    else
      exists_rc=$?
    fi
    if git -C "$work" show-ref --verify --quiet refs/remotes/origin/jkubo >/dev/null 2>&1; then
      quiet_rc=0
    else
      quiet_rc=$?
    fi
    if git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/jkubo^{commit}' >/dev/null 2>&1; then
      parse_rc=0
    else
      parse_rc=$?
    fi
    printf '%s %s %s\n' "$exists_rc" "$quiet_rc" "$parse_rc"
  }
  case "$kind" in
    cycle) damage_target="refs/remotes/origin/jkubo" ;;
    dangling) damage_target="refs/remotes/origin/nonexistent" ;;
    *) fail "unknown origin fork read error $kind" ;;
  esac
  case "$relation" in
    ahead|diverged) ;;
    *) fail "unknown origin fork relation $relation" ;;
  esac
  case "$mode" in
    local|push) ;;
    *) fail "unknown origin fork mode $mode" ;;
  esac
  label="$kind $relation $mode"
  new_sandbox
  work="$SB_ROOT/work"
  seed_fork "$work"
  advance_upstream "$work" bash -c "printf 'upstream-moved\n' > UPSTREAM_MOVE"
  if [[ "$relation" == diverged ]]; then
    printf 'local-only\n' >"$work/LOCAL_ONLY.md"
    commit_tree "$work" "local only"
  fi
  local_tip="$(git -C "$work" rev-parse refs/heads/jkubo)"
  publish_side_fork "REMOTE_ONLY.md" "remote-only" "remote only"
  [[ "$local_tip" != "$SIDE_TIP" ]] || fail "$label remote fork did not move"
  if [[ "$relation" == ahead ]]; then
    git -C "$SB_ROOT/side" merge-base --is-ancestor "$local_tip" "$SIDE_TIP" \
      || fail "$label remote-only commit does not contain the local fork"
  else
    git -C "$SB_ROOT/side" fetch -q "$work" "refs/heads/jkubo:refs/tmp/local-jkubo"
    if git -C "$SB_ROOT/side" merge-base --is-ancestor "$SIDE_TIP" refs/tmp/local-jkubo; then
      fail "$label remote fork is an ancestor of the local fork"
    fi
    if git -C "$SB_ROOT/side" merge-base --is-ancestor refs/tmp/local-jkubo "$SIDE_TIP"; then
      fail "$label local fork is an ancestor of the remote fork"
    fi
    assert_eq "$(git -C "$work" show "refs/heads/jkubo:LOCAL_ONLY.md")" "local-only" \
      "$label local-only fixture"
  fi
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" show "${SIDE_TIP}:REMOTE_ONLY.md")" \
    "remote-only" "$label remote-only fixture"
  if git -C "$work" cat-file -e "refs/heads/jkubo:REMOTE_ONLY.md" 2>/dev/null; then
    fail "$label local fork already contains the remote-only file"
  fi
  tracked_old="$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/jkubo^{commit}')"
  [[ "$tracked_old" != "$SIDE_TIP" ]] || fail "$label tracking ref already matches the remote fork"
  assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/main^{commit}')" \
    "$SEED_BASE" "$label origin/main before fetch"
  operator_commit="$(attach_operator_note "$work")"
  [[ "$operator_commit" != "$local_tip" ]] || fail "$label operator is not ahead of the fork"
  install_checkout_observer "$work"
  install_hook "$work"
  cat >"$work/.git/hooks/pre-rebase" <<EOF
#!/bin/bash
printf 'pre-rebase\n' >>"$SB_ROOT/rebase-hook"
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-rebase"
  cat >"$work/.git/hooks/reference-transaction" <<EOF
#!/bin/bash
state="\${1:-}"
while IFS=' ' read -r old new ref; do
  if [[ "\$state" == committed && "\$ref" == refs/remotes/origin/jkubo && "\$old" != "\$new" && "\$old" =~ ^[0-9a-f]{40}\$ && "\$new" =~ ^[0-9a-f]{40}\$ && ! -s "$SB_ROOT/ref-hook" ]]; then
    printf 'corrupt %s %s %s\n' "\$old" "\$new" "${damage_target}" > "$SB_ROOT/ref-hook"
    git symbolic-ref refs/remotes/origin/jkubo ${damage_target}
  fi
done
exit 0
EOF
  chmod +x "$work/.git/hooks/reference-transaction"
  : >"$SB_ROOT/ref-hook"
  git -C "$work" fetch --quiet origin
  assert_eq "$(grep '^corrupt ' "$SB_ROOT/ref-hook" || true)" \
    "corrupt ${tracked_old} ${SIDE_TIP} ${damage_target}" \
    "$label probe fetch did not commit an origin/jkubo update"
  assert_eq "$(grep -c '^corrupt ' "$SB_ROOT/ref-hook")" "1" "$label probe hook recursed"
  fork_read_codes >"$SB_ROOT/read-before"
  assert_eq "$(cat "$SB_ROOT/read-before")" "0 1 128" "$label native read before script"
  assert_eq "$(cat "$work/.git/refs/remotes/origin/jkubo")" "ref: ${damage_target}" \
    "$label payload before script"
  if [[ "$kind" == dangling ]]; then
    assert_eq "$(git -C "$work" symbolic-ref refs/remotes/origin/jkubo)" "$damage_target" \
      "$label dangling target before script"
  else
    if git -C "$work" symbolic-ref refs/remotes/origin/jkubo >/dev/null 2>&1; then
      fail "$label cycle resolved before script"
    fi
  fi
  mv "$work/.git/hooks/reference-transaction" "$work/.git/hooks/reference-transaction.off"
  git -C "$work" update-ref -d --no-deref refs/remotes/origin/jkubo
  git -C "$work" update-ref refs/remotes/origin/jkubo "$tracked_old"
  mv "$work/.git/hooks/reference-transaction.off" "$work/.git/hooks/reference-transaction"
  : >"$SB_ROOT/ref-hook"
  assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/jkubo^{commit}')" \
    "$tracked_old" "$label restored tracking fork"
  record_operator_snapshot "$work"
  cp "$work/.git/config" "$SB_ROOT/config-before"
  if [[ -f "$work/.git/ORIG_HEAD" ]]; then
    cp "$work/.git/ORIG_HEAD" "$SB_ROOT/orig-before"
  else
    rm -f "$SB_ROOT/orig-before"
  fi
  if [[ "$mode" == push ]]; then
    run_sync "$work" --push
  else
    run_sync "$work"
  fi
  assert_rc 1 "$label"
  assert_eq "$(grep '^corrupt ' "$SB_ROOT/ref-hook" || true)" \
    "corrupt ${tracked_old} ${SIDE_TIP} ${damage_target}" \
    "$label script fetch did not commit an origin/jkubo update"
  assert_eq "$(grep -c '^corrupt ' "$SB_ROOT/ref-hook")" "1" "$label script hook recursed"
  fork_read_codes >"$SB_ROOT/read-after"
  assert_eq "$(cat "$SB_ROOT/read-after")" "0 1 128" "$label native read after refusal"
  assert_eq "$(cat "$work/.git/refs/remotes/origin/jkubo")" "ref: ${damage_target}" \
    "$label damaged tracking preserved"
  if [[ "$kind" == dangling ]]; then
    assert_eq "$(git -C "$work" symbolic-ref refs/remotes/origin/jkubo)" "$damage_target" \
      "$label dangling target preserved"
  else
    if git -C "$work" symbolic-ref refs/remotes/origin/jkubo >/dev/null 2>&1; then
      fail "$label cycle was replaced"
    fi
  fi
  grep -F 'fetched origin fork exists but its commit cannot be read' "$SYNC_LOG" >/dev/null \
    || fail "$label unreadable-fork refusal missing"
  if grep -F 'captured origin fork absent' "$SYNC_LOG"; then
    fail "$label classified the unreadable fork ref as absent"
  fi
  if grep -E 'captured origin fork [0-9a-f]' "$SYNC_LOG"; then
    fail "$label peeled an unreadable fork ref"
  fi
  if grep -F 'is not an ancestor of local' "$SYNC_LOG"; then
    fail "$label took the readable ancestry refusal"
  fi
  if grep -F 'origin/jkubo is absent' "$SYNC_LOG"; then
    fail "$label treated the unreadable fork ref as a missing lease"
  fi
  if grep -F 'rebasing' "$SYNC_LOG"; then
    fail "$label reached rebase"
  fi
  if grep -F 'pushing' "$SYNC_LOG"; then
    fail "$label reached push"
  fi
  if grep -F 'fast forwarding' "$SYNC_LOG"; then
    fail "$label updated the mirror"
  fi
  assert_refusal_preserved "$work" "$label"
  cmp -s "$SB_ROOT/config-before" "$work/.git/config" || fail "$label config changed"
  if [[ -f "$SB_ROOT/orig-before" ]]; then
    cmp -s "$SB_ROOT/orig-before" "$work/.git/ORIG_HEAD" || fail "$label ORIG_HEAD changed"
  else
    [[ ! -e "$work/.git/ORIG_HEAD" ]] || fail "$label ORIG_HEAD created"
  fi
  [[ ! -e "$SB_ROOT/rebase-hook" ]] || fail "$label pre-rebase observer ran"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$local_tip" "$label fork moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/operator)" "$operator_commit" "$label operator moved"
  assert_eq "$(git -C "$work" rev-parse refs/heads/main)" "$SEED_BASE" "$label local main moved"
  assert_eq "$(git -C "$work" rev-parse --verify --end-of-options 'refs/remotes/origin/main^{commit}')" \
    "$SEED_BASE" "$label origin/main moved"
  if git -C "$work" cat-file -e "refs/heads/jkubo:REMOTE_ONLY.md" 2>/dev/null; then
    fail "$label local fork absorbed REMOTE_ONLY.md"
  fi
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$SIDE_TIP" \
    "$label bare fork moved"
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" show "${SIDE_TIP}:REMOTE_ONLY.md")" \
    "remote-only" "$label remote-only bytes changed"
  assert_eq "$(git --git-dir="$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$SEED_BASE" \
    "$label bare main published"
  if [[ "$relation" == diverged ]]; then
    assert_eq "$(git -C "$work" show "refs/heads/jkubo:LOCAL_ONLY.md")" "local-only" \
      "$label local-only lost"
    if git --git-dir="$SB_ROOT/origin.git" cat-file -e "${SIDE_TIP}:LOCAL_ONLY.md" 2>/dev/null; then
      fail "$label origin absorbed LOCAL_ONLY.md"
    fi
  fi
  assert_eq "$(out_value changed "$EVIDENCE")" "false" "$label changed"
  assert_eq "$(out_value sha "$EVIDENCE")" "$local_tip" "$label sha"
  assert_eq "$(out_value upstream "$EVIDENCE")" "$UP_SHA" "$label upstream evidence"
  assert_eq "$(out_value main "$EVIDENCE")" "$SEED_BASE" "$label main evidence"
  assert_eq "$(git -C "$work" show refs/heads/jkubo:README.md)" "base" \
    "$label local fork was rebased"
  say "$label refused unreadable origin fork before checkout"
}
# END origin-fork-read132 fixture
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
scenario_detached_head
scenario_receive_reject "refs/heads/main" "main receive rejection"
scenario_receive_reject "refs/heads/jkubo" "fork receive rejection"
scenario_fetch_commit_rejects_push
scenario_pre_push_commit_rejects
scenario_published_checkout_fails
scenario_pre_push_commit_publishes
scenario_hook_commit_preserved post-checkout no jkubo
scenario_hook_commit_preserved pre-rebase yes jkubo
scenario_hook_commit_preserved post-rewrite yes jkubo
scenario_hook_commit_preserved post-merge yes main
scenario_fetch_dirty_bytes
scenario_conflict_stage_removed
scenario_initial_hidden_index_flag assume-unchanged
scenario_initial_hidden_index_flag skip-worktree
scenario_fetch_hidden_index_flag assume-unchanged
scenario_fetch_hidden_index_flag skip-worktree
scenario_checkout_hidden_index_flag assume-unchanged
scenario_checkout_hidden_index_flag skip-worktree
scenario_clean_filter_conflict push yes
scenario_clean_filter_conflict local yes
scenario_clean_filter_conflict push no
scenario_clean_filter_conflict local no
scenario_operator_todo_conflict push
scenario_operator_todo_conflict local
scenario_raw_checkout_filter local yes
scenario_raw_checkout_filter push yes
scenario_raw_checkout_filter local no
scenario_raw_checkout_filter push no
scenario_ignored_target_collision
scenario_prerebase_raw_policy local yes
scenario_prerebase_raw_policy push yes
scenario_prerebase_raw_policy local no
scenario_prerebase_raw_policy push no
scenario_intermediate_replay_target local yes
scenario_intermediate_replay_target push yes
scenario_intermediate_replay_target local no
scenario_intermediate_replay_target push no
scenario_normalized_start local same
scenario_normalized_start local ahead
scenario_normalized_start push same
scenario_normalized_start push ahead
scenario_precheckout_ignored_intermediate local
scenario_precheckout_ignored_intermediate push
scenario_operator_replay_positive local
scenario_operator_replay_positive push
scenario_filter_same_tree_start local same
scenario_filter_same_tree_start local ahead
scenario_filter_same_tree_start push same
scenario_filter_same_tree_start push ahead
scenario_absent_diverged_main local
scenario_absent_diverged_main push
scenario_moved_upstream_ref postcheckout existing local
scenario_moved_upstream_ref postcheckout existing push
scenario_moved_upstream_ref postcheckout missing local
scenario_moved_upstream_ref postcheckout missing push
scenario_moved_upstream_ref postrewrite existing local
scenario_moved_upstream_ref postrewrite existing push
scenario_moved_upstream_ref postrewrite missing local
scenario_moved_upstream_ref postrewrite missing push
scenario_qualified_ref upstream_tag local
scenario_qualified_ref upstream_tag push
scenario_qualified_ref operator_tag local
scenario_qualified_ref operator_tag push
scenario_qualified_ref heads_tags local
scenario_qualified_ref heads_tags push
scenario_qualified_ref origin_main_diverged_tag local
scenario_qualified_ref origin_main_diverged_tag push
scenario_qualified_ref origin_main_ancestor_tag local
scenario_qualified_ref origin_main_ancestor_tag push
scenario_qualified_ref origin_main_equal_tag local
scenario_qualified_ref origin_main_equal_tag push
scenario_merge_history exclusive_merge local
scenario_merge_history exclusive_merge push
scenario_merge_history common_merge local
scenario_merge_history common_merge push
scenario_legacy_crlf crlf_set local
scenario_legacy_crlf crlf_set push
scenario_legacy_crlf crlf_input local
scenario_legacy_crlf crlf_input push
scenario_legacy_crlf crlf_unset local
scenario_legacy_crlf crlf_unset push
scenario_rebase_update_refs true same local
scenario_rebase_update_refs true same push
scenario_rebase_update_refs true ahead local
scenario_rebase_update_refs true ahead push
scenario_rebase_update_refs false same local
scenario_rebase_update_refs false same push
scenario_rebase_update_refs false ahead local
scenario_rebase_update_refs false ahead push
scenario_moved_origin_ref divergent local
scenario_moved_origin_ref divergent push
scenario_moved_origin_ref ancestor local
scenario_moved_origin_ref ancestor push
scenario_moved_origin_ref equal local
scenario_moved_origin_ref equal push
scenario_cross_tree_attrs crlf_set local
scenario_cross_tree_attrs crlf_set push
scenario_cross_tree_attrs crlf_input local
scenario_cross_tree_attrs crlf_input push
scenario_cross_tree_attrs crlf_unset local
scenario_cross_tree_attrs crlf_unset push
scenario_origin_ref_read_error cycle existing local
scenario_origin_ref_read_error cycle existing push
scenario_origin_ref_read_error cycle missing local
scenario_origin_ref_read_error cycle missing push
scenario_origin_ref_read_error dangling existing local
scenario_origin_ref_read_error dangling existing push
scenario_origin_ref_read_error dangling missing local
scenario_origin_ref_read_error dangling missing push
scenario_origin_fork_read_error cycle ahead local
scenario_origin_fork_read_error cycle ahead push
scenario_origin_fork_read_error cycle diverged local
scenario_origin_fork_read_error cycle diverged push
scenario_origin_fork_read_error dangling ahead local
scenario_origin_fork_read_error dangling ahead push
scenario_origin_fork_read_error dangling diverged local
scenario_origin_fork_read_error dangling diverged push
scenario_origin_tracking_absent fork local
scenario_origin_tracking_absent fork push
scenario_origin_tracking_absent mirror local
scenario_origin_tracking_absent mirror push
say "all scenarios passed"
