---
name: operations
description: Use to onboard a new plugin into the Seretos agent-plugin ecosystem. Scaffolds a Python-MCP or pure-Skill plugin in plugins/<name>/, sets up the GitHub release pipeline (release.yml, dispatch.yml, marketplace integration via MARKETPLACE_DISPATCH_TOKEN), patches workspace.json + mcp-test marketplace.json, and runs init.ps1 to wire up symlinks. User does the GitHub-side actions (repo creation, secret setup, push); the skill does the local scaffolding and meta-repo plumbing. Trigger on requests like "I want to add a new plugin", "scaffold a new MCP", "set up a new skill plugin", "integrate <name> into the ecosystem".
---

# operations — Plugin Onboarding

You guide the user through adding a **new plugin** to the `agent-plugin-dev` meta-repo. The result: a fully scaffolded plugin under `plugins/<name>/` with its own git repo, release pipeline wired to the marketplace, and meta-repo files patched so `mcp-test` picks it up.

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

1. **Plugin type:**
   - `python-mcp` — Python source compiled to a single self-contained binary via PyInstaller (default: Windows `.exe` + Linux ELF; see question 6 below for the Windows-only override), exposes one or more MCP servers. (Reference: `agent-project-issues`, `agent-worktree` for multi-OS; `agent-vdesktop` for Windows-only.)
   - `skill-plugin` — pure documentation skill, no binary, no MCP. (Reference: `agent-vdesktop-skill`.)
   - If the user wants both, run the skill twice with two separate plugin names — they should ship as independent repos.

2. **Plugin name** — must match `agent-{feature}` (lower-kebab, no `-mcp` suffix, see root `AGENTS.md` "Naming convention"). Reject names that:
   - don't start with `agent-`
   - contain uppercase or underscores
   - already exist in `workspace.json` repos[]

3. **Description** — one-sentence, end-user-facing. Show the user what's used in the comparable existing plugins (read one as example) and offer a draft they can edit. If the conversation has enough context to write a strong draft, just propose it and ask for confirmation.

4. **Short identifiers** (only for `python-mcp`). Derive automatically from the plugin name and confirm with the user:
   - `short_name` — drop the `agent-` prefix. Example: `agent-newthing` → `newthing`. Used as the MCP server key, the binary filename (with `.exe` suffix on Windows), and the `.spec` filename.
   - `package_name` — `{short_name}_plugin` with hyphens turned into underscores. Example: `newthing_plugin`. Used as the Python package directory under `src/`.
   - `SHORT_NAME_UPPER` — `short_name` upper-cased with hyphens replaced by underscores. Example: `NEWTHING`. Used as the env-var prefix for `*_PLUGIN_ROOT`.

5. **Skill slug** (only for `skill-plugin`) — typically the same as `short_name` derived above. Used as the directory name under `skills/`.

6. **OS targets** (only for `python-mcp`). Ask: *"Should this plugin ship Linux + Windows binaries, or Windows-only?"*

   - **Default — `[windows, linux]`.** Most MCP servers are I/O- and HTTP-bound and have no native-Windows dependency. The shipped template is wired this way out of the box: `plugin.json`'s `command` is extensionless (`bin/{{short_name}}`), `release.yml` runs a stamp → matrix-build → assembly pipeline, `test.yml` matrices over `windows-latest` + `ubuntu-22.04`, `build.ps1` runs under both Windows PowerShell 5.1 and `pwsh` on Linux. **You do nothing extra to get multi-OS.**

   - **Windows-only override — `[windows]`.** Pick this only if the plugin genuinely depends on Win32 APIs (COM, `pyvda`, `pywin32`, `comtypes`) — reference plugin: `agent-vdesktop`. If the user picks `[windows]`, after the standard template copy walk you must additionally:
     1. Edit `.github/workflows/release.yml`: remove the `ubuntu-22.04` row from the `build` job's `matrix.include`; in the assembly job drop the `bin/{{short_name}}` (Linux binary) existence-check and `chmod +x`; in the orphan-branch push step drop `bin/{{short_name}}` from the `git add` / `git update-index --chmod=+x` calls.
     2. Edit `.github/workflows/test.yml`: drop `ubuntu-22.04` from `matrix.os`.
     3. Edit `.claude-plugin/plugin.json`: change `command` to `${CLAUDE_PLUGIN_ROOT}/bin/{{short_name}}.exe`.

     Apply these edits with `Edit` after the bulk copy finishes — they're surgical and the template's comments call out each spot.

   Surface the recommendation clearly: *"Default is multi-OS. Pick Windows-only only if you know the plugin uses Win32-specific bindings."* Remember the chosen value as `OS_TARGETS` so you can apply the override in Phase 3 if needed.

## Phase 2 — User does GitHub prep (wait for confirmation)

Tell the user, **in this order**, to do these three things off-Claude. Then ask explicitly: "Tell me when those three are done."

1. Create an empty GitHub repository at `Seretos/agent-{name}`. No README, no LICENSE, no .gitignore — those come from the scaffold.

2. Create a **fine-grained personal access token** that the new plugin's release workflow will use to dispatch into the marketplace:
   - Resource owner: `Seretos`
   - Repository access: **Only select repositories** → pick `Seretos/agent-marketplace`
   - Permissions: **Contents: Read and write** + **Pull requests: Read and write**
   - No other scopes. Set an expiration that matches the user's policy.

3. In the **new** plugin repo (`Seretos/agent-{name}`), go to `Settings → Secrets and variables → Actions → New repository secret`. Name it exactly `MARKETPLACE_DISPATCH_TOKEN` and paste the PAT value.

Do **not** proceed to Phase 3 until the user confirms. If they say "done", continue. If they have questions about token scopes or repo settings, answer from this section.

## Phase 3 — Local scaffold

You will copy the right template tree from `.claude/skills/operations/templates/{python-mcp,skill-plugin}/` into `plugins/agent-{name}/`, substituting placeholders as you go.

### Placeholder substitution

Apply these substitutions to **file contents** and to **path segments** (directories and filenames). Both `{{plugin_name}}` and the rest are literal placeholder strings that appear in the template tree.

| Placeholder | Example value |
|---|---|
| `{{plugin_name}}` | `agent-newthing` |
| `{{short_name}}` | `newthing` |
| `{{package_name}}` | `newthing_plugin` |
| `{{skill_slug}}` | `newthing` |
| `{{description}}` | (from Phase 1) |
| `{{author_name}}` | from `git config user.name`, fall back to asking |
| `{{SHORT_NAME_UPPER}}` | `NEWTHING` |

Read `git config user.name` once at the start of Phase 3 with `Bash` and use the result as `{{author_name}}`. If empty, ask the user.

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
3. `.claude-plugin/plugin.json` — change `command` from `${CLAUDE_PLUGIN_ROOT}/bin/{{short_name}}` to `${CLAUDE_PLUGIN_ROOT}/bin/{{short_name}}.exe`.

Use the `Edit` tool for each substitution (the spots are clearly delimited by comments in the template). Don't delete the Linux-only steps in `build.ps1` — the script branches on `$IsWindows` at runtime, so a Windows-only matrix simply never exercises the Linux side.

### Git wiring (local only)

After the files are in place, from `plugins/agent-{name}/`:

```bash
git init -b main
git remote add origin git@github.com:Seretos/agent-{name}.git
git add .
git commit -m "init: scaffold from operations skill"
```

**Stop here.** Do not push. Do not run `gh` commands. The user pushes when they're ready.

## Phase 4 — Meta-repo integration

Patch three things in the meta-repo (`agent-plugin-dev` root):

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

And to `mcpTestSymlinks[]`:

```json
{ "from": "mcp-test/plugins/agent-{name}", "to": "plugins/agent-{name}" }
```

Write the file back with 2-space indentation, matching the existing formatting style. **Use `Edit` rather than `Write`** — preserve the file's existing trailing newline / shape. Find the closing `]` of `repos` and inject the new object just before it.

### 4.2 `mcp-test/.claude-plugin/marketplace.json`

> **Note:** `mcp-test/` is its own standalone git repo (gitignored by the meta-repo). This edit is versioned in the `mcp-test` repo, not in `agent-plugin-dev` — commit it there if you want it tracked.

Append to `plugins[]`:

```json
{ "name": "agent-{name}", "source": "./plugins/agent-{name}" }
```

Same approach: `Edit` to inject before the closing `]`, preserve formatting.

### 4.3 Re-run `scripts/init.ps1`

```powershell
./scripts/init.ps1
```

The script is idempotent. It will:
- Skip cloning the new plugin (already exists locally with `.git`).
- Try to create the `mcp-test/plugins/agent-{name}` symlink.
- If symlink creation fails (no Developer Mode / no admin), it prints the `New-Item` command for the user to run from an elevated PowerShell. That's the standard fallback — just relay the command to the user.

## Phase 5 — Handoff

Give the user a tight handoff message covering:

1. `cd plugins/agent-{name} && git push -u origin main`
2. (Python-MCP only) Local build smoke test: `./scripts/build.ps1 -Clean` — on Windows produces `bin/{{short_name}}.exe`, on Linux produces `bin/{{short_name}}` (extensionless). Either way it must pass the MCP `initialize` handshake.
3. To activate locally, add to `.claude/settings.local.json`:
   ```json
   "enabledPlugins": { "agent-{name}@dev-marketplace": true }
   ```
4. To cut a first release: Actions tab → `release` workflow → "Run workflow" → version `0.0.1`. The workflow will dispatch to `agent-marketplace` and open a PR there.

Then ask if there's anything they want to customize before the first commit (e.g., README content, server.py initial tools, SKILL.md body). For `python-mcp` plugins, point at `SECURITY.md` specifically — the template ships a generic threat-model stub, and the inline HTML comment lists plugin-specific sections worth adding (intentional shell execution, token handling, permission gating, AI-attribution markers) based on the tool surface. If yes to any customization, edit those files in place — they're already in the freshly-committed worktree, so suggest an `--amend` only if the user explicitly asks, otherwise let them stack normal commits.

## Edge cases

- **User reuses an existing name.** Check `workspace.json` `repos[].name`. If it's there, refuse and explain — they need a different name.
- **Symlinks fail on Windows.** Standard issue. Relay the `New-Item` admin command from `init.ps1`'s output verbatim.
- **User wants a language other than Python.** Not in scope yet. Tell them: "Today the templates cover Python-MCP and pure-Skill. C# / .NET and other languages will need a hand-adapted scaffold modeled on the python-mcp template — same `release.yml` dispatch payload (`category: "mcp"`), same `MARKETPLACE_DISPATCH_TOKEN`, same `{{plugin_name}}--v{version}` tag format, but a different `build.ps1` and different file layout." Offer to walk through adapting it manually.
- **User runs the skill against an already-scaffolded plugin.** Detect by checking if `plugins/agent-{name}/.claude-plugin/plugin.json` exists. Don't overwrite — point out the existing file and ask what they want to do.

## Templates

Templates live under `.claude/skills/operations/templates/`:

- `python-mcp/` — full Python-MCP plugin tree (multi-OS by default — Windows + Linux). Reference implementations: `plugins/agent-project-issues/` and `plugins/agent-worktree/` (multi-OS); `plugins/agent-vdesktop/` (post-scaffold Windows-only override).
- `skill-plugin/` — pure-Skill plugin tree (7 files). Reference implementation: `plugins/agent-vdesktop-skill/`.

Templates use the placeholder set listed in Phase 3. Filenames and directory names that include placeholders must be renamed during the copy walk.

When templates drift from the reference implementations (e.g., `agent-vdesktop`'s `release.yml` gets a new step), that's a maintenance task — update the template, not the existing plugins. The templates are the source of truth for **new** plugins; the existing plugins are independent repos that evolve on their own cadence.
