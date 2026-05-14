# {{plugin_name}}

MCP server that ships as a self-contained Windows `.exe` (PyInstaller-frozen Python). End users don't need a Python toolchain.

## Layout

```
src/{{package_name}}/            # Python source (src-layout)
  server.py                       # FastMCP entry point, wires the tools
  __main__.py                     # python -m / PyInstaller entry

tests/                          # pytest, runs on every push (test.yml)
scripts/build.ps1               # PyInstaller wrapper + smoke test + optional packaging
{{short_name}}.spec               # PyInstaller config
pyproject.toml                  # setuptools (package-dir = src/) + pytest config
.claude-plugin/plugin.json      # plugin manifest, points at bin/{{short_name}}.exe
SECURITY.md                     # threat model — extend per tool surface

.github/workflows/
  test.yml                      # pytest on every push and PR
  release.yml                   # manual-dispatch full release flow
  dispatch.yml                  # manual recovery: re-send marketplace dispatch
```

## Branches

- `main` — source of truth. All edits go here.
- `release` — orphan branch, force-pushed by `release.yml`. Contains only install-ready files: `.claude-plugin/plugin.json`, `bin/{{short_name}}.exe`, `README.md`. Clients clone at the version tag (e.g. `{{plugin_name}}--v0.0.1`).

The release branch shares no history with main. Don't try to merge between them.

## Release flow

Triggered manually:

```
Actions → release → Run workflow → version=X.Y.Z
```

or `gh workflow run release.yml -f version=X.Y.Z`.

The workflow:
1. Validates `X.Y.Z` is semver.
2. Fails if tag `{{plugin_name}}--vX.Y.Z` already exists.
3. Stamps the version into `pyproject.toml` and `.claude-plugin/plugin.json` (CI checkout only — never pushed back to main).
4. Runs `scripts/build.ps1 -Clean -Package` (PyInstaller → smoke test → ZIP).
5. Stashes the ZIP outside the working tree (needed because step 6 wipes it).
6. Force-pushes the orphan `release` branch from the staged install-ready tree.
7. Creates the `{{plugin_name}}--vX.Y.Z` tag on that commit and a GitHub Release with the ZIP attached.
8. POSTs to `Seretos/agent-marketplace/dispatches` with the plugin metadata, using `MARKETPLACE_DISPATCH_TOKEN`.

`pyproject.toml`'s `version` field is **not** load-bearing for releases. The workflow input drives everything.

## Required secret

- `MARKETPLACE_DISPATCH_TOKEN` — fine-grained PAT with `Contents: Read and write` + `Pull requests: Read and write` on `Seretos/agent-marketplace` only.

## Build conventions (`scripts/build.ps1`)

- Compatible with **Windows PowerShell 5.1** (the system default) AND PowerShell 7.
- No global `$ErrorActionPreference = 'Stop'` — PyInstaller writes heavily to stderr, which PS 5.1 wraps as ErrorRecord and would trip a global Stop.
- Python discovery prefers `py.exe -3` locally and `python.exe` in `$env:CI` (so `actions/setup-python` is honored).
- The smoke test runs an MCP `initialize` handshake against the freshly built `.exe`. The build fails if the handshake fails.

## PyInstaller / src-layout notes

- The Python package is `{{package_name}}` under `src/`. `pyproject.toml` declares `package-dir = { "" = "src" }` and `[tool.pytest.ini_options] pythonpath = ["src"]`.
- `{{short_name}}.spec` references `src/{{package_name}}/__main__.py` as the entry and `pathex=[ROOT / "src"]`. Adjust both if the layout ever moves.
- If you add native-binding dependencies (e.g. `pyvda`, `pywin32`, `comtypes`), use `collect_all(...)` for them in `{{short_name}}.spec` so PyInstaller picks up lazy-generated submodules.
