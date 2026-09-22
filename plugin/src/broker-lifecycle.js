// Meadow chat-broker host lifecycle: one shared, supervised broker per host,
// owned by the heeler herdr plugin.
//
// Contract (host-component consolidation):
//   - The broker is a LOGICAL INTERNAL component of the plugin, not a
//     separately installed product and not part of herdr core.
//   - ONE broker per host serves ALL agent types and every herdr session.
//     herdr runs [[startup]] hooks per session, so genuine host-wide
//     single-instance ownership is enforced with an owner SOCKET bound
//     (and held) by a detached supervisor process for the broker's
//     lifetime: a second herdr session probes, sees the owner alive and
//     the broker socket answering, and does NOT spawn another broker.
//   - Plugin startup may run in N sessions concurrently; none of them
//     may ever bounce the other's broker.
//
// Layout — the socket PATH is the migration invariant: it is the standard
// path the live deployment already uses (the launchd plist's --socket
// expansion and the omp loader shim's HEELER_CHAT_SOCKET default agree
// on it), so a plugin takeover happens without re-pairing anything:
//   <dataRoot>/broker.sock         the wire socket (unchanged path)
//   <dataRoot>/logs/broker.log     broker stdout/stderr + wire-observability
//   <stateRoot>/broker.owner.sock  the single-instance ownership socket
//   <stateRoot>/broker.owner.json  human-readable owner record
//   <stateRoot>/runtime/           synchronized broker runtime (see
//                                   syncRuntime — agent adapters are loaded
//                                   from here, never from the plugin
//                                   checkout, so GitHub-managed plugin
//                                   updates and herdr plugin link swaps
//                                   never yank code from a live broker)
//
// macOS + Linux: dataRoot = ${XDG_DATA_HOME:-~/.local/share}/meadow;
// stateRoot = ${XDG_STATE_HOME:-~/.local/state}/meadow on both.

import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export function meadowDataRoot() {
  return path.join(process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share"), "meadow");
}

export const BROKER_VERSION = "0.1.0"; // agent-chat package version bundled in the plugin

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(__dirname, "..");

export function meadowStateRoot() {
  return path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "meadow");
}

export function brokerSocketPath() {
  return path.join(meadowDataRoot(), "broker.sock");
}

export function brokerLogPath() {
  return path.join(meadowDataRoot(), "logs", "broker.log");
}

export function ownerSocketPath() {
  return path.join(meadowStateRoot(), "broker.owner.sock");
}

export function ownerRecordPath() {
  return path.join(meadowStateRoot(), "broker.owner.json");
}

export function runtimeDir() {
  return path.join(meadowStateRoot(), "runtime");
}

// ---------------------------------------------------------------------------
// Runtime sync: copy the bundled broker + adapters into runtimeDir with a
// version marker, so supervised processes and agent adapter shims always run
// STABLE paths while the plugin checkout may be swapped by plugin updates.
// A herdr plugin link (development) points at a user worktree: agents must
// never import from a checkout the developer may repurpose.

export function syncRuntime() {
  const src = path.join(PLUGIN_ROOT, "agent-chat");
  const dest = runtimeDir();
  const destBroker = path.join(dest, "broker");
  const staged = path.join(meadowStateRoot(), `runtime.staged-${process.pid}`);
  fs.rmSync(staged, { recursive: true, force: true });
  fs.mkdirSync(staged, { recursive: true });
  copyTree(path.join(src, "src"), path.join(staged, "broker", "src"));
  copyTree(path.join(src, "adapters"), path.join(staged, "broker", "adapters"));
  copyTree(path.join(src, "bin"), path.join(staged, "broker", "bin"));
  // The supervisor is self-contained in the runtime too: if the plugin
  // checkout disappears (uninstall, worktree cleanup), the running
  // supervisor can still supervise; a NEW one can be spawned by the next
  // plugin install.
  fs.copyFileSync(
    path.join(PLUGIN_ROOT, "src", "broker-supervisor.mjs"),
    path.join(staged, "broker", "broker-supervisor.mjs"),
  );
  fs.copyFileSync(path.join(src, "package.json"), path.join(staged, "broker", "package.json"));
  fs.writeFileSync(
    path.join(staged, "broker", "manifest.json"),
    JSON.stringify(
      {
        version: BROKER_VERSION,
        syncedFrom: src,
        syncedAt: new Date().toISOString(),
      },
      null,
      2,
    ) + "\n",
  );
  // Version-stamped manifest lives at the runtime root so a different
  // bundled version atomically replaces the whole runtime.
  fs.mkdirSync(dest, { recursive: true });
  fs.rmSync(path.join(dest, `broker-${BROKER_VERSION}`), { recursive: true, force: true });
  fs.renameSync(path.join(staged, "broker"), path.join(dest, `broker-${BROKER_VERSION}`));
  // 'broker' is a directory rename onto a possibly-existing dir; rename
  // over a non-empty dir fails, so move it aside first.
  const previous = path.join(dest, "broker");
  const retired = path.join(dest, `broker.retired-${process.pid}`);
  let hadPrevious = false;
  try {
    fs.renameSync(previous, retired);
    hadPrevious = true;
  } catch {}
  try {
    fs.renameSync(path.join(dest, `broker-${BROKER_VERSION}`), previous);
  } catch (err) {
    if (hadPrevious) fs.renameSync(retired, previous);
    throw err;
  }
  if (hadPrevious) fs.rmSync(retired, { recursive: true, force: true });
  // GC: drop every version-stamped dir that is not the active one.
  for (const entry of fs.readdirSync(dest)) {
    if (entry.startsWith("broker-") && entry !== `broker-${BROKER_VERSION}`) {
      fs.rmSync(path.join(dest, entry), { recursive: true, force: true });
    }
  }
  fs.rmSync(staged, { recursive: true, force: true });
  return {
    brokerDir: previous,
    brokerEntry: path.join(previous, "bin", "broker.mjs"),
    version: BROKER_VERSION,
  };
}

function copyTree(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const srcPath = path.join(from, entry.name);
    const destPath = path.join(to, entry.name);
    if (entry.isDirectory()) copyTree(srcPath, destPath);
    else if (entry.isFile()) fs.copyFileSync(srcPath, destPath);
  }
}

export function installedRuntime() {
  const brokerDir = path.join(runtimeDir(), "broker");
  let manifest = null;
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(brokerDir, "manifest.json"), "utf8"));
  } catch {}
  return {
    brokerDir,
    brokerEntry: path.join(brokerDir, "bin", "broker.mjs"),
    version: manifest?.version ?? null,
    present: fs.existsSync(path.join(brokerDir, "bin", "broker.mjs")),
  };
}

// ---------------------------------------------------------------------------
// Health

/** Probe the live broker socket with a real wire handshake (hello/welcome). */
export function probeBroker({ socketPath = brokerSocketPath(), timeoutMs = 1500 } = {}) {
  return new Promise((resolve) => {
    const sock = net.connect(socketPath);
    let settled = false;
    let buf = "";
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ alive: false, reason: "timeout" }), timeoutMs);
    sock.once("connect", () => {
      // Wire-level proof, not just an open socket file: send the v1 client
      // hello and require the welcome ack (NDJSON framing).
      sock.write(JSON.stringify({ type: "hello", protocol: 1, peer: "client" }) + "\n");
    });
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      try {
        const frame = JSON.parse(buf.slice(0, nl));
        if (frame.type === "welcome" && frame.protocol === 1) {
          finish({ alive: true });
        } else {
          finish({ alive: false, reason: "bad_welcome" });
        }
      } catch {
        finish({ alive: false, reason: "bad_frame" });
      }
    });
    sock.once("error", (err) => {
      finish({ alive: false, reason: err.code === "ENOENT" ? "no_socket" : err.code ?? "error" });
    });
  });
}
// ---------------------------------------------------------------------------
// Single-instance ownership + supervision
//
// The supervisor process binds a dedicated OWNER socket next to its pid
// record in the Meadow state root and holds it open for the broker's
// lifetime. Ownership is therefore a KERNEL fact: the bind is released
// when the process exits for any reason, and the broker's own stale-path
// hygiene (probe-before-remove, same-UID only) covers the crash case.
// A second herdr session's startup hook connects to the owner socket,
// reads the owner record, sees the lock alive, and does NOT spawn a
// second broker — no pidfiles to trust, no racy unlock step.



/** Ask the current owner for its record; null when no live owner exists. */
export function readOwner({ timeoutMs = 1000 } = {}) {
  return new Promise((resolve) => {
    const sock = net.connect(ownerSocketPath());
    let settled = false;
    const finish = (v) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(v);
    };
    const timer = setTimeout(() => finish(null), timeoutMs);
    let buf = "";
    sock.once("connect", () => {});
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      try {
        finish(JSON.parse(buf.slice(0, nl)));
      } catch {
        finish(null);
      }
    });
    sock.once("error", () => finish(null));
  });
}

/**
 * The supervisor: a small detached Node process that owns the owner
 * socket, spawns and supervises the broker, restarts it on abnormal exit
 * with backoff, and releases ownership on SIGTERM/SIGINT (broker drain:
// the supervisor stops the broker cleanly, adapters reconnect on their own).
 */
// Prefer the runtime's copy (self-contained; survives plugin uninstall).
export function supervisorModule() {
  const runtimeCopy = path.join(runtimeDir(), "broker", "broker-supervisor.mjs");
  if (fs.existsSync(runtimeCopy)) return runtimeCopy;
  return path.join(PLUGIN_ROOT, "src", "broker-supervisor.mjs");
}

/**
 * Ensure the host's broker is up. Idempotent and session-safe:
 *  1. wire-probe the broker socket — if alive, done (no spawn);
 *  2. read the owner socket — if a supervisor owns this host, the probe
 *     the race lost to it (it is mid-start); wait briefly for the socket;
 *  3. no owner: sync the runtime and spawn a detached supervisor.
 * Only one session can bind the owner socket, so concurrent startups
 * converge on a single broker even across many herdr sessions.
 */
export async function ensureBroker({ log } = {}) {
  const probe = await probeBroker();
  if (probe.alive) return { started: false, reason: "already_running" };
  const owner = await readOwner();
  if (owner) {
    // A supervisor owns this host: give it a moment to bring the socket up.
    for (let i = 0; i < 10; i++) {
      await sleep(200);
      if ((await probeBroker()).alive) return { started: false, reason: "owner_up", owner };
    }
    return { started: false, reason: "owner_not_up", owner };
  }
  syncRuntime();
  const rt = installedRuntime();
  const logPath = brokerLogPath();
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const out = fs.openSync(logPath, "a");
  const err = fs.openSync(logPath, "a");
  const child = spawn(process.execPath, [supervisorModule()], {
    stdio: ["ignore", out, err],
    detached: true,
    env: {
      ...process.env,
      MEADOW_BROKER_ENTRY: rt.brokerEntry,
      MEADOW_BROKER_SOCKET: brokerSocketPath(),
      MEADOW_OWNER_RECORD: ownerRecordPath(),
      MEADOW_BROKER_LOG: logPath,
    },
  });
  child.unref();
  log?.(`spawned supervisor pid ${child.pid}`);
  // Wait for the broker socket to answer before declaring success, so the
  // startup hook's outcome is the broker's actual state, not a spawn rc.
  for (let i = 0; i < 25; i++) {
    await sleep(200);
    if ((await probeBroker()).alive) return { started: true, supervisorPid: child.pid };
    if (child.exitCode !== null) break;
  }
  return { started: false, reason: "supervisor_exited", supervisorPid: child.pid };
}

/** Graceful stop: signal the supervisor; it stops the broker and exits. */
export async function stopBroker({ timeoutMs = 10_000 } = {}) {
  const owner = await readOwner();
  if (!owner?.pid) return { stopped: false, reason: "not_running" };
  try {
    process.kill(owner.pid, "SIGTERM");
  } catch (err) {
    if (err.code === "ESRCH") return { stopped: true, reason: "owner_dead" };
    throw err;
  }
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(250);
    if (!(await readOwner({ timeoutMs: 250 }))) return { stopped: true };
    const probe = await probeBroker({ timeoutMs: 500 });
    if (!probe.alive && !(await readOwner({ timeoutMs: 250 }))) return { stopped: true };
  }
  return { stopped: false, reason: "timeout", owner };
}

/** Upgrade: stop (if running), re-sync runtime from the plugin bundle, restart. */
export async function upgradeBroker() {
  const wasRunning = (await probeBroker()).alive;
  if (wasRunning) {
    const stop = await stopBroker();
    if (!stop.stopped) return { upgraded: false, reason: "stop_failed", stop };
  }
  const rt = syncRuntime();
  const result = await ensureBroker();
  return { upgraded: result.started || (await probeBroker()).alive, wasRunning, runtime: rt, result };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
