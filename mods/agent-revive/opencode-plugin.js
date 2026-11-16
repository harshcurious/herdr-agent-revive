// agent-revive: tells Herdr which OpenCode session this terminal shows, so the
// Herdr agent-revive mod can run `opencode -s <id>` here after a reboot.
// The labelling itself is done by ~/.config/herdr-app/mods/agent-revive/hook.sh.
import { spawn } from "node:child_process";

const APP_HOME = process.env.HERDR_APP_HOME
  || `${process.env.XDG_CONFIG_HOME || `${process.env.HOME}/.config`}/herdr-app`;
const HOOK = `${APP_HOME}/mods/agent-revive/hook.sh`;

export default {
  id: "agent-revive",
  setup(ctx) {
    // Only inside a herdr-core terminal.
    if (!process.env.HC_TERMINAL_ID) return;
    let last = "";
    const report = () => {
      try {
        const route = ctx.ui.router.current();
        if (route.type !== "session") return;
        const id = ctx.data.session.root(route.sessionID);
        const info = ctx.data.session.get(id);
        if (!info || info.parentID || id === last) return;
        last = id;
        const child = spawn("/bin/sh", [HOOK, "opencode", id], {
          stdio: "ignore",
          cwd: info.location?.directory || process.cwd(),
        });
        child.on("error", () => { last = ""; });
      } catch { /* never disturb the TUI */ }
    };
    const timer = setInterval(report, 1000);
    report();
    return () => clearInterval(timer);
  },
};
