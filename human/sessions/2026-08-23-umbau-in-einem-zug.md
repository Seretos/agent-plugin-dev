# 2026-08-23 — Umbau in einem Zug

Der Plan aus der Planungssession (`~/.claude/plans/wir-m-ssen-jetzt-dieses-kind-steele.md`) wurde
in dieser Session direkt umgesetzt, ohne Ticket-Umweg — der bisherige Ablauf war dafür nicht
verlässlich genug. `sothis` wurde nur gelesen, nie verändert.

## Was jetzt steht (alles lokal committet, nichts gepusht)

| Repo | Branch | Stand |
|---|---|---|
| `plugins/agent-autonomous-developer` | `main` (4 Commits auf PR #89) | **Neubau**: eine Skill `process-ticket` (Paket → grüner PR), sechs Agenten, `scripts/critic/` aus sothis portiert, CI-Gate, `adev:event`-Kommentare, kein `AskUserQuestion`, keine Board-Schreibzugriffe. 88 Tests grün. Live-Isolationsprobe bestanden und aufgezeichnet. Ein echter `plan-critic`-Lauf (3 Lenses, 47 s) hat einen absichtlich eingebauten Widerspruch als `critical` gefunden. |
| `plugins/agent-ticket-orchestrator` | `main` (3 Commits, neues Repo) | **Neu**: Skills `gatekeeper` (beaufsichtigt, Backlog → Planned) und `run` (unbeaufsichtigt, nur Todo), Agenten `bundler`, `clarifier`. Der `claude -p`-Prozess wird aus dem Hauptturn des `run`-Skills gestartet — bewusst ohne Wrapper-Subagent. |
| Meta-Repo | `main` | Wurzel-`AGENTS.md` +6 Abschnitte (Board, Eskalation, unbenannte Dispatches, Memory-Verortung, CI-Wahrheit, Verweis-Hook), `.githooks/pre-commit` + `check-doc-section-refs.mjs`, Router aus `workspace.json`/Settings entfernt, Orchestrator registriert, `python-lib`-Template entdoppelt. |
| `agent-marketplace` | `chore/remove-ticket-router` | Router aus beiden Registries entfernt. |
| `mcp-test` | `main` | Orchestrator im lokalen Marketplace. |

Vertrag zwischen den Plugins: Einstiegspunkt + Kommentar-Ereignisse, festgehalten in beiden
`AGENTS.md` (und in `plugins/agent-autonomous-developer/skills/process-ticket/SKILL.md` → Events).

## Nebenfund

`agent-autonomous-developer` hatte keine `eol=lf`-`.gitattributes`. Mit `core.autocrlf=true`
(Default hier) landen Skills/Agenten nach einem Checkout als CRLF im Arbeitsbaum, und Claude Code
ignoriert sie stumm. Jetzt behoben; sehr wahrscheinlich eine Mitursache der „macht nichts"-Läufe.

## Bewusst nicht gemacht

- Kein Push, kein Release-Workflow, kein Kommentar auf `agent-plugin-dev#19` — Handarbeit des
  Menschen, siehe Abschlussmeldung der Session.
- `~/.seretos/projects.yml` nicht angefasst (agenten-geschützt).
- `plugins/agent-ecosystem-ticket-router/` liegt noch auf der Platte; löschen nach Archivierung.
- `mcp-test/plugins/agent-ticket-orchestrator`-Symlink braucht erhöhte Rechte.
