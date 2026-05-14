# agent-plugin-dev

Meta-/Dev-Repository für die Entwicklung der `Seretos/agent-*` Plugins (MCP-Server, Skills, Slash Commands, Hooks) für Claude Code. Bündelt die einzelnen Plugin-Repos, einen lokalen Test-Marketplace, einen Production-Test-Workspace und gemeinsame Konventionen.

## Du willst ein Plugin nur benutzen?

**Dann brauchst du dieses Repo nicht.** Plugins werden über den öffentlichen Marketplace installiert:

```text
/plugin marketplace add Seretos/agent-marketplace
/plugin install <plugin-name>@agent-marketplace
```

Marketplace-Repo: <https://github.com/Seretos/agent-marketplace>

## Du willst Plugins entwickeln?

```sh
git clone git@github.com:Seretos/agent-plugin-dev.git
cd agent-plugin-dev
./scripts/init.ps1   # Windows
./scripts/init.sh    # Linux / macOS
```

Das Init-Script:

- klont die 4 Plugin-Repos (`agent-marketplace`, `plugins/agent-vdesktop`, `plugins/agent-vdesktop-skill`, `plugins/agent-project-issues`) an die richtigen Stellen,
- legt die Symlinks unter `dev-test/plugins/` an, die der lokale `dev-marketplace` referenziert.

Falls die Symlink-Erzeugung unter Windows scheitert (kein Developer Mode, keine Admin-Shell), gibt das Script die nötigen Commands aus, die du selbst aus einer Admin-PowerShell ausführen kannst. Idempotent — kann jederzeit erneut laufen.

Konventionen, Release-Flow und Per-Repo-Details: siehe `AGENTS.md`.

## Workspace-Layout

```
agent-plugin-dev/             # dieses Meta-Repo
├── .claude/                  # Claude-Code-Config für diesen Dev-Workspace
├── agent-marketplace/        # eigenes Repo (Seretos/agent-marketplace)
├── plugins/
│   ├── agent-vdesktop/       # eigenes Repo
│   ├── agent-vdesktop-skill/ # eigenes Repo
│   └── agent-project-issues/ # eigenes Repo
├── dev-test/                 # lokaler Marketplace (directory source)
├── prod-test/                # Test gegen den echten Marketplace von GitHub
└── scripts/                  # init.ps1 / init.sh
```

`agent-marketplace/` und `plugins/*` sind eigene Git-Repos und werden hier nicht versioniert — `workspace.json` ist die Source of Truth für den Klon-Zustand.

## User-spezifische Overrides

Jede `.claude/settings.local.json` ist global per `.gitignore` aus dem Repo. Hier kannst du eigene Permissions oder zusätzliche `enabledPlugins` aktivieren, ohne das Repo zu verändern. Die committed `settings.json` ist die geteilte Baseline.
