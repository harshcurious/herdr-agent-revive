# agent-revive

After a reboot (or herdr-core losing a terminal), Herdr brings each pane back
as a plain shell in its old folder. This mod types the exact resume command
into each one, so every tab is back on the conversation it had.

| Agent    | Recorded by (`setup.sh` adds it)                              | Resumed with                    |
|----------|----------------------------------------------------------------|---------------------------------|
| claude   | `SessionStart` hook in `~/.claude/settings.json`              | `claude --resume <id>`          |
| codex    | `SessionStart` + `UserPromptSubmit` in `~/.codex/hooks.json`  | `codex --no-daemon resume <id>` |
| opencode | plugin `~/.config/opencode/plugins/agent-revive/tui.js`       | `opencode -s <id>`              |
| agy      | group `agent-revive`, `PreInvocation`, in `~/.gemini/config/hooks.json` | `agy --conversation <id>` |

## Files

- `main.js`: the mod. Draws nothing; scans every 3 s.
- `hook.sh`: what every agent hook runs; writes the record.
- `setup.sh`: wires the hooks for every installed agent (`--remove` undoes it).
- `opencode-plugin.js`: the OpenCode plugin `setup.sh` copies.

## How it works

Every hook runs `hook.sh`, which writes
`<herdr-app home>/data/agent-revive/<terminal>.json` with the agent, the
conversation id, its folder and the terminal's top-level pid. (`hc label` can't
be used: inside a Herdr terminal `hc` is scoped and can't see its own terminal.)

The mod scans every 3 s. A shell idle at its prompt whose pid differs from the
recorded one was replaced by core, so it gets the resume command; one with the
same pid means you closed the agent yourself, and the record is deleted.
Records of closed terminals are deleted too. Each action is claimed with a
compare-and-swap on the record, so several copies of the mod never type twice.
A Claude that was already running before the hook existed is picked up from
`~/.claude/sessions/<pid>.json`.

Not covered: Claude sessions in background mode (`kind: "bg"` in
`~/.claude/sessions/*.json`). One Claude daemon hosts several terminals'
sessions and passes its starter's `HC_TERMINAL_ID` to all of them, so the
terminal can't be told; the hook records nothing rather than guess.

## Layout

The mod has to be in the layout you use, as an invisible floating block on the
root node:

```json
"floating": [ { "id": "agent-revive", "content": { "mod": "agent-revive" }, "edge": "bottom", "align": "start" } ]
```

Herdr's shipped layouts (`main`, `terminals`, `win98`) are read-only: clone
one first (`herdr-app do layout.clone '{"name":"main","as":"my-layout"}'`).

Dry run of a hook: `AGENT_REVIVE_LOG=/tmp/r.log` in the agent's environment
logs what it would record instead of writing it.
