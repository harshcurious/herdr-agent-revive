#!/bin/sh
# agent-revive hook: remember which conversation this herdr-core terminal runs,
# so the agent-revive mod can resume it after the terminal is lost (reboot,
# core crash) and comes back as a plain shell.
#
#   hook.sh claude|codex     payload JSON on stdin (has "session_id")
#   hook.sh agy              id from $ANTIGRAVITY_CONVERSATION_ID
#   hook.sh opencode <id>    id as an argument (from the OpenCode plugin)
#
# It writes ~/.config/herdr-app/data/agent-revive/<terminal>.json, keyed by
# the herdr-core terminal ($HC_TERMINAL_ID; addresses survive core restarts):
#   agent  which agent
#   id     its conversation id
#   pid    the terminal's top-level shell pid when it was recorded
#          (a different pid later means core replaced the program)
#   cwd    the agent's folder
# (Not `hc label`: inside a Herdr terminal hc is scoped and can't see itself.)
#
# Prints nothing (Claude adds a SessionStart hook's output to the conversation)
# except "{}" for agy, and always exits 0 so it can never block an agent.
# AGENT_REVIVE_LOG=<file>: dry run, append what it would label to that file.

agent="$1"
[ "$agent" = agy ] && printf '{}\n'
[ -n "$HC_TERMINAL_ID" ] || exit 0

id=""
case "$agent" in
  claude|codex)
    input=$(cat 2>/dev/null)
    id=$(printf '%s' "$input" | tr ',{}' '\n\n\n' |
      sed -n 's/^[[:space:]]*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    ;;
  agy) id="$ANTIGRAVITY_CONVERSATION_ID" ;;
  opencode) id="$2" ;;
  *) exit 0 ;;
esac

# The id is typed into a shell later: accept only plain id characters.
case "$id" in ''|*[!A-Za-z0-9._:-]*) exit 0 ;; esac

# The terminal's top-level program is the ancestor whose parent is herdr-core.
top=""
p=$PPID
n=0
while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 40 ]; do
  pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [ -n "$pp" ] || break
  case "$(ps -o command= -p "$p" 2>/dev/null)" in
    # Claude's background daemon hosts the sessions of several terminals and
    # passes its starter's HC_TERMINAL_ID to all of them: the terminal can't
    # be told, so record nothing rather than resume into the wrong tab.
    *"claude daemon run"*|*bg-pty-host*|*bg-spare*) exit 0 ;;
  esac
  case "$(ps -o command= -p "$pp" 2>/dev/null)" in
    *herdr-core*) top=$p; break ;;
  esac
  p=$pp
  n=$((n + 1))
done

cwd=$(pwd -P 2>/dev/null)
# agy runs hooks from the folder holding hooks.json: ask for agy's own folder.
if [ "$agent" = agy ]; then
  cwd=$(readlink "/proc/$PPID/cwd" 2>/dev/null ||
    lsof -a -d cwd -p "$PPID" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
fi

if [ -n "$AGENT_REVIVE_LOG" ]; then
  printf '%s terminal=%s agent=%s id=%s pid=%s cwd=%s\n' \
    "$(date '+%F %T')" "$HC_TERMINAL_ID" "$agent" "$id" "$top" "$cwd" >> "$AGENT_REVIVE_LOG"
  exit 0
fi

case "$HC_TERMINAL_ID" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
record=$(printf '{"agent":"%s","id":"%s","pid":"%s","cwd":"%s"}' "$agent" "$id" "$top" "$(esc "$cwd")")

dir="${HERDR_APP_HOME:-$HOME/.config/herdr-app}/data/agent-revive"
file="$dir/$HC_TERMINAL_ID.json"
[ "$(cat "$file" 2>/dev/null)" = "$record" ] && exit 0
mkdir -p "$dir" 2>/dev/null &&
  printf '%s' "$record" > "$file.$$" 2>/dev/null &&
  mv -f "$file.$$" "$file" 2>/dev/null
rm -f "$file.$$" 2>/dev/null
exit 0
