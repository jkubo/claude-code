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
```

Happy path is a plain `git rebase` of the `jkubo` commits onto `upstream/main`.
If that conflicts the script aborts and leaves `jkubo` exactly where it was,
rather than leaving you in a half finished rebase. Resolve by hand, then re run.

Upstream does not accept external PRs for the bundled plugins, and the CLI is
not open source, so **do not open a PR against `anthropics/claude-code`** from
this tree. File an issue there instead if something is genuinely upstream's bug.

### Automation

`.github/workflows/sync-upstream.yml` runs the rebase daily and pushes both
branches. It only pushes when the rebase is clean; a conflicting day is left
for a human, which is the correct failure mode for a tree nobody is watching.

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
