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
./scripts/sync-upstream.sh              # fetch + rebase jkubo onto upstream/main
./scripts/sync-upstream.sh --push       # also update origin/jkubo and origin/main
./scripts/sync-upstream.sh --dry-run    # show what would happen, touch nothing
./scripts/test-sync-upstream.sh         # run the script against disposable local remotes
```

Happy path is a plain `git rebase` of the `jkubo` commits onto `upstream/main`.
If that conflicts, or the push is rejected, the script restores both `jkubo`
and `main` to the SHAs from the start of the run and exits. It does not leave
a half finished rebase. Resolve by hand, then re run.

The exit path prints the full fork SHA and `changed=true` or `changed=false`.
`changed` is true only when `jkubo` ended on a different commit than it started
on. `main` is updated only when that update is a fast forward onto the exact
upstream commit. A `main` that is ahead of upstream, or has diverged, is left
where it was.

### Remote commits on origin/jkubo

The script records the local `jkubo` tip, fetches, then reads the fetched
`origin/jkubo` tip. That fetched commit has to be contained in the recorded
local tip before the script checks out, rebases, or moves `main`.

Two cases continue. The fetched tip and the local tip are the same commit.
Or the local tip already has commits the fetched tip does not have yet. The
later push uses the fetched SHA as its lease, so those local commits can be
published on top of the remote the fetch actually saw.

The script stops when the fetched tip contains a commit the recorded local
tip does not. The remote branch moved ahead of this clone before fetch, or
the two histories diverged. The exit is before checkout. Local `jkubo`,
local `main`, `origin/jkubo`, and `origin/main` stay on the commits they
had. The index, the worktree, and any cherry-pick, revert, merge, or rebase
already in progress stay as they were. Fetch updates remote-tracking refs,
which is how the new tip was observed.

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

A fork inherits upstream's Actions. Three of them are on a `schedule`, so they
fire here regardless of whether this fork has any issues, and they need
Anthropic secrets that do not exist in this repo. They were **disabled at the
repository level**, not deleted:

- `auto-close-duplicates.yml`
- `lock-closed-issues.yml`
- `sweep.yml`

Disabled rather than deleted on purpose. Deleting them would put fork delta on
files upstream actively edits, so every upstream change to one of them becomes a
rebase conflict, forever, for no benefit. A repo setting is invisible in the
tree, which is the one drawback, and is why it is written down here.

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
