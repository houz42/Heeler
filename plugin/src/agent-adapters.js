// Agent-adapter installation, owned by the heeler plugin.
//
// Adapters run INSIDE each agent process — no extra per-agent daemons. The
// only host-side artifact is ONE loader shim per supported agent, owned
// entirely by this plugin, importing the adapter from the synced runtime
// dir (never from the plugin checkout, which GitHub updates or plugin
// link swaps may repurpose mid-flight).
//
// Supported today: omp (loads every *.ts in ~/.omp/agent/extensions/).
// Scope rule: no new agent support is invented here — the registry lists
// exactly the agents the consolidation supports.

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { installedRuntime, brokerSocketPath } from "./broker-lifecycle.js";

/** One supported agent kind: where its loader shim lives + the shim body. */
export function ompExtensionDir() {
  return path.join(os.homedir(), ".omp", "agent", "extensions");
}

function shimBody(runtimeDir) {
  return `/**
 * Global loader for the Heeler (Meadow) agent-chat broker adapter.
 *
 * Auto-loaded by omp from ~/.omp/agent/extensions/. Registers every omp
 * agent on this host with the local Meadow chat broker so the Heeler iOS
 * client can reach it (chat over the broker, not the transcript file).
 *
 * MANAGED BY THE heeler herdr plugin (heeler.setup / heeler.status). Edit
 * nothing here by hand; uninstall with "herdr plugin action invoke
 * heeler.uninstall-adapters".
 *
 * CRITICAL: the socket path is set BEFORE the adapter import statement
 * executes — herdr-launched pane agents do NOT inherit shell env, so the
 * env MUST be set here, in-process, not assumed from the parent environment.
 */
process.env.HEELER_CHAT_SOCKET ??= ${JSON.stringify(brokerSocketPath())};
// Opt every agent into the broker's ask-interaction wrapper so blocked
// agents' questions surface as answerable cards in the Heeler app.
process.env.HEELER_CHAT_ASK_WRAPPER ??= "1";

import adapter from ${JSON.stringify(path.join(runtimeDir, "adapters", "omp", "extension.ts"))};

export default adapter;
`;
}

/**
 * Install the omp loader shim (idempotent). Returns the install result.
 * The shim name carries the plugin ownership: heeler-chat.ts. An existing
 * legacy shim (heeler-broker-chat.ts from the manual deployment era) is
 * MIGRATED: its content is compared, and it is replaced by the new shim —
 * running omp processes keep their old import path alive (their module is
 * already loaded), new omp processes load the new shim.
 */
export function installOmpAdapter() {
  const rt = installedRuntime();
  if (!rt.present) {
    return { installed: false, reason: "runtime_missing", hint: "run heeler.setup first" };
  }
  const dir = ompExtensionDir();
  fs.mkdirSync(dir, { recursive: true });
  const shimPath = path.join(dir, "heeler-chat.ts");
  const legacyPath = path.join(dir, "heeler-broker-chat.ts");
  fs.writeFileSync(shimPath, shimBody(rt.brokerDir));
  const migrated = fs.existsSync(legacyPath);
  if (migrated) fs.rmSync(legacyPath);
  return { installed: true, shimPath, runtimeDir: rt.brokerDir, version: rt.version, migratedLegacyShim: migrated };
}

/** Uninstall the plugin-owned shims (setup's inverse). */
export function uninstallOmpAdapter() {
  const dir = ompExtensionDir();
  const removed = [];
  for (const name of ["heeler-chat.ts", "heeler-broker-chat.ts"]) {
    const p = path.join(dir, name);
    if (fs.existsSync(p)) {
      fs.rmSync(p);
      removed.push(name);
    }
  }
  return { installed: false, removed };
}

/** Adapter status: shim presence + live registration count from the broker. */
export async function adapterStatus() {
  const shimPath = path.join(ompExtensionDir(), "heeler-chat.ts");
  const legacyPath = path.join(ompExtensionDir(), "heeler-broker-chat.ts");
  const registered = await liveAgentCount();
  return {
    omp: {
      shimInstalled: fs.existsSync(shimPath),
      shimPath,
      legacyShimPresent: fs.existsSync(legacyPath),
      liveRegistrations: registered,
    },
  };
}

/** Count agent registrations by asking the broker (sessions.list). */
function liveAgentCount() {
  return new Promise((resolve) => {
    const sock = net.connect(brokerSocketPath());
    let buf = "";
    const id = "status-1"; // wire contract: request ids are strings
    let settled = false;
    const finish = (v) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(v);
    };
    const timer = setTimeout(() => finish(null), 1500);
    sock.on("error", () => finish(null));
    sock.on("connect", () => {
      // The broker speaks only after the v1 hello handshake.
      sock.write(JSON.stringify({ type: "hello", protocol: 1, peer: "client" }) + "\n");
    });
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        let frame;
        try {
          frame = JSON.parse(line);
        } catch {
          return finish(null);
        }
        if (frame.type === "welcome") {
          const req = JSON.stringify({ type: "request", id, method: "sessions.list" }) + "\n";
          sock.write(req);
        } else if (frame.type === "response" && frame.id === id) {
          const sessions = frame.result?.sessions;
          finish(Array.isArray(sessions) ? sessions.length : null);
        } else if (frame.type === "error") {
          finish(null);
        }
      }
    });
  });
}
