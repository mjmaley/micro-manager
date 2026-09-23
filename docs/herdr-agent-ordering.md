# Herdr agent ordering — installed 0.9.0

Checked read-only on 2026-09-09. No ordering, settings, focus, or sessions changed.

## Findings

- Herdr supports `agent_panel_sort = "spaces"` (workspace grouping; `"workspaces"`
  is an alias) and `"priority"` (attention queue). The local config currently
  specifies `"priority"`; this establishes the file setting, not independently
  the running client's effective setting. Sources: `herdr --default-config`,
  `~/.config/herdr/config.toml:3`, and tagged source
  `src/app/agent_view.rs:53–78`.
- Workspaces and tabs can be reordered by dragging. Optional
  `keys.move_tab_previous` / `keys.move_tab_next` bindings also move tabs. Sources:
  installed 0.9.0 CHANGELOG (entries for workspace dragging, tab dragging and
  #2561), and `herdr --default-config`.
- Advanced `agent.view.set` / `agent.view.clear` APIs provide transient filtered
  and sorted agent-panel views. Sort fields include workspace/tab/pane order,
  attention, status, agent kind, seen, state-change sequence, and token fields.
  This is rule-based sorting rather than an explicit arbitrary list of agent IDs.
  Sources: CHANGELOG's Agent view entry; `src/api/schema/agents.rs:53–68,130–164`;
  `src/app/agent_view.rs:53–78`.
- No dedicated arbitrary agent drag-to-reorder or agent move command was found
  in inspected 0.9.0 help/source. This is a bounded negative finding, not a claim
  about future releases. Sources: `herdr agent --help`, schema, and searches of
  agent/mouse handlers.

## MicroManager implication

`agent.list` returns workspace → tab → pane traversal order, not the sidebar's
priority or custom Agent view order. MicroManager preserves that returned order.
Consequently changing only the sidebar sort does not change pad slot ordering;
reordering underlying workspaces/tabs can change that traversal. Independently
pinning particular agents to physical buttons would require a MicroManager
ordering feature (not implemented here).

Sources: tagged `src/app/api/agents.rs:28–35`,
`src/app/agents.rs:23–38`; repository
`Sources/WLKit/HerdrClient.swift:listAgents()`.

## Primary-source locations

- Installed CLI: `/opt/homebrew/bin/herdr` (`herdr --version`: 0.9.0).
- Changelog: `/opt/homebrew/Cellar/herdr/0.9.0/CHANGELOG.md`.
- Tagged source snapshot: `/tmp/herdr-090-inspection/herdr-0.9.0/`.
- Upstream project: https://github.com/herdrdev/herdr
