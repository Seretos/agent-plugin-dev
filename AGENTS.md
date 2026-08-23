# agent-plugins (project root)

A modular plugin platform for AI coding agents (Claude Code et al.). Each plugin is a self-contained git repository; a central `agent-marketplace` repo registers them all. This directory itself is a meta-repo (`Seretos/agent-plugin-dev`) that bundles the dev workspace for the plugin maintainers.

## Tool priority

Skills and MCP tools take priority over raw file tools — and this **explicitly overrides** the generic harness default that says "prefer the dedicated file/search tools (Glob/Grep/Read)". When a skill or MCP tool covers the task, reach for it first; fall back to raw Glob/Grep/Read only when none applies.

Concretely: any *"where is X defined / what does the code support / which Y exist / how does X work / find the callers of X"* question is a **code-understanding task → use the matching skill first** (e.g. the `serena-wrapper` symbol-aware tools), never raw Glob/Grep/Read.

## Layout

```
agent-plugin-dev/             # this directory — meta-repo Seretos/agent-plugin-dev
├── workspace.json            # manifest of sub-repos + mcp-test symlinks
├── scripts/init.ps1|.sh      # bootstrap: clone sub-repos + create symlinks
├── agent-marketplace/        # own repo: Seretos/agent-marketplace (gitignored here)
│                             # The registry. Metadata only, no plugin code.
├── plugins/                  # all gitignored here
│   ├── agent-vdesktop/       # own repo: Seretos/agent-vdesktop
│   ├── agent-vdesktop-skill/ # own repo: Seretos/agent-vdesktop-skill
│   ├── agent-project-issues/ # own repo: Seretos/agent-project-issues
│   └── agent-worktree/       # own repo: Seretos/agent-worktree
├── extensions/               # all gitignored here — extensions for OTHER apps
│   └── obsidian-memory-gatekeeper/  # own repo: Seretos/obsidian-memory-gatekeeper
├── mcp-test/                 # local marketplace (directory source) for daily dev
└── prod-test/                # test setup against the real GitHub marketplace
```

The `plugins/` folder is intentionally flat — no rigid mcp/ vs skill/ split. A plugin's `plugin.json` declares whether it carries an MCP server, skills, slash commands, hooks, or any mix.

`extensions/` vs `plugins/`: `plugins/` holds extensions for **coding agents** (Claude Code et al., distributed via the marketplace). `extensions/` holds extensions for **other applications** — e.g. an Obsidian plugin like `obsidian-memory-gatekeeper`. Extensions are independent sub-repos like everything else (registered in `workspace.json`, gitignored here), but they don't take part in the agent-marketplace release flow.

## Naming convention

`Seretos/agent-{feature}`. The feature names the domain, not the content type. So `agent-vdesktop` (the domain) — not `agent-vdesktop-mcp` (the content type), since the same repo may later add skills or commands.

If a single domain needs separate release cadences (e.g. an MCP and a textual-only skill that should ship independently), then a suffix is fine: `agent-vdesktop-skill` alongside `agent-vdesktop`.

The marketplace itself is the only repo without a feature suffix: `Seretos/agent-marketplace`.

## Release flow (cross-repo, at a glance)

1. Plugin maintainer triggers the `release` workflow in the plugin's repo with a `version` input (e.g. `0.0.2`).
2. The workflow stamps the version, builds artifacts, force-pushes an orphan `release` branch containing only install-ready files, creates the `v0.0.2` tag and a GitHub Release.
3. The same workflow POSTs a `repository_dispatch` event to `agent-marketplace` carrying the plugin metadata. (Direct POST is used because tags created via `GITHUB_TOKEN` don't trigger downstream workflows.)
4. In `agent-marketplace`, `update-registry.yml` patches `.claude-plugin/marketplace.json` and opens a PR on `plugin-update/{name}-v{version}`.
5. Human review + merge → entry is live.

End users install via `/plugin marketplace add Seretos/agent-marketplace` and `/plugin install <name>@agent-marketplace`.

## Per-repo context

Each subdirectory has its own `AGENTS.md` with detail on conventions, files, and pipelines:
- `agent-marketplace/AGENTS.md` — marketplace.json schema and dispatch flow
- `plugins/agent-vdesktop/AGENTS.md` — MCP server architecture, build pipeline

## Setting up a new machine

1. `git clone git@github.com:Seretos/agent-plugin-dev.git`
2. `cd agent-plugin-dev`
3. `./scripts/init.ps1` (Windows) or `./scripts/init.sh` (Linux/macOS). If Windows symlink creation fails, the script prints the `New-Item` commands to run from an elevated PowerShell.
4. Optional: own `.claude/settings.local.json` with extra `enabledPlugins` / `permissions`. The file is gitignored — overrides the committed `settings.json` baseline.

## Conventions for agents working here

- **The project root IS a git repo** (`Seretos/agent-plugin-dev`). The 4 sub-repos under `agent-marketplace/` and `plugins/` are independently versioned and gitignored here — don't try to `git add` their content at the root level. Edits inside a sub-repo go through its own git history (cd into the sub-repo first).
- **Local plugin testing requires launching Claude from `mcp-test/`.** The mcp-test marketplace points at the symlinked local plugin paths, so any branch checked out under `plugins/<name>/` is picked up on session start (and on `/reload-plugins`). A Claude session launched from elsewhere uses the cached version from the real `agent-marketplace` registry and won't see your local changes.
- Each subdirectory under `plugins/` and `agent-marketplace/` is an independent repo with its own remote, history, and CI.
- The user does the GitHub-side actions (repo creation, secret setup, pushing). Don't push or create remote artifacts unless explicitly asked.
- Marketplace tags are NOT used. `{plugin-name}--v{version}` tags were tried early and removed — Claude Code resolves versions from marketplace.json's content, not from tags on the marketplace repo.
- `**/settings.local.json` is gitignored repo-wide. Committed baselines live in `settings.json`; user-specific extras go in `settings.local.json`.

## Board columns are the state

All projects share one GitHub Projects v2 board (#2), so a column change is visible ecosystem-wide and is never a local affair. The columns are the state machine; everything else is commentary.

| column | meaning | who moves in |
|---|---|---|
| Backlog | everything new (`create_ticket` default) | anyone |
| Planned | bundled and clarified, no open questions | gatekeeper skill (agent) |
| Todo | released for the run — the only column the run sees | human only |
| Doing | package dispatched | run skill |
| Review | PR open; CI running, red, or awaiting merge | run skill |
| Done | merged, CI green | run skill |
| Question | run escalated; the question is a ticket comment | run skill in; human only out (→ Todo or → Backlog) |

Comments are the log, columns are the signal. The run only ever reads Todo, so nothing a human has not released can be picked up. The Question column is emptied only by a human; an empty Question column means there are no open questions. Column names are logical — resolve the native name via `list_board_columns`, never hardcode it.

## Escalation: one level up, never just forwarded

Always escalate one level up until a level can answer; only when no level is left, the human. Escalating is not forwarding: each level must seriously try to answer itself and state what it checked and why that was not enough, so the next level starts from evidence rather than from the original question.

The human is asked only for a decision, never for a retry. Anything whose answer would be "try again" the run does itself, within its round caps. A ticket in the Question column whose only possible reaction is "kick it again" is a system bug, not an open question.

## Every Agent dispatch is unnamed

Never pass `name` to an `Agent` dispatch in this ecosystem, and never resume an agent via `SendMessage`. A named agent delivers its result to a SendMessage mailbox that nothing here listens to; the caller waits for a task notification that never comes and is told nothing. Two runs were lost exactly this way (`agent-autonomous-developer#60` and `#88`).

Continuity does not live in a long-running agent. It lives in the tickets: every return trip is a fresh unnamed dispatch that carries the ticket or package id and reads its state from the comments there.

## Where a memory belongs

A Serena memory entry belongs in the repo whose code it concerns. A fact about two repos is not a memory but a convention, and conventions belong in this file. An entry that would have to live in two stores to be found is duplicated by definition — that is the signal it was misfiled, not a reason to write it twice.

The store is for what an agent looks up, never for what it must obey. A rule written into a memory binds nobody, because nothing guarantees it is read; a rule lives in an AGENTS.md, a skill, or a hook.

## CI is the only truth about green

A PR with a red pipeline is never accepted, whatever a local test run said. A local run is at most a pre-filter that saves time; it is never a verdict, for two reasons: local runs crash regularly for reasons that have nothing to do with the change, and a CI result was produced by nobody with a stake in the outcome.

A run counts as finished only when the pipeline is green — not when the branch is pushed, not when the PR is open. The mechanisms that enforce this (polling, round caps, fix dispatches) live where they execute, in the plugins, not here.

## Doc references are links and they are checked

A reference from one document to a section of another is written as a Markdown link (`[text](path.md#anchor)`), never as prose naming the file and section. The pre-commit hook in `.githooks/` runs `.claude/scripts/check-doc-section-refs.mjs` over the staged content of `.claude/**/*.md`, `human/**/*.md`, and the root `*.md` files: a link whose file or anchor does not exist rejects the commit, and so does a prose reference of the old form. Double-backtick specimens and fenced code are exempt.

The hook is the rule; there is no further doctrine. Scaffolding templates necessarily contain paths and that is fine — the check is only about whether a cross-document reference resolves. A fresh clone needs `git config core.hooksPath .githooks` once.
