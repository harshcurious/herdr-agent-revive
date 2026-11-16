// agent-revive: after a reboot (or any time herdr-core loses a terminal and
// gives it back as a plain shell), start each agent again on its own
// conversation: claude --resume, codex resume, opencode -s, agy --conversation.
//
// The agents' hooks (hook.sh) write data/agent-revive/<terminal>.json:
// { agent, id, cwd, pid }, pid being the terminal's top-level program then.
// A terminal whose pid has changed was replaced by core, so its agent is gone:
// once its shell sits idle at the prompt, this types the resume command.
// When an agent simply exits (same pid, shell back at the prompt) the record
// is deleted, so a conversation you closed yourself never comes back.
//
// Draws nothing: it lives in an invisible floating block of the layout.

import { View, div } from "gpui-kit";
import { terminals, hc, checking, notify, appHome, home, writeTextFile } from "herdr";
import * as fs from "fs/promises";

const RESUME = {
  claude: (id) => `claude --resume ${id}`,
  codex: (id) => `codex --no-daemon resume ${id}`,
  opencode: (id) => `opencode -s ${id}`,
  agy: (id) => `agy --conversation ${id}`,
};
// What each agent's process is called (argv[0]), to tell it is running.
const PROGRAMS = {
  claude: ["claude"],
  codex: ["codex"],
  opencode: ["opencode", ".opencode"],
  agy: ["agy"],
};
const SHELLS = new Set(["zsh", "bash", "fish", "sh", "dash", "ksh", "nu", "pwsh"]);
const SAFE_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const SAFE_ADDRESS = /^[A-Za-z0-9_-]{1,32}$/;
const SCAN_MS = 3000;

const base = (s) => String(s ?? "").split("/").pop().replace(/^-/, "");
const quote = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

export default class AgentRevive extends View {
  init(_props, cx) {
    this.dir = `${appHome()}/data/agent-revive`;
    this.idle = new Map(); // address -> consecutive scans at an idle prompt
    this.missing = new Map(); // address -> consecutive scans not in terminals()
    this.busy = false;
    if (checking()) return;
    cx.timer.every(SCAN_MS, (cx) => {
      if (this.busy) return;
      this.busy = true;
      cx.spawn(async (cx) => {
        try { await this.scan(cx); }
        catch (e) { console.log(`agent-revive: ${e}`); }
        finally { this.busy = false; }
      });
    });
  }

  async records() {
    let names = [];
    try { names = await fs.readdir(this.dir); } catch { return new Map(); }
    const out = new Map();
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const address = name.slice(0, -5);
      if (!SAFE_ADDRESS.test(address)) continue;
      try {
        const text = await fs.readFile(`${this.dir}/${name}`, "utf8");
        out.set(address, { ...JSON.parse(text), text });
      }
      catch { /* a half-written or foreign file: skip it */ }
    }
    return out;
  }

  // Compare-and-swap: writes only if the file still holds `expected` (null:
  // only if there is none). Several copies of this mod can run (one per
  // layout block); whoever swaps first owns the action, the others skip it.
  async write(address, record, expected) {
    const { text: _drop, ...clean } = record;
    try {
      await writeTextFile(`${this.dir}/${address}.json`, JSON.stringify(clean), expected ?? null);
      return true;
    } catch { return false; }
  }

  async forget(address) {
    try { await fs.unlink(`${this.dir}/${address}.json`); } catch { /* already gone */ }
  }

  // A Claude started before its hook existed has no record yet: Claude Code
  // keeps ~/.claude/sessions/<pid>.json with its session id, so take it there.
  async adoptClaude(all, records) {
    for (const t of all) {
      const fg = t.foreground;
      if (records.has(t.address) || !SAFE_ADDRESS.test(t.address ?? "") || t.state !== "live") continue;
      if (!fg?.pid || !t.pid || base(fg.argv?.[0]) !== "claude") continue;
      try {
        const s = JSON.parse(await fs.readFile(`${home()}/.claude/sessions/${fg.pid}.json`, "utf8"));
        if (!SAFE_ID.test(s.sessionId ?? "")) continue;
        const r = { agent: "claude", id: s.sessionId, pid: String(t.pid), cwd: s.cwd ?? fg.cwd ?? "" };
        await fs.mkdir(this.dir, { recursive: true });
        if (await this.write(t.address, r, null)) records.set(t.address, { ...r, text: JSON.stringify(r) });
      } catch { /* no session file (yet) */ }
    }
  }

  async scan(_cx) {
    const records = await this.records();
    const all = terminals();
    await this.adoptClaude(all, records);
    if (!records.size) return;
    const byAddress = new Map(all.map((t) => [t.address, t]));
    const resumed = [];

    for (const [address, r] of records) {
      const t = byAddress.get(address);
      if (!t) {
        // Gone from core (closed). Wait for a listing that has terminals, twice.
        const n = all.length ? (this.missing.get(address) ?? 0) + 1 : 0;
        this.missing.set(address, n);
        if (n >= 2) { await this.forget(address); this.missing.delete(address); }
        continue;
      }
      this.missing.delete(address);
      if (t.state !== "live") { await this.forget(address); continue; }
      if (!RESUME[r.agent] || !SAFE_ID.test(r.id ?? "")) { await this.forget(address); continue; }

      const fg = t.foreground;
      const fgProgram = base(fg?.argv?.[0] ?? fg?.name);
      // A shell in the foreground: nothing else runs, it waits at its prompt.
      // (Its pid can differ from t.pid when Herdr wrapped the program in a shell.)
      const atPrompt = !!fg && SHELLS.has(base(fg.name)) && SHELLS.has(fgProgram);
      const running = !!fg && PROGRAMS[r.agent].includes(fgProgram);
      const seen = atPrompt ? (this.idle.get(address) ?? 0) + 1 : 0;
      this.idle.set(address, seen);
      const pid = t.pid ? String(t.pid) : "";

      if (running) {
        // The agent runs in this program now: keep the pid current, in case
        // its hook couldn't tell (or the agent was resumed by hand).
        if (pid && r.pid !== pid) await this.write(address, { ...r, pid }, r.text);
        continue;
      }
      if (seen < 2 || !pid) continue;

      if (!r.pid || r.pid === pid) {
        // Same program as when recorded and the agent is gone: it was closed.
        await this.forget(address);
      } else {
        // core replaced this terminal's program: resume the conversation.
        // Claim it first: only the copy whose swap succeeds types the command,
        // and a slow send can never type it twice.
        if (!(await this.write(address, { ...r, pid }, r.text))) continue;
        const cd = r.cwd && fg?.cwd && fg.cwd !== r.cwd ? `cd ${quote(r.cwd)} && ` : "";
        const res = await hc(["send", address, cd + RESUME[r.agent](r.id)]);
        if (res.code === 0) resumed.push(r.agent);
        else console.log(`agent-revive: hc send ${address}: ${res.stderr || res.stdout}`);
      }
    }

    if (resumed.length) {
      const n = resumed.length;
      notify({
        title: `Resumed ${n} agent session${n === 1 ? "" : "s"}`,
        body: [...new Set(resumed)].join(", "),
        level: "info",
      });
    }
  }

  render() {
    return div();
  }
}
