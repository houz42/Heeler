#!/usr/bin/env node
// Meadow broker supervisor — one per HOST, spawned detached by the heeler
// plugin's ensureBroker(). This process is the single-instance owner:
//
//   - binds the owner socket (kernel-released on death — the lock),
//   - spawns and supervises the broker (restart with backoff on abnormal
//     exit, stand down when the broker exits cleanly after a stop request),
//   - SIGTERM/SIGINT = graceful stop: stop the broker (adapters reconnect
//     on their own backoff once a new supervisor starts), remove sockets,
//     exit.
//
// Never talks to herdr; state lives in env + the Meadow state root.

import net from "node:net";
import fs from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import os from "node:os";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const BROKER_ENTRY = process.env.MEADOW_BROKER_ENTRY;
const SOCKET_PATH = process.env.MEADOW_BROKER_SOCKET;
const OWNER_RECORD = process.env.MEADOW_OWNER_RECORD;

if (!BROKER_ENTRY || !SOCKET_PATH) {
  console.error("fatal: MEADOW_BROKER_ENTRY and MEADOW_BROKER_SOCKET are required");
  process.exit(1);
}

function ownerSocketPath() {
  return path.join(path.dirname(OWNER_RECORD ?? ""), "broker.owner.sock");
}

// --- ownership --------------------------------------------------------------
const OWNER_PATH = ownerSocketPath();
fs.mkdirSync(path.dirname(OWNER_PATH), { recursive: true });

// Crash case: a stale owner socket from a dead supervisor. Probe it: if
// anything answers, a live supervisor owns this host — stand down (exit 0;
// the other supervisor is doing the job).
try {
  const alive = await probeOwner();
  if (alive) {
    console.log(`another supervisor owns this host (pid ${alive.pid}); standing down`);
    process.exit(0);
  }
} catch {}
// Same stale-path hygiene as the broker itself: same-UID socket + probe.
await removeStale(OWNER_PATH);

const ownerInfo = {
  role: "meadow-broker-supervisor",
  startedAt: new Date().toISOString(),
};

// --- supervision loop state (before any writeOwnerRecord call) ------------
let stopping = false;
let broker = null;
let backoffMs = 250;
const BACKOFF_MAX_MS = 5000;

const ownerServer = net.createServer((conn) => {
  conn.end(JSON.stringify({ ...ownerInfo, pid: process.pid }) + "\n");
});
try {
  await new Promise((resolve, reject) => {
    ownerServer.once("error", reject);
    ownerServer.listen(OWNER_PATH, resolve);
  });
} catch (err) {
  // Lost the bind race to a concurrent session's supervisor: stand down.
  if (err.code === "EADDRINUSE") {
    console.log("owner socket taken by a concurrent supervisor; standing down");
    process.exit(0);
  }
  console.error(`fatal: cannot bind owner socket: ${err.message}`);
  process.exit(1);
}
fs.chmodSync(OWNER_PATH, 0o600);
writeOwnerRecord();

function writeOwnerRecord() {
  const record = { ...ownerInfo, pid: process.pid, brokerPid: broker ? broker.pid : null };
  try {
    fs.writeFileSync(OWNER_RECORD, JSON.stringify(record, null, 2) + "\n");
  } catch {}
}

function startBroker() {
  broker = spawn(process.execPath, [BROKER_ENTRY, "--socket", SOCKET_PATH], {
    stdio: ["ignore", "inherit", "inherit"],
  });
  console.log(`[supervisor] broker pid ${broker.pid}`);
  writeOwnerRecord();
  broker.on("exit", (code, signal) => {
    broker = null;
    writeOwnerRecord();
    if (stopping) return;
    if (code === 0) return; // broker exited cleanly without a stop request: stand down
    console.log(`[supervisor] broker exited code=${code} signal=${signal}; restart in ${backoffMs}ms`);
    const wait = backoffMs;
    backoffMs = Math.min(backoffMs * 2, BACKOFF_MAX_MS);
    setTimeout(startBroker, wait).unref?.();
  });
}

async function shutdown() {
  if (stopping) return;
  stopping = true;
  if (broker) {
    broker.kill("SIGTERM");
    // The broker removes its own socket on clean exit. Give it a bounded
    // wait, then clean up ownership unconditionally.
    const deadline = Date.now() + 5000;
    while (broker && Date.now() < deadline) await sleep(100);
    if (broker) broker.kill("SIGKILL");
  }
  try {
    ownerServer.close();
  } catch {}
  try {
    fs.rmSync(OWNER_PATH, { force: true });
  } catch {}
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function probeOwner() {
  return new Promise((resolve, reject) => {
    const sock = net.connect(OWNER_PATH);
    let buf = "";
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      sock.destroy();
      v === undefined ? reject(new Error("closed")) : resolve(v);
    };
    sock.setTimeout(1000, () => finish(undefined));
    sock.on("data", (c) => {
      buf += c.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      try {
        finish(JSON.parse(buf.slice(0, nl)));
      } catch {
        finish(undefined);
      }
    });
    sock.on("error", () => finish(undefined));
    sock.on("close", () => finish(undefined));
  });
}

async function removeStale(p) {
  let st;
  try {
    st = fs.lstatSync(p);
  } catch (err) {
    if (err.code === "ENOENT") return;
    throw err;
  }
  if ((st.mode & 0o170000) !== 0o140000) throw new Error(`refusing non-socket path ${p}`);
  // Only remove when nothing answers (probeOwner rejects) and same-UID.
  let answers = false;
  try {
    await probeOwner();
    answers = true;
  } catch {}
  if (answers) throw Object.assign(new Error(`another supervisor owns ${p}`), { code: "EADDRINUSE" });
  if (st.uid !== (typeof process.getuid === "function" ? process.getuid() : -1)) {
    throw new Error(`refusing foreign-owned socket ${p}`);
  }
  fs.rmSync(p, { force: true });
}

startBroker();
