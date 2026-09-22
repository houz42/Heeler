#!/usr/bin/env node
// Executable entry for the agent-chat broker.
//
//   agent-chat-broker [--socket PATH] [--register-timeout MS] [--request-timeout MS]
//                     [--log PATH|-]
//
// Path may also come from AGENT_CHAT_SOCKET (alias HEELER_CHAT_SOCKET).
// --log PATH (or AGENT_CHAT_LOG): append wire-observability JSON lines to a
// file ('-' = stderr, the default). Rejections the broker returns to a
// client are also logged there, so a client-side generic error is
// traceable to the exact broker-side rejection.
// Exits 0 on SIGINT/SIGTERM after removing its own socket; exit 3 when
// another broker already owns the path; exit 1 on any fatal condition.
import process from 'node:process';
import fs from 'node:fs';
function arg(name, dflt) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : dflt;
}

const socketPath = arg('socket', process.env.AGENT_CHAT_SOCKET || process.env.HEELER_CHAT_SOCKET);
if (!socketPath) {
  console.error('fatal: --socket PATH or AGENT_CHAT_SOCKET is required');
  process.exit(1);
}

// Log sink for the executable: file append ('-' / unset = stderr). The
// sink serializes each event as one JSON line; write errors are swallowed
// (logging must never kill the broker) but the fd stays open with
// append semantics so rotation-by-recreate loses at most one line.
const logPath = arg('log', process.env.AGENT_CHAT_LOG);
let logSink;
if (logPath && logPath !== '-') {
  const fd = fs.openSync(logPath, 'a');
  logSink = (ev) => {
    try {
      fs.writeSync(fd, JSON.stringify(ev) + '\n');
    } catch {} // a broken log target must never break the broker
  };
}

const { startBroker } = await import('../src/broker.mjs');

let broker;
try {
  broker = await startBroker({
    socketPath,
    ...(arg('register-timeout') && { registerTimeoutMs: Number(arg('register-timeout')) }),
    ...(arg('request-timeout') && { requestTimeoutMs: Number(arg('request-timeout')) }),
    ...(logSink && { log: logSink }),
  });
} catch (err) {
  console.error(`fatal: ${err.message}`);
  process.exit(err.code === 'socket_in_use' ? 3 : 1);
}

console.log(`ready ${socketPath}`);

// SIGINT/SIGTERM: remove ONLY the socket this process bound (the broker's
// close() verifies the bound inode), then exit 0.
let closing = false;
async function shutdown() {
  if (closing) return;
  closing = true;
  try {
    await broker.close();
  } catch (err) {
    console.error(`warning: ${err.message}`);
  }
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
