# {{plugin_name}}

{{description}}

## Quick install

**Claude Code:**

```
/plugin marketplace add Seretos/agent-marketplace
/plugin install {{plugin_name}}@agent-marketplace
```

Self-contained binary — no Python, no `pip install`, no dependencies. The release zip ships native binaries for both Windows (`{{short_name}}.exe`) and Linux (`{{short_name}}`); the host OS auto-selects the right one.

## Alternative installs

### From the GitHub Releases page

1. Download `{{plugin_name}}-<version>.zip` from [Releases](https://github.com/Seretos/{{plugin_name}}/releases).
2. Unpack to a stable folder (e.g. `C:\Users\<you>\.claude\plugins\{{plugin_name}}\` on Windows, `~/.claude/plugins/{{plugin_name}}/` on Linux).
3. In Claude Code:
   ```
   /plugin install <path-to-unpacked-folder>
   ```

### From the release branch

The `release` branch always carries the latest install-ready files (no zip step):

```
git clone --branch release --depth 1 https://github.com/Seretos/{{plugin_name}}.git
```

Then `/plugin install <cloned-path>` in Claude Code.

### Build from source

Requires Python 3.11+ (standard python.org installer with the `py` launcher on Windows; `python3` on Linux).

```powershell
git clone https://github.com/Seretos/{{plugin_name}}.git
cd {{plugin_name}}
pwsh -File scripts/build.ps1 -Clean -Package
```

Output on Windows: `bin/{{short_name}}.exe`. On Linux: `bin/{{short_name}}`. Then install via `/plugin install <path>`.
