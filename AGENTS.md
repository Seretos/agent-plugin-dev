# agent-plugins (project root)

A modular plugin platform for AI coding agents (Claude Code et al.). Each plugin is a self-contained git repository; a central `agent-marketplace` repo registers them all. This directory itself is a meta-repo (`Seretos/agent-plugin-dev`) that bundles the dev workspace for the plugin maintainers.

## Layout

```
agent-plugin-dev/             # this directory — meta-repo Seretos/agent-plugin-dev
├── workspace.json            # manifest of sub-repos + dev-test symlinks
├── scripts/init.ps1|.sh      # bootstrap: clone sub-repos + create symlinks
├── agent-marketplace/        # own repo: Seretos/agent-marketplace (gitignored here)
│                             # The registry. Metadata only, no plugin code.
├── plugins/                  # all gitignored here
│   ├── agent-vdesktop/       # own repo: Seretos/agent-vdesktop
│   ├── agent-vdesktop-skill/ # own repo: Seretos/agent-vdesktop-skill
│   ├── agent-project-issues/ # own repo: Seretos/agent-project-issues
│   └── agent-worktree/       # own repo: Seretos/agent-worktree
├── dev-test/                 # local marketplace (directory source) for daily dev
└── prod-test/                # test setup against the real GitHub marketplace
```

The `plugins/` folder is intentionally flat — no rigid mcp/ vs skill/ split. A plugin's `plugin.json` declares whether it carries an MCP server, skills, slash commands, hooks, or any mix.

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
- **Local plugin testing requires launching Claude from `dev-test/`.** The dev-test marketplace points at the symlinked local plugin paths, so any branch checked out under `plugins/<name>/` is picked up on session start (and on `/reload-plugins`). A Claude session launched from elsewhere uses the cached version from the real `agent-marketplace` registry and won't see your local changes.
- Each subdirectory under `plugins/` and `agent-marketplace/` is an independent repo with its own remote, history, and CI.
- The user does the GitHub-side actions (repo creation, secret setup, pushing). Don't push or create remote artifacts unless explicitly asked.
- Marketplace tags are NOT used. `{plugin-name}--v{version}` tags were tried early and removed — Claude Code resolves versions from marketplace.json's content, not from tags on the marketplace repo.
- `**/settings.local.json` is gitignored repo-wide. Committed baselines live in `settings.json`; user-specific extras go in `settings.local.json`.
