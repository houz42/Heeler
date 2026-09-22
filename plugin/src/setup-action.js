#!/usr/bin/env node
// heeler.setup / heeler.status / heeler.stop-broker / heeler.upgrade-broker —
// the ONE coherent setup/status surface for the consolidated host package.
//
//   herdr plugin action invoke heeler.setup            (install + start all)
//   herdr plugin action invoke heeler.status            (read-only report)
//   herdr plugin action invoke heeler.stop-broker       (graceful stop)
//   herdr plugin action invoke heeler.upgrade-broker    (stop + resync + start)
//   herdr plugin action invoke heeler.uninstall-adapters (remove omp shims)
//
// Output is plain text (for the invoking terminal) and a --json flag prints
// the machine-readable report instead.

import process from "node:process";
import fs from "node:fs";
import {
  BROKER_VERSION,
  meadowDataRoot,
  meadowStateRoot,
  brokerSocketPath,
  brokerLogPath,
  installedRuntime,
  ensureBroker,
  probeBroker,
  readOwner,
  stopBroker,
  upgradeBroker,
  syncRuntime,
} from "./broker-lifecycle.js";
import { installOmpAdapter, uninstallOmpAdapter, adapterStatus } from "./agent-adapters.js";
import { refreshSidebarSnapshot } from "./sidebar-config.js";

const actionId = process.env.HERDR_PLUGIN_ACTION_ID ?? "heeler.setup";
const json = process.argv.includes("--json");

function line(msg) {
  if (!json) process.stdout.write(msg + "\n");
}

async function status() {
  const [probe, owner, adapters, runtime] = await Promise.all([
    probeBroker(),
    readOwner(),
    adapterStatus(),
    Promise.resolve(installedRuntime()),
  ]);
  return {
    broker: {
      alive: probe.alive,
      probeReason: probe.reason ?? null,
      socketPath: brokerSocketPath(),
      version: runtime.version,
      runtimeDir: runtime.brokerDir,
      runtimePresent: runtime.present,
      bundledVersion: BROKER_VERSION,
      owner: owner ? { pid: owner.pid, startedAt: owner.startedAt, brokerPid: owner.brokerPid } : null,
      logPath: brokerLogPath(),
    },
    adapters: adapters,
    layout: {
      dataRoot: meadowDataRoot(),
      stateRoot: meadowStateRoot(),
    },
  };
}

try {
  if (actionId === "heeler.status") {
    const report = await status();
    if (json) {
      process.stdout.write(JSON.stringify(report, null, 2) + "\n");
    } else {
      const b = report.broker;
      line(`M Meadow broker  ${b.alive ? "up" : "down"}  (socket ${b.socketPath})`);
      line(`  runtime v${b.version ?? "none"} at ${b.runtimeDir} (plugin bundles v${b.bundledVersion})`);
      if (b.owner) line(`  supervisor pid ${b.owner.pid}, broker pid ${b.owner.brokerPid ?? "-"}, since ${b.owner.startedAt}`);
      line(`  log: ${b.logPath}`);
      const omp = report.adapters.omp;
      line(`M omp adapter    ${omp.shimInstalled ? "installed" : "not installed"}  (${omp.shimPath})`);
      if (omp.legacyShimPresent) line(`  legacy shim still present: heeler-broker-chat.ts (rerun setup to migrate)`);
      line(`  live agent registrations: ${omp.liveRegistrations ?? "broker unreachable"}`);
    }
  } else if (actionId === "heeler.setup") {
    // 1. Broker runtime + start (idempotent, single-instance safe).
    syncRuntime();
    const start = await ensureBroker();
    // 2. Adapter loader shims.
    const adapters = installOmpAdapter();
    // 3. Sidebar snapshot (unchanged pairing/sidebar helper surface).
    const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
    if (configDir) refreshSidebarSnapshot(configDir);
    const report = await status();
    if (json) {
      process.stdout.write(JSON.stringify({ start, adapters, status: report }, null, 2) + "\n");
    } else {
      line(`M Meadow host package setup`);
      line(`  broker : ${start.started ? "started (supervisor detached)" : start.reason === "already_running" ? "already running" : `NOT running (${start.reason})`}`);
      line(`  runtime: v${report.broker.version} at ${report.broker.runtimeDir}`);
      line(`  socket : ${report.broker.socketPath} ${report.broker.alive ? "(alive, wire handshake ok)" : "(DOWN)"}`);
      line(`  adapter: ${adapters.installed ? `omp shim installed at ${adapters.shimPath}` : `install FAILED: ${adapters.reason}`}${adapters.migratedLegacyShim ? " (migrated legacy heeler-broker-chat.ts)" : ""}`);
      line(`  agents : ${report.adapters.omp.liveRegistrations ?? "none yet (new omp sessions register as they start)"} live registration(s)`);
    }
    if (!report.broker.alive) process.exitCode = 1;
  } else if (actionId === "heeler.stop-broker") {
    const result = await stopBroker();
    if (json) process.stdout.write(JSON.stringify(result) + "\n");
    else line(`M stop-broker: ${result.stopped ? "stopped" : `not stopped (${result.reason})`}`);
    if (!result.stopped && result.reason !== "not_running") process.exitCode = 1;
  } else if (actionId === "heeler.upgrade-broker") {
    const result = await upgradeBroker();
    if (json) process.stdout.write(JSON.stringify(result, null, 2) + "\n");
    else line(`M upgrade-broker: ${result.upgraded ? "upgraded and running" : `FAILED (${JSON.stringify(result)})`}`);
    if (!result.upgraded) process.exitCode = 1;
  } else if (actionId === "heeler.uninstall-adapters") {
    const result = uninstallOmpAdapter();
    if (json) process.stdout.write(JSON.stringify(result) + "\n");
    else line(`M uninstall-adapters: removed ${result.removed.join(", ") || "nothing"}`);
  } else {
    console.error(`setup-action: unknown action ${actionId}`);
    process.exitCode = 2;
  }
} catch (error) {
  console.error(`setup-action: ${error.message}`);
  process.exitCode = 1;
}
