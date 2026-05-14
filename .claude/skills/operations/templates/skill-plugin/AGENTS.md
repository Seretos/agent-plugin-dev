# {{plugin_name}}

Pure skill plugin — no binary, no MCP server. Ships a single `SKILL.md` that Claude Code loads when the skill's `description` matches the user's intent.

## Layout

```
skills/{{skill_slug}}/
  SKILL.md                    # the skill — frontmatter (name, description) + body

.claude-plugin/plugin.json    # plugin manifest, declares dependencies (e.g. on an MCP)

.github/workflows/
  lint.yml                    # plugin.json + SKILL.md frontmatter validation on every push
  release.yml                 # manual-dispatch release flow
```

## Branches

- `main` — source of truth.
- `release` — orphan branch, force-pushed by `release.yml`. Contains only install-ready files: `.claude-plugin/plugin.json`, `skills/`, `README.md`.

## Release flow

Triggered manually:

```
Actions → release → Run workflow → version=X.Y.Z
```

The workflow:
1. Validates `X.Y.Z` is semver.
2. Fails if tag `{{plugin_name}}--vX.Y.Z` already exists.
3. Stamps the version into `.claude-plugin/plugin.json` (CI checkout only).
4. Stages install-ready tree, zips it.
5. Force-pushes the orphan `release` branch.
6. Creates the `{{plugin_name}}--vX.Y.Z` tag and a GitHub Release with the zip attached.
7. POSTs to `Seretos/agent-marketplace/dispatches` (category: `skill`) using `MARKETPLACE_DISPATCH_TOKEN`.

## Required secret

- `MARKETPLACE_DISPATCH_TOKEN` — fine-grained PAT with `Contents: Read and write` + `Pull requests: Read and write` on `Seretos/agent-marketplace` only.

## Dependencies

If this skill teaches Claude how to drive an MCP plugin, declare it under `dependencies` in `.claude-plugin/plugin.json`:

```json
"dependencies": [
  { "name": "agent-<mcp-plugin>", "version": ">=0.0.1 <1.0.0" }
]
```

Claude Code will install/load the MCP automatically when this skill is installed.
