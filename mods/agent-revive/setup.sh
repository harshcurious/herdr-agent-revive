#!/bin/sh
# agent-revive setup: wire each installed agent to hook.sh, so the mod knows
# which conversation every terminal runs. Safe to run again: entries already
# there are left alone. Every file it changes is first copied to
# <file>.before-agent-revive (once).
#
#   sh setup.sh            install for every agent found
#   sh setup.sh --remove   take the entries out again
#
# Touches (only if that agent is installed):
#   Claude Code  ~/.claude/settings.json         hooks.SessionStart
#   Codex        ~/.codex/hooks.json             hooks.SessionStart, UserPromptSubmit
#                (Codex asks you to review new hooks the next time it starts)
#   agy          ~/.gemini/config/hooks.json     group "agent-revive": PreInvocation
#   OpenCode     ~/.config/opencode/plugins/agent-revive/tui.js
# Needs python3 to edit the JSON files.

set -e
APP_HOME="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}"
MOD="$APP_HOME/mods/agent-revive"
HOOK="$MOD/hook.sh"
MODE=install
[ "$1" = "--remove" ] && MODE=remove

[ -f "$HOOK" ] || { echo "agent-revive: $HOOK not found; put the mod in $MOD first" >&2; exit 1; }
command -v python3 >/dev/null || { echo "agent-revive: python3 is needed to edit the hook files" >&2; exit 1; }
chmod +x "$HOOK" 2>/dev/null || :

have() { command -v "$1" >/dev/null 2>&1 || [ -e "$2" ]; }

backup() {
  [ -f "$1" ] && [ ! -e "$1.before-agent-revive" ] && cp -p "$1" "$1.before-agent-revive"
  return 0
}

# edit <kind> <file>: add or remove our entries in a JSON hooks file.
edit() {
  backup "$2"
  python3 - "$1" "$2" "$HOOK" "$MODE" <<'PY'
import json, os, sys
kind, path, hook, mode = sys.argv[1:5]
data = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read().strip()
    data = json.loads(text) if text else {}

def command(agent):
    return f"sh '{hook}' {agent}"

def ours(entry):
    return "agent-revive/hook.sh" in json.dumps(entry)

changed = False
if kind in ("claude", "codex"):
    events = ["SessionStart"] + (["UserPromptSubmit"] if kind == "codex" else [])
    hooks = data.setdefault("hooks", {})
    for event in events:
        groups = hooks.setdefault(event, [])
        kept = [g for g in groups if not ours(g)]
        if mode == "remove":
            if len(kept) != len(groups):
                hooks[event] = kept
                changed = True
        elif len(kept) == len(groups):
            groups.append({"hooks": [{"type": "command", "command": command(kind), "timeout": 5}]})
            changed = True
elif kind == "agy":
    if mode == "remove":
        changed = data.pop("agent-revive", None) is not None
    elif "agent-revive" not in data:
        data["agent-revive"] = {"PreInvocation": [
            {"type": "command", "command": command("agy"), "timeout": 5}]}
        changed = True

if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".agent-revive-tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
print(f"  {kind:8} {path}: {'updated' if changed else 'already ' + ('clean' if mode == 'remove' else 'set')}")
PY
}

echo "agent-revive: $MODE"
if have claude "$HOME/.claude"; then edit claude "$HOME/.claude/settings.json"; fi
if have codex "$HOME/.codex"; then edit codex "$HOME/.codex/hooks.json"; fi
if have agy "$HOME/.gemini/antigravity-cli"; then edit agy "$HOME/.gemini/config/hooks.json"; fi
if have opencode "$HOME/.config/opencode"; then
  dir="$HOME/.config/opencode/plugins/agent-revive"
  if [ "$MODE" = remove ]; then
    rm -rf "$dir" && echo "  opencode $dir: removed"
  else
    mkdir -p "$dir" && cp "$MOD/opencode-plugin.js" "$dir/tui.js" && echo "  opencode $dir/tui.js: written"
  fi
fi
[ "$MODE" = install ] && echo "Now add the mod to your layout (see README) and restart your agents."
exit 0
