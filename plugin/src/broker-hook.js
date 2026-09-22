#!/usr/bin/env node
// Broker startup hook — runs in EVERY herdr session (plugins are
// user-global; every herdr server on this host runs it), plus again on
// live handoff. It must therefore be genuinely idempotent and
// single-instance safe: when a broker already answers the wire probe,
// this hook exits without spawning anything. Only a session that finds
// NO live broker and NO live supervisor spawns one.
import { ensureBroker, probeBroker } from "./broker-lifecycle.js";

try {
  const probe = await probeBroker();
  if (probe.alive) {
    console.log("broker-hook: broker already running; no action");
  } else {
    const result = await ensureBroker({ log: (m) => console.log(`broker-hook: ${m}`) });
    console.log(`broker-hook: ${result.started ? "broker started" : `broker not started (${result.reason})`}`);
    if (!result.started && result.reason !== "already_running" && result.reason !== "owner_up") {
      process.exitCode = 1;
    }
  }
} catch (error) {
  console.error(`broker-hook: ${error.code ?? error.message}`);
  process.exitCode = 1;
}
