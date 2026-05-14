# {{plugin_name}}

A Claude Code **skill** plugin. {{description}}

This plugin ships **only the skill content** — no binaries, no MCP server.

## Install

```
/plugin marketplace add Seretos/agent-marketplace
/plugin install {{plugin_name}}@agent-marketplace
```

If the skill teaches Claude how to use a specific MCP, declare that MCP as a dependency in `.claude-plugin/plugin.json` (`dependencies` array). Claude Code will install/load it automatically.

## What the skill teaches

See `skills/{{skill_slug}}/SKILL.md` for the full content.
