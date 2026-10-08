# jkubo fork of claude-code

Personal fork of [`anthropics/claude-code`](https://github.com/anthropics/claude-code),
kept current with upstream the same way `jkubo/grok-build` is.

## Read this first: what this fork can and cannot change

**Upstream carries no CLI source.** `anthropics/claude-code` is the plugin
marketplace, the examples, the devcontainer, the docs, and the issue-triage
automation under `scripts/`. The Claude Code binary itself ships as a bundled
npm package. On this machine `~/.local/bin/claude` is a three line shim that
runs `mise use -g claude`.

So, unlike `jkubo/grok-build` (a real Rust workspace where a patch changes the
product), **nothing committed here changes how the `claude` CLI behaves.**
That is the single most important thing to know before spending time in this
tree, and it is why this file leads with it.

What this fork IS good for, and it is not nothing:

| Surface | Effect |
|---------|--------|
| `plugins/*` | Real. These are the plugins Claude Code loads. `feature-dev`, `code-review`, `hookify`, `pr-review-toolkit`, `agent-sdk-dev` and friends all come from here. |
| `.claude-plugin/marketplace.json` | Registers a plugin so it is installable. A new plugin needs an entry here. |
| `examples/*` | Reference settings, hooks, gateway and MDM configs. |
| `.devcontainer/` | The containerised dev environment. |

Behaviour changes that do NOT belong here, because they belong to the live
config surface instead: hooks (`~/.claude/settings.json`), skills, MCP servers,
output styles, statusline, and the Agent SDK. Those survive every upstream
release; a fork does not make them any more durable.

**Do not patch the npm bundle.** It is minified, it breaks on every release,
and it fights `mise use -g claude`, which updates underneath you. That is a
treadmill, not a fork.

## Branches

| Branch | Meaning |
|--------|---------|
| `main` | Fast forward mirror of `anthropics/claude-code` `main`. No fork delta, ever. |
| `jkubo` | Default. Upstream plus local plugins and this tooling. |

Keeping `main` clean is what makes the rebase cheap: upstream advances, `main`
fast forwards, and only `jkubo` ever has to replay.

## Keep current

```sh
./scripts/sync-upstream.sh              # fetch + rebase jkubo onto the accepted upstream commit
./scripts/sync-upstream.sh --push       # also update origin/jkubo and origin/main
./scripts/sync-upstream.sh --dry-run    # show what would happen, touch nothing
./scripts/test-sync-upstream.sh         # run the script against disposable local remotes
```

The suite reads its unchanged em dash fixture as UTF-8. Run it with a UTF-8
locale. `LC_ALL=C` remains a limitation of that scan.

Happy path is `git rebase --no-update-refs` of the `jkubo` commits onto the
upstream commit accepted before checkout. The flag is invocation-local. It
does not rewrite `rebase.updateRefs` or any other config byte, and it does
not move a checkpoint branch or the operator branch. Only the branch being
rebased advances. The private failed-replay comparison uses the same flag, so
another local branch cannot make that comparison diverge. If replay fails in
a conflict this run still owns, the script aborts that rebase and returns to
the starting named checkout when safe. An unexpected hook-created commit,
file, ref, or operation is preserved for inspection. The script never resets
named refs to erase completed replay. When a later mirror update or push
fails, completed local replay, local mirror updates, and all operator commits
remain. A rejected atomic push changes neither remote target. Resolve the
failure, inspect the retained local history, then re run.

The fetched upstream commit is accepted once, after fetch and before the
first checkout. That object is the commit at `refs/remotes/upstream/main`.
A tag named `upstream/main` is not the accepted commit, and the short name
is not resolved again. Replay history, effective attributes, target
collisions, the native rebase, mirror ancestry, missing-main creation,
fast-forward, and the printed upstream SHA all use that same commit. A
normal hook may afterwards move `refs/remotes/upstream/main`. That tracking
ref is not read again for authority, and the script does not point it back
at the accepted commit to hide the hook. Before the commit is accepted,
including when `FORK_SYNC_TOKEN` is missing and the run stops before fetch,
diagnostics may still report the commit already stored at
`refs/remotes/upstream/main`. A missing tracking ref stays unreported. The
upstream remote's own `main` is left untouched.

Branch OID, tree, dry-run, and diagnostic reads use `refs/heads/` or
`refs/remotes/`. The return branch is the full symbolic HEAD with only the
`refs/heads/` prefix removed. Checkout uses that literal branch name, so
HEAD stays attached; checking out `refs/heads/<name>` would detach. A tag
that shares a branch name does not choose the checkout or the preflight
tree. Those tree reads use the captured commit id.

Mutable runs require Python 3 for batched raw filesystem and committed-blob
reads. Every ownership adoption checks the captured committed target against
actual raw bytes, type and mode, through no-follow descriptors and stable stat
metadata. The check runs before normalized Git evidence can refresh a foreign
index, and again before checkout, replay, mirror fast-forward, publication or
return checkout. Clean filters and a subsequent `git add` cannot make hidden
operator bytes belong to this run. The index snapshot hashes complete native
stage tuples without writing a tree or refreshing the index. Normal hooks and
filters continue to run.

With `--allow-dirty`, only explicit dirty paths captured before fetch may
differ from committed blobs. Their exact raw state and original committed
path provenance must remain unchanged. Filter-hidden clean bytes receive no
exception. Missing, transformed, unreadable or uncertain state stops the run
and leaves current work for inspection. Existing untracked or ignored paths
at an upcoming committed checkout or upstream replay target also stop it
before Git can overwrite them. File/directory transitions and symlinked parent
paths are treated conservatively. These checks provide no lock against a
change after the last observation.

Replay checks include every captured intermediate fork commit tree, including
paths introduced and then removed before the final fork tip. An ignored file
at such a transient path still belongs to the operator. Collision and
effective attribute checks use that same committed history participation,
including the starting checkout, the fork tip, and upstream. Unavailable
objects or uncertain target paths leave current work intact.

Those checks run before the first checkout. The path set is the union of the
starting checkout, the fork tip, the accepted upstream, and every intermediate
replay commit. That same union is queried against the working tree, the cached
index, and each of those committed trees, including a path the source tree
does not contain. An upstream `*.dat crlf` or `*.dat crlf=input` rule therefore
applies to a fork-only `payload.dat` and is refused before checkout. Text, eol,
encoding, ident, legacy `crlf` or `crlf=input`, or automatic line-ending
normalization on any path in that union is refused before this run switches
branches or deletes a tracked path. A colliding ignored or untracked path in
that same set is refused then too. Info and global attributes still apply.
A configured clean or smudge filter is refused before
checkout when the captured HEAD commit and the fork commit differ, including
when those commits share one tree. The same filter still allows that checkout
when the captured HEAD commit and the fork commit are equal, because that is
how a normal hook's filtered bytes are observed. The filter stays unsupported
for native replay and is refused before rebase. If the checkout only moved
symbolic HEAD between two names of the same commit, that refusal puts symbolic
HEAD back without a second transforming checkout. A different commit keeps
the captured symbolic HEAD, because the filter refusal happens before
checkout. Refusal does not disable hooks or filters. A driver
configured only on a path absent from every participating tree is inactive
and does not block replay. The full attribute check runs again before native
replay.

When the pre-checkout checks pass, the first fork checkout still runs its
normal hook and then verifies raw state. A hook that adds filtered bytes and
stages their normalized contents is refused there with its raw file and index
intact.
Filtered-conflict tests now verify prospective unsupported-input refusal;
their conflict hooks do not run on this source. Earlier actual filtered
conflicts and abort results remain historical evidence. Unfiltered native
conflict/abort controls still run.

This repository's inherited `.gitattributes` sets `text=auto` and `eol=lf`.
That normalization can hide a hook's raw CRLF edit even with no external
filter and `core.autocrlf=false`. An advancing automated sync therefore stops
at the unsupported-input guard before checkout. Inspect and perform such
replay manually; a local passing fixture suite does not establish advancing
cron availability for this inherited configuration.

Legacy `crlf` is the same gate. `crlf` set aliases `text`, and `crlf=input`
aliases `eol=lf`. `git check-attr` still reports `text` and `eol` as
unspecified for those aliases, while `git add` normalizes CRLF to LF even
with `core.autocrlf=false`. Both are refused before checkout. `-crlf` aliases
`-text`. With `core.autocrlf=false`, `-crlf` keeps the committed CRLF bytes
and remains a supported replay. `--allow-dirty` does not waive this refusal.

Exclusive fork merges require manual inspected handling. The script refuses
before checkout when a merge commit is reachable from the recorded fork tip
and not from the accepted upstream commit. Plain `git rebase` drops content
that exists only in that merge. A merge already contained in the accepted
upstream does not block a later linear exclusive fork. If that history cannot
be read, the run stops the same way and leaves the checkout untouched.
`--allow-dirty` does not waive this refusal. The script does not rewrite
merge topology and does not claim those payloads were replayed.

The regression fixture records the official commit it was replayed onto in
`UPSTREAM_PIN`. This candidate pins `3deb873687379f0c199a69fdaccc65f0865f7a29`.
The previous public candidate pinned `71cdddec623889d38af14b7a489670a03186f659`.
The pin moved forward with the official base. The fork delta is still the sync
workflow, this file, and the two sync scripts. Paths outside that delta stay
the official blobs, modes, and types from the pinned commit.

A change to local HEAD, a local branch, the index, actual tracked or untracked
file bytes, or an in-progress operation during fetch stops the script before
checkout, rebase, or push. A same-status dirty edit is detected. The first
checkout must still name the captured fork tip before replay starts. A
failed rebase is aborted only while its original fork ref and replay metadata
match this run, with Git's replay reflog and original `AUTO_MERGE` conflict
bytes intact, the complete expected conflict-stage matrix (including stage
presence) and remaining staged entries unchanged, and no unexpected files or
other operation. Before abort, every tracked path is compared with its stored
`AUTO_MERGE` blob using raw reads, without clean or text filters. File type,
regular-file tree permissions, and stable device/inode/read metadata must also
match. Missing, unreadable, transformed, or uncertain paths leave the conflict
operation and local work intact. Filters and hooks continue to run normally. Native `git merge-tree` derives those stages from committed
trees; unavailable or uncertain reconstruction leaves the operation intact.
Configured external merge drivers also leave it intact rather than run their
commands again only to check ownership.
The complete operation directories and operation pseudorefs must also match
a separate native Git replay from the original committed fork and upstream
inputs. That reference uses an empty template, isolated configuration, and
its own worktree, index, refs, and new objects; the real replay still runs its
normal hooks and filters. Added or missing entries, different bytes, types,
or modes, including a valid pending `exec` todo instruction, prevent abort.
`FETCH_HEAD` and `COMMIT_EDITMSG` survive abort and are excluded from that
operation comparison. If a custom configuration or earlier replay timestamps
prevent Git from reproducing the detached commit and full operation exactly,
leave the paused operation for inspection. This check provides no lock against
a later concurrent change.
Uncertain state,
including a failed replay with autostashed dirty input, is left for the
operator rather than discarded. A changed fork needs Git's final replay
reflog entry; an extra post-rewrite commit or unavailable reflog stops before
the mirror checkout. Hooks run normally.

`assume-unchanged` and `skip-worktree` flags can hide tracked changes from Git
status and diff. Mutable runs refuse these preexisting flags before fetch,
including with `--allow-dirty`, and preserve the exact index, flags, refs, and
file bytes. New hidden flags during fetch, checkout, or replay also stop the
run before it adopts that state. `--dry-run` still reports without replay.
Inspect those tracked files and index flags before deciding how to continue.

A successful pre-rebase hook can add a normal commit before Git refuses its
final branch update. That exact operator commit remains on its named branch,
while Git may already have transformed the checkout and index. Inspect the
retained named history and current operation before continuing; restoring
those checkout files is an operator decision.

Once `git push --atomic` returns success, the fork and `main` SHAs captured
for that push are the commit point. A checkout that fails afterwards exits
nonzero and does not move those published tips back. A pre-push hook can add
a later local commit after the objects that were uploaded. That later commit
stays on its named branch. The printed fork SHA is the commit the push
uploaded, not a later local commit and not the tip from the start of the run.

The exit path prints the fork SHA and `changed=true` or `changed=false`.
After a successful push, the SHA is the uploaded fork commit and `changed`
compares it with the fork tip from the start of the run. Otherwise the SHA
is the local `jkubo` tip at exit, and `changed` is true when that tip differs
from the start of the run. `main` is updated only when that update is a fast
forward onto the exact upstream commit accepted before checkout, not onto a
later read of `refs/remotes/upstream/main`. A `main` that is ahead of
upstream, or has diverged, is left where it was.

When local `main` does not exist, the commit at `refs/remotes/origin/main`
is captured after fetch and before the first checkout, together with the
accepted upstream commit. A tag named `origin/main` is not that commit. The
ancestry check still runs after replay, before the branch is created or
checked out. The captured object must already be an ancestor of the upstream
commit accepted before checkout, or be that same commit. The local branch is
created from the captured object, not from a later read of the tracking ref.
A normal hook may move `refs/remotes/origin/main` after replay. That move does
not redefine the captured object, and the script does not point the tracking
ref back to hide the hook. A ref that was absent at capture stays absent: a
hook that creates it later is not adopted. Absence is only exit 2 from
`git show-ref --exists`. Git 2.46 added that option: exit 0 means the ref
exists, exit 2 means it is missing, and exit 1 means the lookup failed.
Existence does not prove the object. On exit 0 the script peels the ref once with
`git rev-parse --verify --end-of-options ref^{commit}` and captures that
commit once. A direct ref or a symbolic ref that resolves is captured that
way. `refs/remotes/origin/jkubo` uses this same existence and peel rule
before checkout. Only exit 2 leaves its fetch-time lease empty. A cyclic ref, a dangling
symbolic ref, any other existing ref that does not peel, a lookup failure,
or any other status refuses before checkout. `git show-ref --verify --quiet`
exit 1 is not absence. That status is also what Git returns for a ref that
exists and does not resolve. Git older than 2.46 has no `--exists` option.
An unsupported option refuses before checkout. This script does not claim
the distinction on older Git. The damaged tracking ref is left as the hook
wrote it. The refusal does not check out, replay, push, or create `main`.
A missing ref does not take this refusal. A captured
`refs/remotes/origin/main` that is not an ancestor is refused while local
`main` is still absent. That ancestry check stays after replay and before
creation. Completed `jkubo` replay stays
on its name, the starting branch and its raw checkout are restored, and
neither remote head is published. A completed native replay can change
`ORIG_HEAD` and the binary index. The refusal preserves semantic index stages,
index flags, and the operator's raw bytes and modes.

### Remote commits on origin/jkubo

The script records the local `jkubo` tip, fetches, then classifies
`refs/remotes/origin/jkubo` before any checkout. `git show-ref --exists`
exit 0 means the ref exists, exit 2 means it is missing, and exit 1 means
the lookup failed. Only exit 2 is absence. That empty lease is not filled
in later. Exit 0 does not prove the object. The script peels the ref once
with `git rev-parse --verify --end-of-options refs/remotes/origin/jkubo^{commit}`
and keeps that commit as the fetch-time lease. A direct ref or a symbolic
ref that resolves is that commit. A cycle, a dangling symbolic ref, any
other existing ref that does not peel, a lookup failure, an unsupported
option, or any other status refuses before checkout. `git show-ref
--verify --quiet` exit 1 is not absence. Git 2.46 added `--exists`, which
this script already requires for `origin/main`. An unsupported status
refuses before checkout. The damaged tracking ref is left in place. The
refusal does not check out, replay, create `main`, or push.
`--allow-dirty` does not waive it.

When the peel succeeds, that commit has to be contained in the recorded
local tip before the script checks out, rebases, or moves `main`.

Two cases continue. The fetched tip and the local tip are the same commit.
Or the local tip already has commits the fetched tip does not have yet. The
later push uses the fetched SHA as its lease, so those local commits can be
published on top of the remote the fetch actually saw.

The script stops when the fetched tip contains a commit the recorded local
tip does not. The remote branch moved ahead of this clone before fetch, or
the two histories diverged. The exit is before checkout. Local `jkubo`,
local `main`, and `origin/main` stay on the commits they had, and the peeled
`origin/jkubo` stays on the fetched commit. The index, the worktree, and any
cherry-pick, revert, merge, or rebase already in progress stay as they were.
Fetch updates remote-tracking refs, which is how the new tip was observed.

Reconcile that remote work, then run the script again. After the failed run,
`git log jkubo..origin/jkubo` lists the commits the local tip lacks.

When local `jkubo` has nothing of its own past the previous remote tip,
fast-forward it to the fetched tip and run the sync again:

```sh
git merge --ff-only origin/jkubo
```

When both sides have commits the other lacks, read both ranges
(`git log jkubo..origin/jkubo` and `git log origin/jkubo..jkubo`) and combine
them in the worktree yourself. A merge or a rebase you run and inspect is
that step. Run `./scripts/sync-upstream.sh` again only after local `jkubo`
contains the fetched `origin/jkubo` commit.

Publishing a local history that was already rebased onto a remote tip you
have read is outside this script. Do that as its own reviewed push of `main`
and `jkubo` together, with the lease set to the exact `origin/jkubo` SHA
observed for that push. This script does not grow a bypass for that case.

A cherry-pick, revert, merge, or rebase already in progress stops the script
the same way, before checkout. A multi-commit cherry-pick whose first commit
is empty leaves `CHERRY_PICK_HEAD` and `.git/sequencer` while
`git status --porcelain` prints nothing. A paused revert leaves `REVERT_HEAD`,
`.git/sequencer`, or both, and can be just as quiet. The script does not
abort that operation. Finish it or abort it yourself, then re run.
`--allow-dirty` does not bypass this stop.

HEAD has to be a named branch. A detached HEAD stops the script before fetch,
checkout, or any other ref movement, including `--dry-run` and
`--allow-dirty`. Switch to the named branch you intend to come back to, then
re run. The script does not guess `jkubo`: checking that branch out would
replace the detached commit, index, and worktree.

Upstream does not accept external PRs for the bundled plugins, and the CLI is
not open source, so **do not open a PR against `anthropics/claude-code`** from
this tree. File an issue there instead if something is genuinely upstream's bug.

### Automation

`.github/workflows/sync-upstream.yml` runs the rebase daily and pushes both
branches when the rebase is clean. A conflicting day is left for a human,
which is the correct failure mode for a tree nobody is watching.

The push contains whatever `.github/workflows` files upstream changed.
`GITHUB_TOKEN` is a GitHub App installation token for this job. GitHub
rejects a push that creates or updates workflow files unless the token has
the Workflows permission. This workflow does not grant that permission to
`GITHUB_TOKEN`. The job permission is `contents: read`. Checkout persists
`FORK_SYNC_TOKEN` and the push uses that credential:

```yaml
token: ${{ secrets.FORK_SYNC_TOKEN }}
```

The workflow refuses to continue when that secret is empty or whitespace,
and it does so before checkout. The sync script checks again, before it
fetches or moves a branch, when `FORK_SYNC_TOKEN_REQUIRED=1`. The workflow
sets that variable. The secret value is not printed.

#### Fine-grained token

Use a fine-grained personal access token. Do not install a broader admin or
delete token as this secret. GitHub documents the creation form and these
query parameters (`name`, `description`, `target_name`, `expires_in`, and
one parameter per permission). This is the prepared link:

```text
https://github.com/settings/personal-access-tokens/new?name=Claude+Code+fork+sync&description=Daily+upstream+sync+for+jkubo%2Fclaude-code&target_name=jkubo&expires_in=90&contents=write&workflows=write
```

On that form set Resource owner to `jkubo`, Repository access to **Only
select repositories**, and select only `jkubo/claude-code`. Repository
selection is not a documented URL parameter, so the link does not do it.

From the fine-grained token documentation checked on 2026-10-08:

| Permission | Level to grant | Why |
|------------|----------------|-----|
| Contents | `write` (includes read) | HTTP git fetch and push |
| Workflows | `write` only | edit files under `.github/workflows`. GitHub's example text for `workflows=write` is the permission to edit workflow files. The table has no Workflows read level. |

Grant nothing else. No organization permissions. No account permissions.
This is a user-owned repository, and no organization policy is changed.

GitHub documents that every fine-grained token also has read-only access to
all public repositories. That is platform behavior. Write access stays on
the selected repository.

GitHub's documented `contents=read` example also includes Metadata read.
[UNVERIFIED: this session did not open the live generate page for the
combined `contents=write` and `workflows=write` URL.] Read the summary
before generating. Stop if any write other than Contents and Workflows is
listed. Metadata read is the expected extra.

Store the value when `gh` prompts. Do not commit it, and do not paste it
into a chat or a file in this tree:

```sh
gh secret set FORK_SYNC_TOKEN --repo jkubo/claude-code
```

The secret was empty on the 2026-10-08 re-entry check recorded by the
operator plan. This clone does not set it. `scripts/test-sync-upstream.sh`
pushes only to local scratch remotes. A passing local run is not a GitHub
Actions run. The daily workflow stays red until that secret exists.

#### GitHub App alternative

The platform allows a GitHub App with no permissions until some are
selected. The permissions guide says Contents is what lets an installation
token authenticate for HTTP git, and Workflows is what lets it edit
`.github/workflows`. Install it on the personal account. The install flow
offers **Only select repositories**; select only `jkubo/claude-code`. Grant
no organization permissions and no account permissions.

[UNVERIFIED: the registration form's exact Workflows access-level label was
not clicked through in this session. The documented requirement is the
Workflows repository permission in order to edit workflow files.]

[UNVERIFIED: installation access token lifetime was not re-checked against
current docs in this session.] This workflow does not mint an app token. It
reads `FORK_SYNC_TOKEN`. Put an installation token in that secret only when
its lifetime covers the daily run. Otherwise mint one inside the job from
an app id and a private key, which is a different workflow than the one
checked in here.

## Inherited workflows

A fork inherits upstream's Actions. The duplicate, lock, and sweep lifecycle
workflows are on a `schedule`, so they would run in this fork even though
issues are disabled. They are intentionally disabled at the repository
level, not deleted:

- `auto-close-duplicates.yml`
- `lock-closed-issues.yml`
- `sweep.yml`

`lock-closed-issues.yml` and `sweep.yml` do not both require Anthropic
secrets. Lock uses the workflow `issues: write` permission. Sweep uses
`secrets.GITHUB_TOKEN` with that same permission. `auto-close-duplicates.yml`
also passes `secrets.STATSIG_API_KEY`. The disablement is the fork's
schedule setting, not a claim that every one of these workflows needs an
Anthropic secret.

Disabled rather than deleted on purpose. Deleting them would put fork delta
on files upstream actively edits, so every upstream change to one of them
becomes a rebase conflict, forever, for no benefit. A repo setting is
invisible in the tree, which is the one drawback, and is why it is written
down here.

To check or change:

```sh
gh workflow list --repo jkubo/claude-code --all
gh workflow disable <file>.yml --repo jkubo/claude-code
```

The remaining upstream workflows are triggered by issue and PR events. This
fork receives none, so they never run.

## Adding a local plugin

1. Create `plugins/<name>/` following the layout of an existing plugin.
2. Add an entry to `.claude-plugin/marketplace.json`.
3. Commit on `jkubo`, never on `main`.

Keep local plugins in their own commits, separate from any upstream cherry
pick. The rebase replays commits, so one concern per commit is what keeps a
conflicting day survivable.

## Commit hygiene

This is a public fork of an Anthropic repository. Commits here follow the same
rule as any upstream facing work: author as
`Jay Kubo <6161465+jkubo@users.noreply.github.com>`, no AI co author trailer,
no em dashes, imperative subject lines.
