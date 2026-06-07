---
name: operations
description: Use to onboard a new plugin or library into the Seretos agent-plugin ecosystem. Scaffolds a Python-MCP plugin or pure-Skill plugin in plugins/<name>/, or a pure Python library (python-lib) in libs/lib-python-<feature>/, sets up the matching GitHub release pipeline (plugins: release.yml + dispatch.yml + marketplace via MARKETPLACE_DISPATCH_TOKEN; libs: tag + release/Nx floating branch, no marketplace), patches workspace.json (+ mcp-test marketplace.json for plugins) and the root .seretos/projects.yml, and runs init.ps1 to wire up symlinks. User does the GitHub-side actions (repo creation, secret setup, push); the skill does the local scaffolding and meta-repo plumbing. Trigger on requests like "I want to add a new plugin", "scaffold a new MCP", "set up a new skill plugin", "add a new python lib", "scaffold a lib-python", "integrate <name> into the ecosystem".
---

# operations — Plugin & Lib Onboarding

You guide the user through adding a **new plugin or library** to the `agent-plugin-dev` meta-repo. The result: a fully scaffolded project with its own git repo and release pipeline, plus meta-repo files patched so the workspace knows about it.

- **Plugins** (`python-mcp`, `skill-plugin`) land under `plugins/agent-<name>/`, wire a release pipeline to the marketplace, and get an `mcp-test` symlink.
- **Libs** (`python-lib`) land under `libs/lib-python-<feature>/`, ship as Python *source* (no binary, no marketplace, no `mcp-test` symlink) consumed by other repos via `git+https://.../@vX.Y.Z`. The lib path is a **strict subset** of the plugin path — wherever a phase below says "for `python-lib`", that overrides the plugin default.

## What you do vs. what the user does

| You (the skill) | The user |
|---|---|
| Ask the clarifying questions in Phase 1 | Decide name, type, description |
| Render templates with placeholder substitution | Create the GitHub repo `Seretos/agent-{name}` |
| `git init` + `git remote add` + initial commit (local only) | Create the fine-grained PAT |
| Patch `workspace.json` + `mcp-test/.claude-plugin/marketplace.json` | Add `MARKETPLACE_DISPATCH_TOKEN` as Actions secret |
| Re-run `scripts/init.ps1` | `git push -u origin main` from the new plugin dir |

**Never** push, never call `gh repo create`, never set secrets remotely. That's a hard convention from the repo root README ("The user does the GitHub-side actions").

## Phase 1 — Clarify

Ask the user (use `AskUserQuestion` when multiple options exist, plain prose when a name is needed):

1. **Project type:**
   - `python-mcp` — Python source compiled to a single self-contained binary via PyInstaller (default: Windows `.exe` + Linux ELF; see question 6 below for the Windows-only override), exposes one or more MCP servers. (Reference: `agent-project-issues`, `agent-worktree` for multi-OS; `agent-vdesktop` for Windows-only.)
   - `skill-plugin` — pure documentation skill, no binary, no MCP. (Reference: `agent-vdesktop-skill`.)
   - `python-lib` — pure Python utility library: src-layout, no binary, no MCP, no marketplace. Shipped as source and consumed by other repos via a `git+https` pin. (Reference: `libs/lib-python-config` — the cleanest, smallest blueprint.)
   - If the user wants both a lib and a wrapper plugin (the common `lib-python-X` + `agent-X` pair), run the skill twice with two separate names — they ship as independent repos.

2. **Project name:**
   - **plugins** — must match `agent-{feature}` (lower-kebab, no `-mcp` suffix, see root `AGENTS.md` "Naming convention").
   - **libs** — must match `lib-python-{feature}` (lower-kebab, the `lib-python-` prefix is mandatory; see root `AGENTS.md` and all four existing libs). **No `agent-` prefix.**
   - In both cases reject names that contain uppercase or underscores, or already exist in `workspace.json` repos[].

3. **Description** — one-sentence, end-user-facing. Show the user what's used in the comparable existing plugins (read one as example) and offer a draft they can edit. If the conversation has enough context to write a strong draft, just propose it and ask for confirmation.

4. **Short identifiers** (only for `python-mcp`). Derive automatically from the plugin name and confirm with the user:
   - `short_name` — drop the `agent-` prefix. Example: `agent-newthing` → `newthing`. Used as the MCP server key, the binary filename (with `.exe` suffix on Windows), and the `.spec` filename.
   - `package_name` — `{short_name}_plugin` with hyphens turned into underscores. Example: `newthing_plugin`. Used as the Python package directory under `src/`.
   - `SHORT_NAME_UPPER` — `short_name` upper-cased with hyphens replaced by underscores. Example: `NEWTHING`. **The default scaffold doesn't use it** — the manifests ship no `env` block. Derive it only if you add an `env` entry for a binary that reads a `*_PLUGIN_ROOT` variable.

5. **Skill slug** (only for `skill-plugin`) — typically the same as `short_name` derived above. Used as the directory name under `skills/`.

   **Lib identifiers** (only for `python-lib`). Derive automatically and confirm:
   - `lib_name` — the full project name, e.g. `lib-python-comfy`. Used in `pyproject.toml` `name`, the `.seretos`/`.serena` configs, README, and the git remote.
   - `package_name` — `lib_name` with hyphens turned into underscores, e.g. `lib_python_comfy`. Used as the Python package directory under `src/`.

6. **OS targets** (only for `python-mcp`). Ask: *"Should this plugin ship Linux + Windows binaries, or Windows-only?"*

   > **For `python-lib`: skip this question entirely.** Libs are source-only and OS-agnostic; there is no binary to target. `test.yml` already matrices `windows-latest` + `ubuntu-22.04`, which is the full coverage a lib needs.

   - **Default — `[windows, linux]`.** Most MCP servers are I/O- and HTTP-bound and have no native-Windows dependency. The shipped template is wired this way out of the box: both manifests' `command` is extensionless (`bin/{{short_name}}` — `${CLAUDE_PLUGIN_ROOT}/...` for Claude, `${PLUGIN_ROOT}/...` for Codex), `release.yml` runs a stamp → matrix-build → assembly pipeline, `test.yml` matrices over `windows-latest` + `ubuntu-22.04`, `build.ps1` runs under both Windows PowerShell 5.1 and `pwsh` on Linux. **You do nothing extra to get multi-OS.**

     > **Known Codex-on-Windows limitation.** A multi-OS zip ships both `bin/{{short_name}}` and `bin/{{short_name}}.exe` side by side. Codex on Windows currently fails to resolve the extensionless command to the `.exe` (no PATHEXT resolution), so the MCP won't start there until OpenAI fixes it — `openai/codex#16229`. Claude (both OSes) and Codex-on-Linux are unaffected; a Windows-only plugin sidesteps it because its `command` carries an explicit `.exe`. Flag this to the user if their plugin targets Codex on Windows.

   - **Windows-only override — `[windows]`.** Pick this only if the plugin genuinely depends on Win32 APIs (COM, `pyvda`, `pywin32`, `comtypes`) — reference plugin: `agent-vdesktop`. If the user picks `[windows]`, after the standard template copy walk you must additionally:
     1. Edit `.github/workflows/release.yml`: remove the `ubuntu-22.04` row from the `build` job's `matrix.include`; in the assembly job drop the `bin/{{short_name}}` (Linux binary) existence-check and `chmod +x`; in the orphan-branch push step drop `bin/{{short_name}}` from the `git add` / `git update-index --chmod=+x` calls.
     2. Edit `.github/workflows/test.yml`: drop `ubuntu-22.04` from `matrix.os`.
     3. Append `.exe` to the `command` in **both** manifests: `.claude-plugin/plugin.json` → `${CLAUDE_PLUGIN_ROOT}/bin/{{short_name}}.exe`, and `.codex-plugin/plugin.json` → `${PLUGIN_ROOT}/bin/{{short_name}}.exe`.

     Apply these edits with `Edit` after the bulk copy finishes — they're surgical and the template's comments call out each spot.

   Surface the recommendation clearly: *"Default is multi-OS. Pick Windows-only only if you know the plugin uses Win32-specific bindings."* Remember the chosen value as `OS_TARGETS` so you can apply the override in Phase 3 if needed.

## Phase 2 — User does GitHub prep (wait for confirmation)

> **For `python-lib`: only step 1 applies, and the repo is `Seretos/lib-python-{feature}`.** A lib never dispatches into the marketplace, so there is **no PAT and no `MARKETPLACE_DISPATCH_TOKEN` secret** — its `release.yml` uses only the built-in `secrets.GITHUB_TOKEN`. Skip steps 2 and 3 entirely. Tell the user: "Create the empty repo, then tell me when it's done."

Tell the user, **in this order**, to do these three things off-Claude. Then ask explicitly: "Tell me when those three are done."

1. Create an empty GitHub repository at `Seretos/agent-{name}` (or `Seretos/lib-python-{feature}` for a lib). No README, no LICENSE, no .gitignore — those come from the scaffold.

2. Create a **fine-grained personal access token** that the new plugin's release workflow will use to dispatch into the marketplace:
   - Resource owner: `Seretos`
   - Repository access: **Only select repositories** → pick `Seretos/agent-marketplace`
   - Permissions: **Contents: Read and write** + **Pull requests: Read and write**
   - No other scopes. Set an expiration that matches the user's policy.

3. In the **new** plugin repo (`Seretos/agent-{name}`), go to `Settings → Secrets and variables → Actions → New repository secret`. Name it exactly `MARKETPLACE_DISPATCH_TOKEN` and paste the PAT value.

Do **not** proceed to Phase 3 until the user confirms. If they say "done", continue. If they have questions about token scopes or repo settings, answer from this section.

## Phase 3 — Local scaffold

You will copy the right template tree from `.claude/skills/operations/templates/{python-mcp,skill-plugin,python-lib}/` into the destination, substituting placeholders as you go. Destination is `plugins/agent-{name}/` for plugins, **`libs/lib-python-{feature}/` for libs**.

### Placeholder substitution

Apply these substitutions to **file contents** and to **path segments** (directories and filenames). Both `{{plugin_name}}` and the rest are literal placeholder strings that appear in the template tree.

Plugins (`python-mcp`, `skill-plugin`):

| Placeholder | Example value |
|---|---|
| `{{plugin_name}}` | `agent-newthing` |
| `{{short_name}}` | `newthing` |
| `{{package_name}}` | `newthing_plugin` |
| `{{skill_slug}}` | `newthing` |
| `{{display_name}}` | `Agent Newthing` |
| `{{description}}` | (from Phase 1) |
| `{{author_name}}` | from `git config user.name`, fall back to asking |

Libs (`python-lib`) — a smaller set; the template uses only these four:

| Placeholder | Example value |
|---|---|
| `{{lib_name}}` | `lib-python-comfy` |
| `{{package_name}}` | `lib_python_comfy` (hyphens → underscores) |
| `{{description}}` | (from Phase 1) |
| `{{author_name}}` | from `git config user.name`, fall back to asking |

Read `git config user.name` once at the start of Phase 3 with `Bash` and use the result as `{{author_name}}`. If empty, ask the user. (`python-lib` has no `{{display_name}}`, no `{{short_name}}`, no manifests — skip the display-name confirmation below.)

Derive `{{display_name}}` (used by **both** plugin types, in the Codex manifest's `interface.displayName`) by title-casing the plugin name — `agent-newthing` → `Agent Newthing` — and **confirm it with the user**, since casing isn't always mechanical (`agent-vdesktop` → `Agent vDesktop`).

`OS_TARGETS` is **state, not a placeholder** — it doesn't appear in any template file. It drives a post-copy override step (Phase 3.5 below) for the Windows-only case. The default `[windows, linux]` requires no edits at all.

### Copying procedure

Walk the template tree manually (don't shell out to `cp -r` — placeholder-renames must happen during the walk). For each entry:

- If it's a directory whose name contains `{{...}}`, create the substituted directory and recurse.
- If it's a file whose name contains `{{...}}`, read its contents, substitute placeholders in the content, and `Write` to the substituted destination path.
- If neither name nor content contains placeholders, just copy the bytes.

Use `Glob` over `.claude/skills/operations/templates/<type>/**/*` to enumerate. Use `Read` + `Write` for each file. Don't try to be clever with `Bash` recursive copy — Windows paths and template renames will trip you up.

### OS_TARGETS post-copy override (python-mcp only)

If the user chose `OS_TARGETS = [windows, linux]` (the default), **skip this section** — the template is already wired for multi-OS.

If the user chose `OS_TARGETS = [windows]`, apply the surgical edits enumerated in Phase 1 question 6 to the freshly copied tree:

1. `.github/workflows/release.yml` — remove the `ubuntu-22.04` matrix row from the `build` job, drop the Linux-binary assertion + `chmod +x` from the assembly job's "Build merged staging tree" step, and drop the Linux-binary `git add` / `git update-index --chmod=+x` calls from the orphan-branch push step.
2. `.github/workflows/test.yml` — drop `ubuntu-22.04` from `matrix.os`.
3. Both manifests — append `.exe` to `command`: `.claude-plugin/plugin.json` → `${CLAUDE_PLUGIN_ROOT}/bin/{{short_name}}.exe`, and `.codex-plugin/plugin.json` → `${PLUGIN_ROOT}/bin/{{short_name}}.exe`.

Use the `Edit` tool for each substitution (the spots are clearly delimited by comments in the template). Don't delete the Linux-only steps in `build.ps1` — the script branches on `$IsWindows` at runtime, so a Windows-only matrix simply never exercises the Linux side.

### Git wiring (local only)

After the files are in place, from the destination dir (`plugins/agent-{name}/`, or `libs/lib-python-{feature}/` for a lib):

```bash
git init -b main
git remote add origin git@github.com:Seretos/agent-{name}.git   # lib: git@github.com:Seretos/lib-python-{feature}.git
git add .
git commit -m "init: scaffold from operations skill"
```

**Stop here.** Do not push. Do not run `gh` commands. The user pushes when they're ready.

## Phase 4 — Meta-repo integration

Patch the meta-repo (`agent-plugin-dev` root). **For `python-lib`, sections 4.1 (repos only, no symlink), 4.3, and 4.4 apply; skip 4.2 entirely.**

### 4.1 `workspace.json`

Read the file, parse the JSON, append to `repos[]` (preserving the order — append at end):

```json
{
  "name": "agent-{name}",
  "path": "plugins/agent-{name}",
  "remote": "git@github.com:Seretos/agent-{name}.git",
  "branch": "main"
}
```

For a **lib**, the entry points at `libs/`:

```json
{
  "name": "lib-python-{feature}",
  "path": "libs/lib-python-{feature}",
  "remote": "git@github.com:Seretos/lib-python-{feature}.git",
  "branch": "main"
}
```

And — **plugins only** — to `mcpTestSymlinks[]`:

```json
{ "from": "mcp-test/plugins/agent-{name}", "to": "plugins/agent-{name}" }
```

> **Libs get no `mcpTestSymlinks[]` entry.** A lib exposes no MCP, so there's nothing for `mcp-test` to mount — adding one would dangle.

Write the file back with 2-space indentation, matching the existing formatting style. **Use `Edit` rather than `Write`** — preserve the file's existing trailing newline / shape. Find the closing `]` of `repos` and inject the new object just before it.

### 4.2 `mcp-test/.claude-plugin/marketplace.json` (plugins only — skip for libs)

> **Note:** `mcp-test/` is its own standalone git repo (gitignored by the meta-repo). This edit is versioned in the `mcp-test` repo, not in `agent-plugin-dev` — commit it there if you want it tracked.

Append to `plugins[]`:

```json
{ "name": "agent-{name}", "source": "./plugins/agent-{name}" }
```

Same approach: `Edit` to inject before the closing `]`, preserve formatting.

### 4.3 Root `.seretos/projects.yml`

So the `project-issues` MCP / ticket-routing knows the new project, append an entry to the root `.seretos/projects.yml` `projects:` list (this file already lists every plugin and lib). Match the existing block shape:

```yaml
  - id: {name}
    description: ""
    provider: github
    path: Seretos/{name}
    token_env: GITHUB_TOKEN
    permissions:
      issues:
        create: true
        modify: true
      pulls:
        create: true
        modify: true
        merge: true
```

Use the project name verbatim as `id` (`agent-{name}` or `lib-python-{feature}`). `Edit` to append at the end of the list, preserving indentation.

### 4.4 Re-run `scripts/init.ps1`

```powershell
./scripts/init.ps1
```

The script is idempotent. It will:
- Skip cloning the new project (already exists locally with `.git`).
- Try to create the `mcp-test/plugins/agent-{name}` symlink (plugins only).
- If symlink creation fails (no Developer Mode / no admin), it prints the `New-Item` command for the user to run from an elevated PowerShell. That's the standard fallback — just relay the command to the user.

> **For `python-lib`: nothing extra happens, by design.** The symlink loop iterates only `mcpTestSymlinks[]`, and a lib has no entry there, so init.ps1 just records the repo as "already present" and creates no symlink. No script change is needed for libs.

## Phase 5 — Handoff

Give the user a tight handoff message covering:

1. `cd plugins/agent-{name} && git push -u origin main`
2. (Python-MCP only) Local build smoke test: `./scripts/build.ps1 -Clean` — on Windows produces `bin/{{short_name}}.exe`, on Linux produces `bin/{{short_name}}` (extensionless). Either way it must pass the MCP `initialize` handshake.
3. To activate locally, add to `.claude/settings.local.json`:
   ```json
   "enabledPlugins": { "agent-{name}@dev-marketplace": true }
   ```
4. To cut a first release: Actions tab → `release` workflow → "Run workflow" → version `0.0.1`. The workflow will dispatch to `agent-marketplace` and open a PR there.
5. **Replace `assets/icon.png` before cutting v0.0.1** — the templates ship a generic default PNG; if you release without replacing it, the marketplace will show the default image permanently (or until you cut another tag).
6. **Fill in `description.md`'s Key Features before cutting v0.0.1** — the template ships a `TODO` stub. The marketplace shows this blurb on the plugin's detail page (sent as `description_url`); an unedited stub ships the placeholder text.

Then ask if there's anything they want to customize before the first commit (e.g., README content, server.py initial tools, SKILL.md body). For `python-mcp` plugins, point at `SECURITY.md` specifically — the template ships a generic threat-model stub, and the inline HTML comment lists plugin-specific sections worth adding (intentional shell execution, token handling, permission gating, AI-attribution markers) based on the tool surface. If yes to any customization, edit those files in place — they're already in the freshly-committed worktree, so suggest an `--amend` only if the user explicitly asks, otherwise let them stack normal commits.

### Handoff for `python-lib`

A lib has no binary, no marketplace, no icon, no `description.md`, no `settings.local.json` activation block. Its handoff is shorter:

1. `cd libs/lib-python-{feature} && git push -u origin main`
2. Smoke-test locally: `pip install -e ".[test]" && python -m pytest` (the template ships one passing smoke test).
3. To cut the first release: Actions tab → `release` workflow → "Run workflow" → version `0.1.0` (libs start at `0.1.0`, not `0.0.1`). This validates semver, stamps `pyproject.toml`, tags `v0.1.0`, and force-pushes `release/0.x`. **No marketplace PR** — a lib doesn't dispatch.
4. Consumers pin the lib in their `pyproject.toml` / `pip install` via `git+https://github.com/Seretos/lib-python-{feature}@v0.1.0` (exact tag) or `@release/0.x` (floating latest 0.x).
5. Then fill in the real public API in `src/{{package_name}}/__init__.py` (`__all__`), the README usage block, and delete the AGENTS.md authoring-rule comment.

## Edge cases

- **User reuses an existing name.** Check `workspace.json` `repos[].name`. If it's there, refuse and explain — they need a different name.
- **Symlinks fail on Windows.** Standard issue. Relay the `New-Item` admin command from `init.ps1`'s output verbatim.
- **User wants a language other than Python.** Not in scope yet. Tell them: "Today the templates cover Python-MCP, pure-Skill, and pure Python-lib. C# / .NET and other languages will need a hand-adapted scaffold modeled on the python-mcp template — same `release.yml` dispatch payload (`category: "mcp"`), same `MARKETPLACE_DISPATCH_TOKEN`, same `{{plugin_name}}--v{version}` tag format, but a different `build.ps1` and different file layout." Offer to walk through adapting it manually.
- **User runs the skill against an already-scaffolded project.** Detect by checking if the destination already has its marker file: `plugins/agent-{name}/.claude-plugin/plugin.json` for a plugin, or `libs/lib-python-{feature}/pyproject.toml` for a lib. Don't overwrite — point out the existing file and ask what they want to do.

## Templates

Templates live under `.claude/skills/operations/templates/`:

- `python-mcp/` — full Python-MCP plugin tree (multi-OS by default — Windows + Linux). Reference implementations: `plugins/agent-project-issues/` and `plugins/agent-worktree/` (multi-OS); `plugins/agent-vdesktop/` (post-scaffold Windows-only override).
- `skill-plugin/` — pure-Skill plugin tree. Reference implementation: `plugins/agent-vdesktop-skill/`.
- `python-lib/` — pure Python source library (no binary, no MCP, no marketplace). Its `release.yml` is the **lib-release flow** (semver-validate → stamp `pyproject.toml` → tag `vX.Y.Z` → force-push `release/Nx` → GitHub Release → open downstream dependency-update tickets; no binary, no marketplace dispatch, no `MARKETPLACE_DISPATCH_TOKEN`). The release's final step + the standalone `ticket.yml` recovery workflow (`open-dep-ticket`) file a `chore(deps): bump {{lib_name}} to vX.Y.Z` issue in each repo listed in `release.yml`'s `CONSUMERS` env list, via a `CONSUMER_TICKET_TOKEN` PAT (Issues: write on the consumers; `GITHUB_TOKEN` can't open cross-repo issues). Ships empty by design — a fresh lib has no consumers, so the step is a green no-op until the agent adds an `owner/repo` line when a downstream repo first pins the lib. Ships no `.claude-plugin`/`.codex-plugin` manifests, no `.spec`, no `build.ps1`, no icon, no `description.md`. Reference implementation: `libs/lib-python-config/` (notification reference: `libs/lib-python-projects/.github/workflows/{release,ticket}.yml`). Placeholders: `{{lib_name}}` / `{{package_name}}` / `{{description}}` / `{{author_name}}`.
- `electron-typescript/` — empty-but-runnable Electron + TypeScript desktop **app** (not a plugin), built with `electron-builder` for Windows + macOS + Linux. Its `release.yml` creates a `{{app_name}}--vX.Y.Z` tag on the release commit, attaches the per-OS installers as Release assets, and dispatches an `app-release` event (carrying a `downloads` platform→URL map) to the marketplace's **app** registry — not the plugin registry. App placeholders are `{{app_name}}` / `{{short_name}}` / `{{display_name}}` / `{{description}}` / `{{author_name}}`. The Phase 1–4 scaffolding flow above is plugin-shaped; an app uses this template but a different (app-specific) onboarding path, so adapt by hand for now.

All three plugin/lib trees ship a paired `AGENTS.md` + `CLAUDE.md`: `AGENTS.md` is the human/agent doc (the top HTML comment states the authoring rule — *only document what an agent can't derive from the code* — and should be deleted in real projects), and `CLAUDE.md` is a one-line `@AGENTS.md` import so Claude Code, which loads `CLAUDE.md` rather than `AGENTS.md`, picks it up. Keep the `AGENTS.md` lean when you fill it in.

**Every template** (`python-mcp`, `skill-plugin`, `python-lib`, `electron-typescript`) also ships two repo-level configs so the scaffolded repo is workflow-ready the moment it's cloned, no manual setup:

- `.claude/settings.json` — enables the three workflow plugins (`agent-project-issues`, `agent-worktree`, `agent-autonomous-developer` from `@agent-marketplace`) so the ticket/PR/worktree tooling is live inside the new repo. Identical across all templates; no placeholders.
- `.seretos/projects.yml` — registers the repo *itself* with the `project-issues` MCP (one entry, `merge: false`), so an agent working inside the repo can read/route its own tickets. `id`/`path` are placeholdered (`{{plugin_name}}` / `{{lib_name}}` / `{{app_name}}`). If the repo consumes a sibling lib, add that lib as a second, read-only entry (`create:/modify:/merge: false`) per-instance — that pairing is project-specific and stays out of the template.

Templates use the placeholder set listed in Phase 3. Filenames and directory names that include placeholders must be renamed during the copy walk.

### Dual host manifests (Claude + Codex)

Both plugin types scaffold **two** host manifests so a single release installs on both Claude Code and Codex:

- `.claude-plugin/plugin.json` — Claude; the `command` expands via `${CLAUDE_PLUGIN_ROOT}`.
- `.codex-plugin/plugin.json` — Codex; same surface but the `command` expands via `${PLUGIN_ROOT}`, plus a `repository` field and an `interface { displayName, shortDescription }` block.

For `python-mcp` both carry an **inline** `mcpServers` block — there is no external `.mcp.json`, because `${CLAUDE_PLUGIN_ROOT}` doesn't expand in Codex MCP commands and a bare relative path fails in Claude, so no placeholder is shared across the two hosts. The default scaffold ships **no `env` block** (add one with `{{SHORT_NAME_UPPER}}_PLUGIN_ROOT` only if the binary actually reads it). For `skill-plugin`, the Codex manifest carries an explicit `skills: "./skills"` pointer (Claude auto-discovers `skills/`).

`release.yml` stamps the version into **both** manifests and stages the `.codex-plugin/` directory into the release zip alongside `.claude-plugin/`. The matrix `python-mcp` pipeline also sets `include-hidden-files: true` on the stamped-source artifact so those dot-directories survive the build round-trip. There is no `.mcp.json` staging, by design.

### Marketplace icon

Both templates ship `assets/icon.png` (a default placeholder PNG; the user replaces it with the plugin's real artwork before cutting v0.0.1). The release pipeline treats it as an install artifact, not just a repo file:

- `release.yml` copies `assets/` into the staging tree, so it lands inside the release zip **and** on the orphan `release` branch at the tagged commit.
- The dispatch payload to `agent-marketplace` carries an `"icon": "https://raw.githubusercontent.com/${repo}/${TAG}/assets/icon.png"` field; the marketplace renders that URL on the plugin's tile.

This means a plugin without an `assets/icon.png` shipped to the orphan `release` branch will resolve to a broken image on the marketplace. The default PNG that ships in the templates is good enough to prevent that until the user provides their own.

### Longer description (`description.md`)

Both templates ship a root `description.md` — a longer-form, user-facing blurb (with a **Key Features** section) that the marketplace renders on the plugin's detail page so a user can decide whether the plugin fits their workflow. Like the icon, it is a release artifact, not just a repo file:

- `release.yml` copies `description.md` into the staging tree, so it lands on the orphan `release` branch at the tagged commit.
- The dispatch payload carries `"description_url": "https://raw.githubusercontent.com/${repo}/${TAG}/description.md"`; the marketplace dispatcher (`update-registry.yml`) reads `description_url` and stores it on the registry entry. The recovery `dispatch.yml` (python-mcp) sends the same field.

The shipped `description.md` is a `{{plugin_name}}`/`{{description}}`-templated stub with `TODO` Key Features — the user fills it in before cutting v0.0.1.

When templates drift from the reference implementations (e.g., `agent-vdesktop`'s `release.yml` gets a new step), that's a maintenance task — update the template, not the existing plugins. The templates are the source of truth for **new** plugins; the existing plugins are independent repos that evolve on their own cadence.
