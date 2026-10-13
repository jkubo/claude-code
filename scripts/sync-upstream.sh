#!/usr/bin/env bash
# Rebase the jkubo fork of claude-code onto anthropics/claude-code.
#
#   ./scripts/sync-upstream.sh              # fetch + rebase (no push)
#   ./scripts/sync-upstream.sh --push       # also update origin/jkubo + origin/main
#   ./scripts/sync-upstream.sh --dry-run    # report only, change nothing
#
# `main` stays an exact fast-forward of the upstream commit accepted once
# before checkout and must never carry fork delta. `jkubo` is that commit
# plus local plugins and this tooling. Replay is `git rebase --no-update-refs`:
# the flag does not change rebase.updateRefs, and other branches stay put.
# A later move of refs/remotes/upstream/main is not a new upstream. The
# fetched origin/main and origin/jkubo refs are classified before checkout.
# Only a missing ref is absence. An unreadable existing ref refuses then.
# There is no build step: upstream ships no CLI source, so nothing compiles.
# See FORK.md before assuming a commit in this tree changes the `claude` binary.
#
# Deliberately NOT modelled on grok-build's `git am --3way` fallback. That
# fallback earns its keep when the delta is one product patch that must survive
# an upstream refactor. Here the delta is whole plugin directories that upstream
# does not touch, so a conflict means something genuinely surprising happened
# and a human should look at it rather than have a script force it through.
#
# An owned failed replay is aborted. Completed local replay and mirror updates
# stay after rejected publication; other commands' work is preserved. After a
# successful push, the exit path reports the uploaded SHAs.
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
PUBLISHED=0
PUBLISHED_FORK=""
PUBLISHED_MAIN=""
OWNED_FORK=""
OWNED_MAIN=""
OWNED_MAIN_PRESENT=0
OWNED_HEAD_SHA=""
OWNED_HEAD_SYM=""
OWNED_PORCELAIN=""
OWNED_INDEX_TREE=""
OWNED_OPS=""
OWNED_BRANCHES=""
OURS_REBASE=0
BASE_READY=0
BASE_HEAD_SHA=""
BASE_HEAD_SYM=""
BASE_PORCELAIN=""
BASE_INDEX_TREE=""
BASE_OPS=""
BASE_BRANCHES=""
SNAP_HEAD_SHA=""
SNAP_HEAD_SYM=""
SNAP_PORCELAIN=""
SNAP_INDEX_TREE=""
SNAP_INDEX_FLAGS=""
BASE_INDEX_FLAGS=""
OWNED_INDEX_FLAGS=""
SNAP_OPS=""
SNAP_BRANCHES=""
SNAP_FORK=""
SNAP_MAIN=""
SNAP_MAIN_PRESENT=0
SNAP_OTHER_BRANCHES=""
OWNED_OTHER_BRANCHES=""
SNAP_WORKTREE=""
SNAP_DIRTY=""
SNAP_STAGED=""
SNAP_UNTRACKED=""
BASE_WORKTREE=""
OWNED_WORKTREE=""
OWNED_DIRTY=""
OWNED_STAGED=""
OWNED_UNTRACKED=""
REBASE_UPSTREAM=""
CAPTURED_ORIGIN=""
CAPTURED_ORIGIN_PRESENT=0

log()  { printf 'sync-upstream: %s\n' "$*"; }
die()  { printf 'sync-upstream: ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \?//'
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

operation_fp() {
  local git_dir name dir out=""
  git_dir="$(git rev-parse --absolute-git-dir)"
  for name in CHERRY_PICK_HEAD REVERT_HEAD MERGE_HEAD; do
    if [[ -f "$git_dir/$name" ]]; then
      out+="$name present"$'\n'
    else
      out+="$name absent"$'\n'
    fi
  done
  for dir in sequencer rebase-merge rebase-apply; do
    if [[ -d "$git_dir/$dir" ]]; then
      out+="$dir present"$'\n'
    else
      out+="$dir absent"$'\n'
    fi
  done
  printf '%s' "$out" | git hash-object --stdin
}

# Python 3 batches raw filesystem reads and Git blob reads without filters.
# NUL path records, no-follow descriptors, exact modes and stable stat metadata
# keep each observed read coherent. Reader failures preserve uncertain state.
RAW_FS_READER="$(cat <<'PY_RAW_FS_READER'
import hashlib, os, stat, subprocess, sys

# Only hashes leave this reader. Actual bytes never enter Git's object store.
mode = sys.argv[1]
parents = {}
missing = []
batch = None
ok = False

def identity(s):
    return (s.st_mode, s.st_dev, s.st_ino, s.st_nlink, s.st_uid, s.st_gid,
            s.st_size, s.st_mtime_ns, s.st_ctime_ns)

def parent(path):
    parts = path.split(b'/')
    if not path or path.startswith(b'/') or any(p in (b'', b'.', b'..') for p in parts):
        raise ValueError('unsupported path')
    prefix = b''
    fd = parents[b''][0]
    for part in parts[:-1]:
        key = prefix + part + b'/'
        if key not in parents:
            try:
                before = os.stat(part, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return None, parts[-1]
            if not stat.S_ISDIR(before.st_mode):
                raise ValueError('non-directory parent')
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            if identity(before) != identity(os.fstat(child)):
                os.close(child)
                raise ValueError('changed parent')
            parents[key] = (child, identity(before), fd, part)
        fd = parents[key][0]
        prefix = key
    return fd, parts[-1]

def raw(path, expected=None, tree_mode=None):
    fd, name = parent(path)
    try:
        before = os.stat(name, dir_fd=fd, follow_symlinks=False) if fd is not None else None
    except FileNotFoundError:
        before = None
    if before is None:
        if expected is not None:
            raise ValueError('missing tracked path')
        missing.append(path)
        return b'missing'
    if stat.S_ISREG(before.st_mode):
        if tree_mode is not None and before.st_mode != int(tree_mode, 8):
            raise ValueError('different file mode')
        opened = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            if identity(before) != identity(os.fstat(opened)):
                raise ValueError('changed open file')
            digest = hashlib.sha256()
            offset = 0
            while True:
                chunk = os.read(opened, 65536)
                if not chunk:
                    break
                if expected is not None and chunk != expected[offset:offset + len(chunk)]:
                    raise ValueError('different raw bytes')
                digest.update(chunk)
                offset += len(chunk)
            if expected is not None and offset != len(expected):
                raise ValueError('different length')
            if identity(before) != identity(os.fstat(opened)):
                raise ValueError('changed during read')
        finally:
            os.close(opened)
        value = b'file\0' + oct(before.st_mode).encode() + b'\0' + digest.digest()
    elif stat.S_ISLNK(before.st_mode):
        if tree_mode is not None and tree_mode != b'120000':
            raise ValueError('different symlink type')
        target = os.readlink(name, dir_fd=fd)
        if expected is not None and target != expected:
            raise ValueError('different symlink bytes')
        value = b'symlink\0' + oct(before.st_mode).encode() + b'\0' + hashlib.sha256(target).digest()
    elif stat.S_ISDIR(before.st_mode) and expected is None:
        value = b'directory\0' + oct(before.st_mode).encode()
    else:
        raise ValueError('unsupported file type')
    if identity(before) != identity(os.stat(name, dir_fd=fd, follow_symlinks=False)):
        raise ValueError('changed path')
    return value

def entries(tree):
    data = subprocess.check_output(['git', 'ls-tree', '--full-tree', '-rz', tree],
                                  stderr=subprocess.DEVNULL, env=dict(os.environ, GIT_NO_LAZY_FETCH='1'))
    result = {}
    for record in data.split(b'\0'):
        if not record:
            continue
        metadata, path = record.split(b'\t', 1)
        tree_mode, kind, oid = metadata.split(b' ')
        if kind != b'blob' or tree_mode not in (b'100644', b'100755', b'120000'):
            raise ValueError('unsupported tree entry')
        result[path] = (tree_mode, oid)
    return result

try:
    root = os.open(b'.', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parents[b''] = (root, identity(os.fstat(root)), None, None)
    if mode == 'fingerprint':
        digest = hashlib.sha256()
        for path in sys.stdin.buffer.read().split(b'\0'):
            if path:
                digest.update(path + b'\0' + raw(path) + b'\0')
        output = digest.hexdigest()
    elif mode == 'tree':
        skipped = {os.fsencode(p) for p in sys.argv[3:]}
        env = dict(os.environ, GIT_NO_LAZY_FETCH='1')
        batch = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        for path, (tree_mode, oid) in entries(sys.argv[2]).items():
            if path in skipped:
                continue
            batch.stdin.write(oid + b'\n')
            batch.stdin.flush()
            header = batch.stdout.readline().rstrip(b'\n').split(b' ')
            if len(header) != 3 or header[:2] != [oid, b'blob']:
                raise ValueError('unavailable blob')
            size = int(header[2])
            data = batch.stdout.read(size)
            if len(data) != size or batch.stdout.read(1) != b'\n':
                raise ValueError('incomplete blob read')
            raw(path, data, tree_mode)
        batch.stdin.close()
        if batch.stdout.read() or batch.wait() != 0:
            raise ValueError('blob producer failed')
        output = None
    elif mode in ('attributes', 'normalization'):
        # normalization is the pre-checkout gate. attributes also refuses an
        # active clean/smudge filter before replay. Legacy crlf is queried
        # directly: check-attr does not expand it into text or eol.
        # crlf set aliases text, crlf=input aliases eol=lf, and -crlf is unset.
        # Build one path union from every committed tree, then ask the working
        # tree, the index, and each of those trees about that same union. A
        # path missing from a tree is still subject to that tree's rules.
        # Reads without --source also apply info and global attributes.
        check_filters = mode == 'attributes'
        trees = list(dict.fromkeys(sys.argv[2:]))
        if not trees:
            raise ValueError('missing attribute source')
        wanted = [b'filter', b'working-tree-encoding', b'ident', b'text', b'eol', b'crlf']
        auto = subprocess.run(['git', 'config', '--get', 'core.autocrlf'], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
        if auto.returncode not in (0, 1):
            raise ValueError('unknown normalization configuration')
        auto_value = auto.stdout.strip().lower()
        if auto_value not in (b'', b'false', b'no', b'off', b'0', b'true', b'yes', b'on', b'1', b'input'):
            raise ValueError('unknown autocrlf value')
        active_auto = auto_value in (b'true', b'yes', b'on', b'1', b'input')
        driver_cache = {}
        union = []
        seen_paths = set()
        for tree in trees:
            for path in entries(tree):
                if path in seen_paths:
                    continue
                seen_paths.add(path)
                union.append(path)
        known_paths = set(union)
        payload = b''.join(path + b'\0' for path in union)
        sources = [[], ['--cached']]
        for tree in trees:
            sources.append(['--source=' + tree])
        attr_env = dict(os.environ, GIT_NO_LAZY_FETCH='1')
        for source in sources:
            attrs = subprocess.check_output(['git', 'check-attr', '-z', '--stdin',
                     *source, *[a.decode() for a in wanted]], input=payload,
                     stderr=subprocess.DEVNULL, env=attr_env)
            fields = attrs.split(b'\0')
            if fields[-1:] != [b''] or len(fields) != len(union) * len(wanted) * 3 + 1:
                raise ValueError('incomplete attribute read')
            matrix = {}
            for offset in range(0, len(fields) - 1, 3):
                path, attr, value = fields[offset:offset + 3]
                if path not in known_paths or attr not in wanted or (path, attr) in matrix:
                    raise ValueError('unknown attribute record')
                matrix[path, attr] = value
            inactive = (b'unspecified', b'unset')
            for path in union:
                    encoding = matrix[path, b'working-tree-encoding']
                    ident = matrix[path, b'ident']
                    text = matrix[path, b'text']
                    eol = matrix[path, b'eol']
                    crlf = matrix[path, b'crlf']
                    # set and input normalize CRLF to LF on git add. unset
                    # (-crlf) does not. Any other value is unknown and refuses.
                    if crlf not in inactive:
                        raise ValueError('active raw normalization')
                    if encoding not in inactive or ident not in inactive or text not in inactive or eol not in inactive:
                        raise ValueError('active raw normalization')
                    if active_auto and text != b'unset':
                        raise ValueError('active automatic normalization')
                    if not check_filters:
                        continue
                    driver = matrix[path, b'filter']
                    if driver not in inactive and driver not in driver_cache:
                        for suffix in ('clean', 'smudge', 'process', 'required'):
                            config = subprocess.run(['git', 'config', '--get',
                                     'filter.' + os.fsdecode(driver) + '.' + suffix],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                            if config.returncode not in (0, 1):
                                raise ValueError('unknown filter configuration')
                            value = config.stdout.strip()
                            if value and not (suffix == 'required' and value.lower() in (b'false', b'no', b'off', b'0')):
                                raise ValueError('active configured raw filter')
                        driver_cache[driver] = True
        output = None
    elif mode == 'collision':
        current = entries(sys.argv[2])
        targets = set()
        for tree in dict.fromkeys(sys.argv[3:]):
            targets.update(entries(tree))
        for path in targets:
            fd, name = parent(path)
            if fd is not None and path not in current:
                try:
                    os.stat(name, dir_fd=fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                raise ValueError('existing operator target path')
        output = None
    else:
        raise ValueError('unsupported reader mode')
    for fd, before, ancestor, name in parents.values():
        after = os.fstat(fd) if ancestor is None else os.stat(name, dir_fd=ancestor, follow_symlinks=False)
        if before != identity(after) or before != identity(os.fstat(fd)):
            raise ValueError('changed directory')
    for path in missing:
        try:
            os.lstat(path)
        except FileNotFoundError:
            continue
        raise ValueError('missing path appeared')
    ok = True
    if output is not None:
        print(output)
except Exception:
    pass
finally:
    if batch is not None and batch.poll() is None:
        batch.stdin.close()
        batch.stdout.close()
        batch.wait()
    for fd, _, _, _ in parents.values():
        os.close(fd)
sys.exit(0 if ok else 1)
PY_RAW_FS_READER
)"
path_bytes_fp() {
  python3 -c "$RAW_FS_READER" fingerprint
}

# Assume-unchanged and skip-worktree can hide tracked byte changes from diff.
# Hash only these semantic flags, so normal checkout additions remain valid.
index_flags_fp() {
  local entry
  git ls-files -v -z | while IFS= read -r -d '' entry; do
    case "${entry:0:1}" in
      [a-z]|S) printf '%s\0' "$entry" ;;
    esac
  done | git hash-object --stdin
}

capture_local_snapshot() {
  SNAP_HEAD_SHA="$(git rev-parse HEAD)" || return 1
  SNAP_HEAD_SYM="$(git symbolic-ref -q HEAD || echo DETACHED)"
  SNAP_PORCELAIN="$(git --no-optional-locks status --porcelain=v1 -z --untracked-files=all | git hash-object --stdin)" || return 1
  SNAP_INDEX_TREE="$(git ls-files --stage -z | git hash-object --stdin)" || return 1
  SNAP_WORKTREE="$(git ls-files -z --cached --others --exclude-standard | sort -zu | path_bytes_fp)" || return 1
  SNAP_UNTRACKED="$(git ls-files -z --others --exclude-standard | sort -zu | path_bytes_fp)" || return 1
  SNAP_DIRTY="$(git diff --binary --no-ext-diff --no-textconv | git hash-object --stdin)" || return 1
  SNAP_STAGED="$(git diff --cached --binary --no-ext-diff --no-textconv | git hash-object --stdin)" || return 1
  SNAP_INDEX_FLAGS="$(index_flags_fp)" || return 1
  SNAP_OPS="$(operation_fp)" || return 1
  SNAP_OTHER_BRANCHES="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | awk -v f="refs/heads/$FORK_BRANCH" -v m="refs/heads/$MIRROR_BRANCH" '$1 != f && $1 != m' | sort | git hash-object --stdin)" || return 1
  SNAP_BRANCHES="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | sort | git hash-object --stdin)" || return 1
  if git show-ref --verify --quiet "refs/heads/$FORK_BRANCH"; then
    SNAP_FORK="$(git rev-parse "refs/heads/$FORK_BRANCH")" || return 1
  else
    SNAP_FORK=""
  fi
  if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
    SNAP_MAIN_PRESENT=1
    SNAP_MAIN="$(git rev-parse "refs/heads/$MIRROR_BRANCH")" || return 1
  else
    SNAP_MAIN_PRESENT=0
    SNAP_MAIN=""
  fi
}

save_base_snapshot() {
  capture_local_snapshot || return 1
  BASE_HEAD_SHA="$SNAP_HEAD_SHA"
  BASE_HEAD_SYM="$SNAP_HEAD_SYM"
  BASE_PORCELAIN="$SNAP_PORCELAIN"
  BASE_WORKTREE="$SNAP_WORKTREE"
  BASE_INDEX_TREE="$SNAP_INDEX_TREE"
  BASE_INDEX_FLAGS="$SNAP_INDEX_FLAGS"
  BASE_OPS="$SNAP_OPS"
  BASE_BRANCHES="$SNAP_BRANCHES"
  BASE_READY=1
}

local_matches_base() {
  [[ "$BASE_READY" -eq 1 ]] || return 1
  capture_local_snapshot || return 1
  [[ "$SNAP_HEAD_SHA" == "$BASE_HEAD_SHA" ]] || return 1
  [[ "$SNAP_HEAD_SYM" == "$BASE_HEAD_SYM" ]] || return 1
  [[ "$SNAP_PORCELAIN" == "$BASE_PORCELAIN" ]] || return 1
  [[ "$SNAP_WORKTREE" == "$BASE_WORKTREE" ]] || return 1
  [[ "$SNAP_INDEX_TREE" == "$BASE_INDEX_TREE" ]] || return 1
  [[ "$SNAP_INDEX_FLAGS" == "$BASE_INDEX_FLAGS" ]] || return 1
  [[ "$SNAP_OPS" == "$BASE_OPS" ]] || return 1
  [[ "$SNAP_BRANCHES" == "$BASE_BRANCHES" ]] || return 1
  return 0
}

mark_owned_from_worktree() {
  local expected_sha="$1"
  raw_checkout_still_expected "$expected_sha" || return 1
  capture_local_snapshot || return 1
  [[ "$SNAP_HEAD_SHA" == "$expected_sha" ]] || return 1
  raw_checkout_still_expected "$expected_sha" || return 1
  OWNED_HEAD_SHA="$SNAP_HEAD_SHA"
  OWNED_HEAD_SYM="$SNAP_HEAD_SYM"
  OWNED_PORCELAIN="$SNAP_PORCELAIN"
  OWNED_WORKTREE="$SNAP_WORKTREE"
  OWNED_DIRTY="$SNAP_DIRTY"
  OWNED_STAGED="$SNAP_STAGED"
  OWNED_UNTRACKED="$SNAP_UNTRACKED"
  OWNED_INDEX_TREE="$SNAP_INDEX_TREE"
  OWNED_INDEX_FLAGS="$SNAP_INDEX_FLAGS"
  OWNED_OPS="$SNAP_OPS"
  OWNED_BRANCHES="$SNAP_BRANCHES"
  OWNED_OTHER_BRANCHES="$SNAP_OTHER_BRANCHES"
  OWNED_FORK="$SNAP_FORK"
  OWNED_MAIN="$SNAP_MAIN"
  OWNED_MAIN_PRESENT="$SNAP_MAIN_PRESENT"
}

state_still_owned() {
  [[ -n "$OWNED_HEAD_SHA" ]] || return 1
  raw_checkout_still_expected "$OWNED_HEAD_SHA" || return 1
  capture_local_snapshot || return 1
  [[ "$SNAP_HEAD_SHA" == "$OWNED_HEAD_SHA" ]] || return 1
  [[ "$SNAP_HEAD_SYM" == "$OWNED_HEAD_SYM" ]] || return 1
  [[ "$SNAP_PORCELAIN" == "$OWNED_PORCELAIN" ]] || return 1
  [[ "$SNAP_WORKTREE" == "$OWNED_WORKTREE" ]] || return 1
  [[ "$SNAP_INDEX_TREE" == "$OWNED_INDEX_TREE" ]] || return 1
  [[ "$SNAP_INDEX_FLAGS" == "$OWNED_INDEX_FLAGS" ]] || return 1
  [[ "$SNAP_OPS" == "$OWNED_OPS" ]] || return 1
  [[ "$SNAP_BRANCHES" == "$OWNED_BRANCHES" ]] || return 1
  return 0
}

# Checkout may execute an operator hook. Verify its expected target and all
# existing named refs before recording the resulting tree as ours.
checkout_still_expected() {
  local expected_sha="$1" expected_sym="$2"
  raw_checkout_still_expected "$expected_sha" || return 1
  capture_local_snapshot || return 1
  [[ "$SNAP_HEAD_SHA" == "$expected_sha" && "$SNAP_HEAD_SYM" == "$expected_sym" ]] || return 1
  [[ "$SNAP_BRANCHES" == "$OWNED_BRANCHES" && "$SNAP_OPS" == "$OWNED_OPS" ]] || return 1
  [[ "$SNAP_DIRTY" == "$OWNED_DIRTY" && "$SNAP_STAGED" == "$OWNED_STAGED" ]] || return 1
  [[ "$SNAP_UNTRACKED" == "$OWNED_UNTRACKED" ]] || return 1
  [[ "$SNAP_INDEX_FLAGS" == "$OWNED_INDEX_FLAGS" ]] || return 1
  raw_checkout_still_expected "$expected_sha"
}

# Reconstruct all expected conflict stages with native Git from committed
# inputs. Validate their presence as well as their values; a removed stage or
# fully resolved path belongs to the other command. Worktree bytes never enter
# this merge: it creates only merge objects from already committed trees.
conflict_index_still_expected() {
  local rebase_dir="$1" stopped base entry path merge_status
  local expected_stages actual_stages tree_oid
  local excludes=()
  stopped="$(cat "$rebase_dir/stopped-sha")" || return 1
  base="$(git rev-parse "${stopped}^")" || return 1
  # Avoid executing a configured external merge driver a second time merely
  # to establish ownership. Leave such uncertain conflict state intact.
  if git config --get-regexp '^merge\..*\.driver$' >/dev/null 2>&1; then
    return 1
  fi
  # merge-tree returns 1 for conflicts. Its first NUL record is the tree OID;
  # remaining records are the complete index-stage matrix, with no messages.
  if expected_stages="$(git merge-tree --write-tree --no-messages --merge-base="$base" -z HEAD "$stopped" 2>/dev/null | {
    IFS= read -r -d '' tree_oid || exit 1
    sort -z | git hash-object --stdin
  })"; then
    return 1
  else
    merge_status=$?
  fi
  [[ "$merge_status" -eq 1 && -n "$expected_stages" ]] || return 1
  actual_stages="$(git ls-files --unmerged -z | sort -z | git hash-object --stdin)" || return 1
  [[ "$actual_stages" == "$expected_stages" ]] || return 1
  while IFS= read -r -d '' entry; do
    path="${entry#*$'\t'}"
    excludes+=(":(exclude,literal)$path")
  done < <(git ls-files --unmerged -z)
  git diff --cached --quiet --no-ext-diff --no-textconv AUTO_MERGE -- "${excludes[@]}"
}

# Compare committed blobs literally with raw files and symlink targets. A
# single batch producer is checked through successful EOF and exit status.
raw_tree_matches_worktree() {
  local tree="$1"
  shift
  python3 -c "$RAW_FS_READER" tree "$tree" "$@"
}

PRESERVED_DIRTY_PATHS=()
PRESERVED_DIRTY_BYTES=""
PRESERVED_DIRTY_TREE=""
save_preserved_dirty_paths() {
  local path
  [[ "$ALLOW_DIRTY" -eq 1 ]] || return 0
  while IFS= read -r -d '' path; do
    PRESERVED_DIRTY_PATHS+=("$path")
  done < <(git diff --name-only -z --no-ext-diff --no-textconv HEAD)
  [[ ${#PRESERVED_DIRTY_PATHS[@]} -gt 0 ]] || return 0
  PRESERVED_DIRTY_BYTES="$(printf '%s\0' "${PRESERVED_DIRTY_PATHS[@]}" | path_bytes_fp)" || return 1
  PRESERVED_DIRTY_TREE="$(git --literal-pathspecs ls-tree --full-tree -rz HEAD -- "${PRESERVED_DIRTY_PATHS[@]}" | git hash-object --stdin)" || return 1
}

# Only explicit dirty input captured before fetch may differ from a stored
# blob. Its exact raw state and original committed path provenance must stay.
raw_checkout_still_expected() {
  local tree="$1" dirty_bytes dirty_tree
  if [[ ${#PRESERVED_DIRTY_PATHS[@]} -gt 0 ]]; then
    dirty_bytes="$(printf '%s\0' "${PRESERVED_DIRTY_PATHS[@]}" | path_bytes_fp)" || return 1
    dirty_tree="$(git --literal-pathspecs ls-tree --full-tree -rz "$tree" -- "${PRESERVED_DIRTY_PATHS[@]}" | git hash-object --stdin)" || return 1
    [[ "$dirty_bytes" == "$PRESERVED_DIRTY_BYTES" && "$dirty_tree" == "$PRESERVED_DIRTY_TREE" ]] || return 1
  fi
  raw_tree_matches_worktree "$tree" "${PRESERVED_DIRTY_PATHS[@]}"
}

checkout_target_clear() {
  python3 -c "$RAW_FS_READER" collision "$(git rev-parse HEAD)" "$@"
}

native_transforms_supported() {
  python3 -c "$RAW_FS_READER" attributes "$@"
}

native_normalization_supported() {
  python3 -c "$RAW_FS_READER" normalization "$@"
}

prepare_owned_checkout() {
  state_still_owned && raw_checkout_still_expected "$OWNED_HEAD_SHA" && checkout_target_clear "$1" || return 1
  [[ "${2:-0}" -eq 1 ]] || native_transforms_supported "$OWNED_HEAD_SHA" "$1"
}

# Fingerprint the complete operation directories and uppercase pseudorefs.
# FETCH_HEAD and COMMIT_EDITMSG survive abort and are not sequencer state.
# Reject links/special files; require a stable raw read of every entry.
rebase_operation_fp() {
  local git_dir="$1" name path relative before after bits digest
  {
    for name in rebase-merge rebase-apply sequencer; do
      printf '%s\0' "$name"
      if [[ -e "$git_dir/$name" || -L "$git_dir/$name" ]]; then
        [[ -d "$git_dir/$name" && ! -L "$git_dir/$name" ]] || return 1
        find "$git_dir/$name" -print0 | sort -z || return 1
      else
        printf 'absent\0'
      fi
    done
    find "$git_dir" -mindepth 1 -maxdepth 1 -name '[A-Z]*' \
      ! -name FETCH_HEAD ! -name COMMIT_EDITMSG -print0 | sort -z || return 1
  } | while IFS= read -r -d '' path; do
    case "$path" in
      rebase-merge|rebase-apply|sequencer|absent) printf '%s\0' "$path"; continue ;;
    esac
    relative="${path#"$git_dir/"}"
    [[ ! -L "$path" ]] || return 1
    before="$(stat -c '%f:%d:%i:%h:%u:%g:%s:%y:%z' -- "$path" 2>/dev/null)" || return 1
    bits="${before%%:*}"
    printf '%s\0%s\0' "$relative" "$bits"
    if [[ -f "$path" && -r "$path" ]]; then
      digest="$(git hash-object --no-filters -- "$path")" || return 1
      printf 'file\0%s\0' "$digest"
    elif [[ -d "$path" ]]; then
      printf 'directory\0'
    else
      return 1
    fi
    after="$(stat -c '%f:%d:%i:%h:%u:%g:%s:%y:%z' -- "$path" 2>/dev/null)" || return 1
    [[ "$before" == "$after" ]] || return 1
  done | git hash-object --stdin
}

# Reproduce Git's plain failed replay in a private empty-template repository.
# Only committed objects are shared read-only through alternates; all index,
# worktree, refs and new objects belong to the reference repository. Its lack
# of hooks/config never changes the real replay. Both replays pass
# --no-update-refs, so another branch in the real repo cannot write an
# update-refs file the reference does not have. Any mismatch keeps that real
# operation intact, including valid operator-added todo instructions.
rebase_operation_still_expected() (
  local actual_dir="$1" proof objects actual_head committer_name committer_email
  local committer_date format before expected after replay_status
  actual_head="$(git rev-parse HEAD)" || return 1
  committer_name="$(git show -s --format=%cn HEAD)" || return 1
  committer_email="$(git show -s --format=%ce HEAD)" || return 1
  committer_date="$(git show -s --format=%cI HEAD)" || return 1
  format="$(git rev-parse --show-object-format)" || return 1
  objects="$(git rev-parse --path-format=absolute --git-path objects)" || return 1
  [[ "$objects" != *$'\n'* ]] || return 1
  before="$(rebase_operation_fp "$actual_dir")" || return 1
  proof="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$proof"' EXIT
  mkdir "$proof/template" "$proof/worktree" || return 1
  (
    unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_CONFIG_PARAMETERS
    unset GIT_CONFIG_SYSTEM GIT_CONFIG GIT_TEMPLATE_DIR GIT_DEFAULT_HASH
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0
    export GIT_DIR="$proof/repo.git"
    export GIT_COMMITTER_NAME="$committer_name" GIT_COMMITTER_EMAIL="$committer_email"
    export GIT_COMMITTER_DATE="$committer_date"
    git init --bare --quiet --object-format="$format" --template="$proof/template" "$GIT_DIR" || exit 1
    printf '%s\n' "$objects" >"$GIT_DIR/objects/info/alternates" || exit 1
    export GIT_WORK_TREE="$proof/worktree"
    git checkout --quiet -b "$FORK_BRANCH" "$FORK_BEFORE" || exit 1
    git update-ref "refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" "$REBASE_UPSTREAM" || exit 1
    cd "$GIT_WORK_TREE" || exit 1
    if git rebase --quiet --no-update-refs "$REBASE_UPSTREAM" >"$proof/replay.log" 2>&1; then
      exit 1
    else
      replay_status=$?
    fi
    [[ "$replay_status" -eq 1 && -d "$GIT_DIR/rebase-merge" ]] || exit 1
    [[ "$(git rev-parse HEAD)" == "$actual_head" ]] || exit 1
  ) || return 1
  expected="$(rebase_operation_fp "$proof/repo.git")" || return 1
  after="$(rebase_operation_fp "$actual_dir")" || return 1
  [[ "$before" == "$after" && "$after" == "$expected" ]]
)

owned_failed_rebase() {
  local git_dir rebase_dir empty_fp changed_outside_conflicts
  git_dir="$(git rev-parse --absolute-git-dir)" || return 1
  rebase_dir="$git_dir/rebase-merge"
  [[ -d "$rebase_dir" && ! -d "$git_dir/rebase-apply" ]] || return 1
  [[ ! -d "$git_dir/sequencer" && ! -f "$git_dir/MERGE_HEAD" && ! -f "$git_dir/CHERRY_PICK_HEAD" && ! -f "$git_dir/REVERT_HEAD" ]] || return 1
  [[ "$(cat "$rebase_dir/head-name")" == "refs/heads/$FORK_BRANCH" ]] || return 1
  [[ "$(cat "$rebase_dir/orig-head")" == "$FORK_BEFORE" ]] || return 1
  [[ "$(cat "$rebase_dir/onto")" == "$REBASE_UPSTREAM" ]] || return 1
  raw_tree_matches_worktree AUTO_MERGE || return 1
  capture_local_snapshot || return 1
  [[ "$SNAP_FORK" == "$FORK_BEFORE" && "$SNAP_BRANCHES" == "$OWNED_BRANCHES" && "$SNAP_HEAD_SYM" == DETACHED ]] || return 1
  [[ "$SNAP_UNTRACKED" == "$OWNED_UNTRACKED" ]] || return 1
  [[ "$SNAP_INDEX_FLAGS" == "$OWNED_INDEX_FLAGS" ]] || return 1
  # The detached tip must be Git's own last replay step. AUTO_MERGE records
  # its original conflict bytes, so edits to a conflicted path also stop abort.
  case "$(git reflog show -1 --format='%gs' HEAD)" in
    'rebase (start):'*|'rebase (pick):'*|'rebase (continue):'*) ;;
    *) return 1 ;;
  esac
  git rev-parse --verify 'AUTO_MERGE^{tree}' >/dev/null 2>&1 || return 1
  conflict_index_still_expected "$rebase_dir" || return 1
  empty_fp="$(printf '' | git hash-object --stdin)"
  # Autostashed dirty input or ordinary changed files cannot be claimed as a
  # conflict we own. Preserve that operation for the operator to inspect.
  [[ "$OWNED_DIRTY" == "$empty_fp" && "$OWNED_STAGED" == "$empty_fp" ]] || return 1
  changed_outside_conflicts="$(comm -z -23 <(git diff-files --name-only -z | sort -zu) <(git diff --name-only --diff-filter=U -z | sort -zu) | git hash-object --stdin)" || return 1
  [[ "$changed_outside_conflicts" == "$empty_fp" ]] || return 1
  raw_tree_matches_worktree AUTO_MERGE || return 1
  rebase_operation_still_expected "$git_dir"
}

restore_branches() {
  local start_sha=""
  [[ "$MUTATED" -eq 1 ]] || return 0
  [[ "$PUBLISHED" -eq 0 ]] || return 0
  if [[ "$OURS_REBASE" -eq 1 ]]; then
    if state_still_owned; then
      OURS_REBASE=0
    elif owned_failed_rebase; then
      if git rebase --abort; then
        OURS_REBASE=0
        if ! checkout_still_expected "$FORK_BEFORE" "refs/heads/$FORK_BRANCH"; then
          log "local state changed while aborting; preserving it"
          MUTATED=0
          return 0
        fi
        mark_owned_from_worktree "$FORK_BEFORE" || return 1
      else
        log "could not abort the owned rebase; preserving it"
        MUTATED=0
        return 0
      fi
    else
      log "failed rebase state is not owned; preserving refs, files, and operation"
      MUTATED=0
      return 0
    fi
  fi
  # Completed commits remain on their names, including replay and main. Only
  # return to the original checkout if no other command changed owned state.
  # The tree argument is the branch commit. A same-named tag is not that tree.
  if state_still_owned && [[ -n "$START_BRANCH" ]] && git show-ref --verify --quiet "refs/heads/$START_BRANCH"; then
    start_sha="$(git rev-parse --verify "refs/heads/${START_BRANCH}^{commit}" 2>/dev/null || true)"
    if [[ -n "$start_sha" ]] && prepare_owned_checkout "$start_sha"; then
      git checkout --quiet "$START_BRANCH" || log "could not return to $START_BRANCH; preserving current checkout"
    elif [[ "$(git rev-parse "refs/heads/$START_BRANCH")" == "$(git rev-parse HEAD)" ]] \
      && raw_checkout_still_expected "$(git rev-parse HEAD)" \
      && git symbolic-ref HEAD "refs/heads/$START_BRANCH"; then
      # The checkout named a different branch of this same commit. A content
      # checkout back is itself an unsupported transform, so restore only the
      # symbolic HEAD. Bytes, index, and the other ref stay as they are.
      log "restored symbolic HEAD to $START_BRANCH without a transforming checkout"
    else
      log "raw checkout or target paths are uncertain; preserving current checkout"
    fi
  else
    log "local state changed; preserving current checkout"
  fi
  MUTATED=0
}

fail_rollback() {
  restore_branches
  die "$@"
}

emit_evidence() {
  local fork_sha="" upstream_sha="" main_sha="" changed="false"
  # After acceptance, report that commit even if a hook moved the tracking
  # ref. Before acceptance, a diagnostic may still observe the qualified
  # remote-tracking commit. A same-named tag is not that commit. A missing
  # token exits before fetch and stays on this diagnostic path.
  if [[ -n "$REBASE_UPSTREAM" ]]; then
    upstream_sha="$REBASE_UPSTREAM"
  else
    upstream_sha="$(git rev-parse --verify "refs/remotes/${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}^{commit}" 2>/dev/null || true)"
  fi
  if [[ "$PUBLISHED" -eq 1 ]]; then
    fork_sha="$PUBLISHED_FORK"
    main_sha="$PUBLISHED_MAIN"
  else
    fork_sha="$(git rev-parse "refs/heads/$FORK_BRANCH" 2>/dev/null || true)"
    if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
      main_sha="$(git rev-parse "refs/heads/$MIRROR_BRANCH")"
    fi
  fi
  if [[ -n "$fork_sha" && -n "$FORK_BEFORE" && "$fork_sha" != "$FORK_BEFORE" ]]; then
    changed="true"
  fi
  log "fork sha=${fork_sha:-unknown} changed=${changed}"
  if [[ -n "$upstream_sha" ]]; then
    log "upstream sha=${upstream_sha}"
  fi
  if [[ -n "$main_sha" ]]; then
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
  local upstream_sha main_sha pinned_origin
  # The accepted upstream commit, not a fresh read of the tracking ref.
  # post-rewrite can point that ref at the rebased fork after this runs.
  upstream_sha="$REBASE_UPSTREAM"
  [[ -n "$upstream_sha" ]] || return 1
  if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
    main_sha="$(git rev-parse "refs/heads/$MIRROR_BRANCH")" || return 1
    prepare_owned_checkout "$main_sha" || return 1
    git checkout --quiet "$MIRROR_BRANCH" || return 1
    checkout_still_expected "$main_sha" "refs/heads/$MIRROR_BRANCH" || return 1
  else
    # CI checks out only jkubo. A plain `git checkout main` is DWIM-ambiguous.
    # CAPTURED_ORIGIN was read after fetch and before checkout. Do not reread
    # refs/remotes/$ORIGIN_REMOTE/$MIRROR_BRANCH: a post-rewrite hook may have
    # moved it, and a ref that was absent is not adopted if a hook creates it.
    # Do not point that ref back at the capture to hide the hook. A tag named
    # origin/main is not this commit. The captured object must be an ancestor
    # of the exact upstream commit, or that same commit. A non-ancestor is
    # refused while local main is still absent. Do not create the branch, and
    # do not reset a main that already exists. Presence 0 means the qualified
    # ref was missing at capture. An existing cyclic, dangling, or otherwise
    # unreadable ref refuses before checkout and does not reach this branch.
    if [[ "$CAPTURED_ORIGIN_PRESENT" -ne 1 || -z "$CAPTURED_ORIGIN" ]]; then
      log "origin/$MIRROR_BRANCH does not exist"
      return 1
    fi
    pinned_origin="$CAPTURED_ORIGIN"
    if ! git merge-base --is-ancestor "$pinned_origin" "$upstream_sha"; then
      log "$MIRROR_BRANCH is ${pinned_origin} and upstream is ${upstream_sha}"
      return 1
    fi
    main_sha="$pinned_origin"
    prepare_owned_checkout "$main_sha" || return 1
    git checkout --quiet -b "$MIRROR_BRANCH" "$pinned_origin" || return 1
    MAIN_CREATED=1
    raw_checkout_still_expected "$main_sha" || return 1
    capture_local_snapshot || return 1
    [[ "$SNAP_HEAD_SHA" == "$pinned_origin" && "$SNAP_HEAD_SYM" == "refs/heads/$MIRROR_BRANCH" ]] || return 1
    [[ "$SNAP_OTHER_BRANCHES" == "$OWNED_OTHER_BRANCHES" && "$SNAP_FORK" == "$OWNED_FORK" && "$SNAP_OPS" == "$OWNED_OPS" && "$SNAP_INDEX_FLAGS" == "$OWNED_INDEX_FLAGS" ]] || return 1
    [[ "$SNAP_DIRTY" == "$OWNED_DIRTY" && "$SNAP_STAGED" == "$OWNED_STAGED" && "$SNAP_UNTRACKED" == "$OWNED_UNTRACKED" ]] || return 1
    [[ "$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | awk -v m="refs/heads/$MIRROR_BRANCH" '$1 != m' | sort | git hash-object --stdin)" == "$OWNED_BRANCHES" ]] || return 1
  fi
  # Record the checkout before the fast-forward check. A refusal after this
  # point still owns this tree, so rollback can return to the start branch.
  mark_owned_from_worktree "$main_sha" || return 1
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
  prepare_owned_checkout "$upstream_sha" || return 1
  git merge --ff-only --quiet "$upstream_sha" || return 1
  raw_checkout_still_expected "$upstream_sha" || return 1
  capture_local_snapshot || return 1
  [[ "$SNAP_MAIN" == "$upstream_sha" && "$SNAP_HEAD_SHA" == "$upstream_sha" ]] || return 1
  [[ "$SNAP_OTHER_BRANCHES" == "$OWNED_OTHER_BRANCHES" && "$SNAP_FORK" == "$OWNED_FORK" && "$SNAP_OPS" == "$OWNED_OPS" && "$SNAP_INDEX_FLAGS" == "$OWNED_INDEX_FLAGS" ]] || return 1
  [[ "$SNAP_DIRTY" == "$OWNED_DIRTY" && "$SNAP_STAGED" == "$OWNED_STAGED" && "$SNAP_UNTRACKED" == "$OWNED_UNTRACKED" ]] || return 1
  mark_owned_from_worktree "$upstream_sha" || return 1
}

# Classify one qualified fetched tracking ref after fetch and before checkout.
# git show-ref --exists is 0 when the ref exists, 2 when it is missing, and
# 1 on any other lookup failure. It does not prove the object. Only 2 is
# absence, which clears dest and returns 2. On 0, peel once. A direct ref or
# a symbolic ref that resolves is that commit. A cycle, a dangling ref, a
# failed peel, a lookup error, an unsupported option, or any other status
# refuses before checkout. git show-ref --verify --quiet exit 1 is not
# absence. Git 2.46 added --exists; older Git gets an unsupported status and
# refuses. Callers leave the damaged tracking ref in place.
read_fetched_tracking_commit() {
  local origin_ref="$1" kind="$2" dest="$3" exists_rc=0 oid=""
  if git show-ref --exists "$origin_ref" >/dev/null 2>&1; then
    exists_rc=0
  else
    exists_rc=$?
  fi
  case "$exists_rc" in
    2)
      printf -v "$dest" '%s' ""
      return 2
      ;;
    0)
      if ! oid="$(git rev-parse --verify --end-of-options "${origin_ref}^{commit}")"; then
        die "fetched origin ${kind} exists but its commit cannot be read. Preserving current work and refusing to replay or push."
      fi
      if [[ -z "$oid" ]]; then
        die "fetched origin ${kind} exists but its commit cannot be read. Preserving current work and refusing to replay or push."
      fi
      printf -v "$dest" '%s' "$oid"
      return 0
      ;;
    *)
      die "fetched origin ${kind} existence could not be read. Preserving current work and refusing to replay or push."
      ;;
  esac
}

# Classify refs/remotes/$ORIGIN_REMOTE/$MIRROR_BRANCH after fetch and before
# checkout. Missing stays missing and is not adopted later. The damaged
# tracking ref is not deleted or rewritten. The call stays next to the
# accepted upstream pin, before the first checkout.
capture_fetched_origin_mirror() {
  local origin_ref rc=0
  origin_ref="refs/remotes/${ORIGIN_REMOTE}/${MIRROR_BRANCH}"
  # Capture $? in the false branch. A bare if with no else returns 0 and
  # would hide helper exit 2, refusing a genuinely missing ref.
  if read_fetched_tracking_commit "$origin_ref" mirror CAPTURED_ORIGIN; then
    CAPTURED_ORIGIN_PRESENT=1
    log "captured origin mirror ${CAPTURED_ORIGIN}"
    return 0
  else
    rc=$?
  fi
  if [[ "$rc" -ne 2 ]]; then
    die "fetched origin mirror existence could not be read. Preserving current work and refusing to replay or push."
  fi
  CAPTURED_ORIGIN=""
  CAPTURED_ORIGIN_PRESENT=0
  log "captured origin mirror absent"
}

# Classify refs/remotes/$ORIGIN_REMOTE/$FORK_BRANCH with the same existence
# and peel rule. Only a real missing ref leaves the lease empty. That empty
# value is not replaced from a later read. An existing ref that does not peel
# refuses before checkout. A peeled commit is the immutable fetch-time lease.
capture_fetched_origin_fork() {
  local origin_ref rc=0
  origin_ref="refs/remotes/${ORIGIN_REMOTE}/${FORK_BRANCH}"
  # Same false-branch capture as the mirror. Helper exit 2 is absence.
  if read_fetched_tracking_commit "$origin_ref" fork FORK_LEASE; then
    log "captured origin fork ${FORK_LEASE}"
    return 0
  else
    rc=$?
  fi
  if [[ "$rc" -ne 2 ]]; then
    die "fetched origin fork existence could not be read. Preserving current work and refusing to replay or push."
  fi
  FORK_LEASE=""
  log "captured origin fork absent"
}

cd "$ROOT"
[[ -d .git ]] || die "not a git repo: $ROOT"
command -v python3 >/dev/null || die "Python 3 is required for raw worktree ownership checks."

# Before any checkout. --allow-dirty and --dry-run do not bypass this, and
# the script does not abort an operation it did not start.
refuse_in_progress

# Hidden tracked files are an unsupported mutable input. Refuse before fetch,
# even with --allow-dirty, and leave the flags, index, refs, and bytes intact.
if [[ "$DO_DRY" -eq 0 ]] && [[ "$(index_flags_fp)" != "$(printf '' | git hash-object --stdin)" ]]; then
  die "index has assume-unchanged or skip-worktree flags. Refusing to fetch or replay; inspect the index and tracked files."
fi

# A dirty tree plus a rebase is how you lose work that was never committed.
# Exempt --dry-run: it mutates nothing, so refusing there would make the one
# command that is always safe the one command you cannot run when you most
# want it, which is mid-change.
if [[ "$DO_DRY" -eq 0 && "$ALLOW_DIRTY" -eq 0 ]] && [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty. Commit, stash, or pass --allow-dirty."
fi

# A detached HEAD has no branch name to come back to. Falling back to the
# fork branch replaced that checkout, index, and worktree when a later push
# was rejected. Refuse before fetch, checkout, or any other ref movement.
# --allow-dirty does not bypass this stop.
# Capture the full symbolic ref and strip only refs/heads/. --short can
# print heads/<name> when a tag shares the branch name. Checkout later uses
# the literal branch name; checking out refs/heads/<name> would detach.
if ! start_sym="$(git symbolic-ref -q HEAD)"; then
  die "HEAD is detached. Switch to an intended named branch."
fi
case "$start_sym" in
  refs/heads/?*) START_BRANCH="${start_sym#refs/heads/}" ;;
  *) die "HEAD is detached. Switch to an intended named branch." ;;
esac
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
  behind="$(git rev-list --count "refs/heads/${FORK_BRANCH}..refs/remotes/${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo '?')"
  ahead="$(git rev-list --count "refs/remotes/${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}..refs/heads/${FORK_BRANCH}" 2>/dev/null || echo '?')"
  log "[dry-run] $FORK_BRANCH is $behind behind and $ahead ahead of $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  exit 0
fi

# Baseline for "did someone else touch this clone during fetch". Remote
# tracking refs are allowed to move. Local HEAD, branches, index, worktree,
# and in-progress operations are not.
save_preserved_dirty_paths || die "dirty input could not be read consistently. Preserving it."
raw_checkout_still_expected "$(git rev-parse HEAD)" || die "raw worktree does not match its committed tree before fetch. Preserving it and refusing to replay or push."
save_base_snapshot
log "fetching $UPSTREAM_REMOTE and $ORIGIN_REMOTE"
git fetch --quiet "$UPSTREAM_REMOTE"
git fetch --quiet "$ORIGIN_REMOTE"

# After fetch, before MUTATED and before any checkout. --verify --quiet
# exit 1 is not absence and must not skip the lease.
capture_fetched_origin_fork

# The lease is the peeled fork tip this fetch just observed. It only pins the
# later atomic push. It is not permission to rebase. Absence stays empty.
# The fetched origin tip must already be an ancestor of the local fork tip
# recorded before the fetch.
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

# Fetch can run hooks in this clone. A commit, a dirty index, or a sequencer
# that showed up after the baseline belongs to that other command. Stop
# before this run checks out or rebases, and do not reset what it wrote.
if ! local_matches_base; then
  die "local HEAD, branch, index, worktree, or operation changed during fetch. Refusing to rebase or push."
fi

# Rebase jkubo before moving main. A conflict then has nothing to undo on main.
raw_checkout_still_expected "$BASE_HEAD_SHA" || die "raw worktree does not match its captured committed tree. Preserving it and refusing to replay or push."
# Normalization, exclusive fork merges, and colliding targets are refused
# before any checkout. A later return checkout cannot undo a tree change once
# normalization is unsupported. Cover the starting checkout, the fork tip,
# upstream, and every intermediate replay commit. The attribute readers use
# the path union of those trees and query the working tree, the index, and
# every tree, including a path that tree does not contain. Legacy crlf set
# and crlf=input count as normalization even when text and eol are
# unspecified. -crlf does not. --allow-dirty does not waive that gate or the
# merge gate. A clean filter still allows a same-commit checkout so its hook
# can be observed. A different commit is refused here even when its tree
# matches. Later guards remain.
# Accept the fetched upstream commit once, before any checkout. The object
# is refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH verified as a commit.
# A tag named upstream/main is not that object. Replay history, attributes,
# collisions, the native rebase, mirror checks, and exported upstream
# evidence all reuse REBASE_UPSTREAM. Do not read the tracking ref again
# for authority, and do not move that ref back to hide a hook.
# Capture origin/$MIRROR_BRANCH at the same time. Missing stays missing.
# An existing ref that does not resolve refuses here, before MUTATED.
REBASE_UPSTREAM="$(git rev-parse --verify "refs/remotes/${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}^{commit}")" || die "could not establish replay targets. Preserving current work."
pre_upstream="$REBASE_UPSTREAM"
log "accepted upstream commit ${REBASE_UPSTREAM}"
capture_fetched_origin_mirror
pre_replay_text="$(GIT_NO_LAZY_FETCH=1 git rev-list "$pre_upstream..$FORK_BEFORE")" || die "could not establish replay targets. Preserving current work."
pre_replay=()
if [[ -n "$pre_replay_text" ]]; then mapfile -t pre_replay <<<"$pre_replay_text"; fi
pre_head="$(git rev-parse HEAD)"
# Commits reachable from the fork and not from the accepted upstream. A merge
# in that range is unsupported: plain rebase drops content that exists only
# in the merge. Merges already contained in the accepted upstream are outside
# the range. Read rev-list in this shell so a producer failure refuses.
# Process substitution would hide that status and continue into checkout.
if ! exclusive_merges="$(GIT_NO_LAZY_FETCH=1 git rev-list --merges "${pre_upstream}..${FORK_BEFORE}")"; then
  die "exclusive fork merge history is unsupported for native replay. Preserving current work and refusing to replay or push."
fi
if [[ -n "$exclusive_merges" ]]; then
  die "exclusive fork merge history is unsupported for native replay. Preserving current work and refusing to replay or push."
fi
native_normalization_supported "$pre_head" "$FORK_BEFORE" "$pre_upstream" "${pre_replay[@]}" || die "tracked raw transforms are unsupported for native replay. Preserving current work and refusing to replay or push."
if ! native_transforms_supported "$pre_head" "$FORK_BEFORE" "$pre_upstream" "${pre_replay[@]}"; then
  [[ "$pre_head" == "$FORK_BEFORE" ]] || die "tracked raw transforms are unsupported for native replay. Preserving current work and refusing to replay or push."
fi
checkout_target_clear "$FORK_BEFORE" "$pre_upstream" "${pre_replay[@]}" || die "an intermediate replay target collides with local work or is uncertain. Preserving it and refusing to replay or push."
MUTATED=1
mark_owned_from_worktree "$BASE_HEAD_SHA"
prepare_owned_checkout "$FORK_BEFORE" 1 || die "raw checkout or target paths changed. Preserving them and refusing to replay or push."
log "rebasing $FORK_BRANCH onto $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git checkout --quiet "$FORK_BRANCH"
if ! checkout_still_expected "$FORK_BEFORE" "refs/heads/$FORK_BRANCH"; then
  die "local state changed during checkout. Preserving it and refusing to rebase or push."
fi
mark_owned_from_worktree "$FORK_BEFORE"
# Same accepted object as the pre-checkout pin. The checkout hook may already
# have moved the tracking ref; that ref is not the rebase target.
replay_targets_text="$(GIT_NO_LAZY_FETCH=1 git rev-list "$REBASE_UPSTREAM..$FORK_BEFORE")" || die "could not establish replay targets. Preserving current work."
replay_targets=()
if [[ -n "$replay_targets_text" ]]; then mapfile -t replay_targets <<<"$replay_targets_text"; fi
native_transforms_supported "$FORK_BEFORE" "$REBASE_UPSTREAM" "${replay_targets[@]}" || die "tracked raw transforms are unsupported for native replay. Preserving current work and refusing to replay or push."
# Native replay visits intermediate commit trees even when their paths are
# absent from both final tips. Check that same complete participation set.
checkout_target_clear "$REBASE_UPSTREAM" "${replay_targets[@]}" || die "an intermediate replay target collides with local work or is uncertain. Preserving it and refusing to replay or push."
prepare_owned_checkout "$REBASE_UPSTREAM" || die "raw checkout or replay target paths are uncertain. Preserving them and refusing to replay or push."
OURS_REBASE=1
# Invocation-local. Leave rebase.updateRefs and every other branch untouched.
if ! git rebase --quiet --no-update-refs "$REBASE_UPSTREAM"; then
  restore_branches
  if [[ "$OURS_REBASE" -eq 0 ]] && [[ "$(git rev-parse "refs/heads/$FORK_BRANCH")" == "$FORK_BEFORE" ]]; then
    die "rebase failed. $FORK_BRANCH left untouched at ${FORK_BEFORE}."
  fi
  die "rebase failed with changed local state. Preserving it for inspection."
fi
OURS_REBASE=0
# Git records its finished replay before post-rewrite runs. A later hook
# commit must remain on the fork with its checkout, rather than being adopted.
if [[ "$(git rev-parse "refs/heads/$FORK_BRANCH")" != "$FORK_BEFORE" ]]; then
  replay_entry="$(git reflog show -1 --format='%gs' "refs/heads/$FORK_BRANCH")"
  if [[ "$replay_entry" != 'rebase (finish):'* ]]; then
    die "fork changed after replay, or replay provenance is unavailable. Preserving it and refusing to push."
  fi
fi
raw_checkout_still_expected "$(git rev-parse "refs/heads/$FORK_BRANCH")" || die "raw state changed during rebase. Preserving completed replay and refusing to push."
capture_local_snapshot
if [[ "$SNAP_INDEX_FLAGS" != "$OWNED_INDEX_FLAGS" || "$SNAP_OTHER_BRANCHES" != "$OWNED_OTHER_BRANCHES" || "$SNAP_OPS" != "$OWNED_OPS" || "$SNAP_MAIN" != "$OWNED_MAIN" || "$SNAP_MAIN_PRESENT" != "$OWNED_MAIN_PRESENT" || "$SNAP_HEAD_SYM" != "refs/heads/$FORK_BRANCH" || "$SNAP_DIRTY" != "$OWNED_DIRTY" || "$SNAP_STAGED" != "$OWNED_STAGED" || "$SNAP_UNTRACKED" != "$OWNED_UNTRACKED" ]]; then
  die "local state changed during rebase. Preserving completed replay and refusing to push."
fi
mark_owned_from_worktree "$SNAP_HEAD_SHA" || die "raw state changed during rebase. Preserving completed replay and refusing to push."

log "fast forwarding $MIRROR_BRANCH to accepted upstream $REBASE_UPSTREAM"
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
  if [[ "$main_now" != "$REBASE_UPSTREAM" ]]; then
    fail_rollback "$MIRROR_BRANCH changed from the exact upstream commit. Preserving it and refusing to push."
  fi
  state_still_owned && raw_checkout_still_expected "$OWNED_HEAD_SHA" || fail_rollback "raw local state changed before push. Preserving it and refusing to publish."
  log "pushing $MIRROR_BRANCH and $FORK_BRANCH"
  # One atomic push. main has no force flag, so a non-fast-forward is rejected.
  # jkubo's lease is the SHA observed at fetch, not the remote-tracking ref at
  # push time. --force is never used.
  if ! git push --atomic \
      --force-with-lease="${FORK_BRANCH}:${FORK_LEASE}" \
      "$ORIGIN_REMOTE" \
      "${main_now}:refs/heads/${MIRROR_BRANCH}" \
      "${fork_now}:refs/heads/${FORK_BRANCH}"; then
    fail_rollback "push rejected. Completed local replay, mirror updates, and operator work were preserved."
  fi
  # Commit point. fork_now and main_now are the objects the refspec uploaded.
  # A pre-push hook may have added a later local commit after this capture.
  # Nothing after this line may roll these SHAs back or report a different one.
  PUBLISHED=1
  PUBLISHED_FORK="$fork_now"
  PUBLISHED_MAIN="$main_now"
  log "pushed"
else
  log "not pushed (pass --push)"
fi

# Publication may leave a later normal hook commit on a named branch. Its
# committed bytes are safe to leave on that name; uncommitted raw changes,
# index/operation changes or target-path collisions must stop return checkout.
return_branch="$FORK_BRANCH"
if [[ -n "$START_BRANCH" ]] && git show-ref --verify --quiet "refs/heads/$START_BRANCH"; then
  return_branch="$START_BRANCH"
fi
return_sha="$(git rev-parse "refs/heads/$return_branch")"
raw_checkout_still_expected "$(git rev-parse HEAD)" || die "raw state changed before return checkout. Preserving current work; published=$PUBLISHED."
capture_local_snapshot
return_heads="$SNAP_BRANCHES"
return_current="$SNAP_HEAD_SHA"
if [[ "$SNAP_HEAD_SYM" == DETACHED || "$SNAP_OPS" != "$OWNED_OPS" || "$SNAP_INDEX_FLAGS" != "$OWNED_INDEX_FLAGS" || "$SNAP_DIRTY" != "$OWNED_DIRTY" || "$SNAP_STAGED" != "$OWNED_STAGED" || "$SNAP_UNTRACKED" != "$OWNED_UNTRACKED" ]] || ! raw_checkout_still_expected "$return_current" || ! checkout_target_clear "$return_sha" || ! native_transforms_supported "$return_current" "$return_sha"; then
  die "raw state or target paths changed before return checkout. Preserving current work; published=$PUBLISHED."
fi
if ! git checkout --quiet "$return_branch"; then
  if [[ "$PUBLISHED" -eq 1 ]]; then
    die "checkout of $return_branch failed after the push already succeeded. Published $FORK_BRANCH ${PUBLISHED_FORK} and $MIRROR_BRANCH ${PUBLISHED_MAIN} were left in place."
  fi
  die "checkout of $return_branch failed. Preserving current work."
fi
raw_checkout_still_expected "$return_sha" || die "raw state changed during return checkout. Preserving it; published=$PUBLISHED."
capture_local_snapshot
if [[ "$SNAP_HEAD_SHA" != "$return_sha" || "$SNAP_HEAD_SYM" != "refs/heads/$return_branch" || "$SNAP_BRANCHES" != "$return_heads" || "$SNAP_OPS" != "$OWNED_OPS" || "$SNAP_INDEX_FLAGS" != "$OWNED_INDEX_FLAGS" || "$SNAP_DIRTY" != "$OWNED_DIRTY" || "$SNAP_STAGED" != "$OWNED_STAGED" || "$SNAP_UNTRACKED" != "$OWNED_UNTRACKED" ]] || ! raw_checkout_still_expected "$return_sha"; then
  die "local state changed during return checkout. Preserving it; published=$PUBLISHED."
fi
log "done"
