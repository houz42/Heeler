#!/usr/bin/env node
// Foreground stdout pairing CLI (v3 design: "Native cold start and Meadow
// Host helper" + "Pairing display reliability").
//
// The cold-start route the user verified is now an INSTALLED foreground
// command: a terminal-text QR and the SAME copyable HERDR-PAIR payload go
// straight to stdout — no herdr plugin-action dispatch, no popup pane, no
// remote graphics or clipboard dependency. It reuses the ADR 0007
// implementation unchanged (pairing-session.js mints the Bootstrap Key and
// the restricted authorized_keys line; pair-accept.js, run by sshd as the
// forced command, performs Enrollment) — this file is presentation and
// ceremony lifetime only; there is no second protocol.
//
// Ceremony rules (design):
//   - The foreground process stays alive while the user scans/copies.
//   - Normal exit, Ctrl-C, SSH disconnect (SIGHUP) and TTL expiry revoke an
//     unused bootstrap credential; successful enrollment consumes it.
//   - Regeneration (r) explicitly revokes the prior code before minting.
//   - Rerendering (redraw after a resize) reuses the live credential and
//     never mints a second one.
//   - Diagnostics go to stderr; the credential exists only on stdout, never
//     in routine logs.
//
// State location: the plugin's herdr state directory
// (${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/heeler), the same home
// pair-accept.js reads via --state-dir, so the popup, this CLI, and the
// accept script share one ceremony namespace. HERDR_PLUGIN_STATE_DIR wins
// when herdr invokes this entrypoint through its action dispatch.

import os from "node:os";
import { emitKeypressEvents } from "node:readline";
import { readEnrollment } from "./pairing-session.js";
import {
  beginPairing,
  endPairing,
  expirePairing,
  sweepExpiredStateFiles,
  PAIRING_TTL_SECONDS,
} from "./pairing-session.js";
import { candidateAddresses } from "./addresses.js";
import { readHostKeyFingerprint } from "./host-key.js";
import { commentOf, removeKeyLine, sweepExpiredBootstrapLines } from "./authorized-keys.js";
import {
  ENROLL_POLL_MS,
  copyCode,
  enrolledBlock,
  expiredBlock,
  pairingCodePayload,
  qrScreen,
  regeneratedBlock,
} from "./pair-stdout-model.js";

const SSH_DIR = process.env.MEADOW_SSH_DIR ?? "/etc/ssh";

function resolveStateDir() {
  if (process.env.HERDR_PLUGIN_STATE_DIR) {
    return process.env.HERDR_PLUGIN_STATE_DIR;
  }
  const stateHome = process.env.XDG_STATE_HOME ?? `${os.homedir()}/.local/state`;
  return `${stateHome}/herdr/plugins/heeler`;
}

function fatal(message) {
  process.stderr.write(`meadow pair: ${message}\n`);
  process.exit(1);
}

function usage() {
  process.stdout.write(
    [
      "meadow pair — print a Meadow Pairing Code (terminal QR + copyable text)",
      "              directly in this terminal and wait for the phone.",
      "",
      "Keys while the code is displayed:",
      "  c    copy the pairing code to the host clipboard (if available)",
      "  r    regenerate: revokes the current code and mints a fresh one",
      "  q    quit: revokes the unused credential and exits",
      "",
      "Environment:",
      "  MEADOW_SSH_DIR          host SSH config dir (default /etc/ssh)",
      "  HERDR_PLUGIN_STATE_DIR  pairing state dir (default ~/.local/state/herdr/plugins/heeler)",
      "",
    ].join("\n"),
  );
}


if (process.argv.includes("--help") || process.argv.includes("-h")) {
  usage();
  process.exit(0);
}

function toStderr(message) {
  process.stderr.write(`${message}\n`);
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function readKeys(onKey) {
  emitKeypressEvents(process.stdin);
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();
  process.stdin.on("keypress", (chunk, key) => {
    if (key === undefined) {
      return;
    }
    if (key.ctrl && key.name === "c") {
      // Route Ctrl-C through the same close path so cleanup runs.
      onKey({ name: "q", ctrl: true });
      return;
    }
    onKey(key);
  });
  // An SSH disconnect ends stdin; treat it as a quit so the bootstrap line
  // is revoked instead of outliving the session until TTL sweep.
  process.stdin.on("end", () => onKey({ name: "q", stdinEnded: true }));
  process.stdin.on("close", () => onKey({ name: "q", stdinEnded: true }));
}

function main() {
  const home = os.homedir();
  const stateDir = resolveStateDir();

  if (!process.stdout.isTTY) {
    // Still allow one-shot mint+print for scripted use: the credential is
    // printed and remains revocable via the TTL and startup sweeps.
    fatal("stdout is not a terminal; run `meadow pair` in an interactive shell");
    return;
  }

  const hostKey = readHostKeyFingerprint(SSH_DIR);
  if (hostKey === null) {
    fatal(`No SSH host key found under ${SSH_DIR}. Enable Remote Login (System Settings > General > Sharing) or run: sudo ssh-keygen -A`);
    return;
  }

  const candidates = candidateAddresses();
  if (candidates.length === 0) {
    fatal("No routable network address found. Connect to a LAN or VPN and retry.");
    return;
  }
  const addresses = candidates.map((c) => c.address);

  // Startup sweep: crashed or killed ceremonies must leave no residue.
  sweepExpiredBootstrapLines(home)
    .then((removed) => {
      if (removed > 0) {
        toStderr(`meadow pair: revoked ${removed} stale bootstrap line(s) from previous crashed ceremonies`);
      }
    })
    .catch((error) => toStderr(`meadow pair: bootstrap sweep failed: ${error.message}`));
  try {
    const stateRemoved = sweepExpiredStateFiles(stateDir);
    if (stateRemoved > 0) {
      toStderr(`meadow pair: removed ${stateRemoved} stale pairing state file(s)`);
    }
  } catch (error) {
    toStderr(`meadow pair: state sweep failed: ${error.message}`);
  }

  let phase = "qr"; // qr | enrolled | expired | revoked | fatal
  let session = null;
  let minting = false;
  let pendingRegenerate = false;
  let displayedCode = null;
  let expiryTimer = null;
  let enrollWatch = null;
  let enrolled = null;
  let closing = false;
  let lastExpiresAt = 0;

  async function cleanup() {
    if (expiryTimer !== null) {
      clearTimeout(expiryTimer);
      expiryTimer = null;
    }
    if (enrollWatch !== null) {
      clearInterval(enrollWatch);
      enrollWatch = null;
    }
    if (session !== null) {
      const { pairingId } = session;
      session = null;
      try {
        await endPairing({ home, stateDir, pairingId });
        toStderr(`meadow pair: pairing ${pairingId} closed; unused bootstrap credential revoked`);
      } catch (error) {
        toStderr(`meadow pair: revoke-on-exit failed for ${pairingId}: ${error.message} (startup sweeps will clean up after TTL)`);
      }
    }
  }

  async function close(code) {
    if (closing) {
      return;
    }
    closing = true;
    try {
      await cleanup();
    } finally {
      if (process.stdin.isTTY) {
        try {
          process.stdin.setRawMode(false);
        } catch {
          // stdin already gone (SSH disconnect)
        }
      }
      process.exit(code);
    }
  }

  for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) {
    process.on(signal, () => void close(0));
  }

  function enterEnrolled(record) {
    enrolled = record;
    phase = "enrolled";
    if (enrollWatch !== null) {
      clearInterval(enrollWatch);
      enrollWatch = null;
    }
    if (expiryTimer !== null) {
      clearTimeout(expiryTimer);
      expiryTimer = null;
    }
    process.stdout.write(`\n${enrolledBlock({ fingerprint: record.fingerprint, username: os.userInfo().username, at: record.enrolledAt ?? nowSeconds() })}\n`);
  }

  function onEnrollmentPoll(pairingId) {
    if (closing || phase !== "qr") {
      return;
    }
    const record = readEnrollment(stateDir, pairingId);
    if (record !== null) {
      enterEnrolled(record);
    }
  }

  async function expireCeremony(pairingId) {
    phase = "expired";
    if (enrollWatch !== null) {
      clearInterval(enrollWatch);
      enrollWatch = null;
    }
    const record = await expirePairing({ home, stateDir, pairingId });
    if (closing) {
      return;
    }
    if (record !== null) {
      // A device enrolled inside the accept lock right at the deadline.
      session = null;
      enterEnrolled(record);
      return;
    }
    session = null;
    displayedCode = null;
    process.stdout.write(`\n${expiredBlock({ expiresAt: lastExpiresAt })}\n`);
  }

  async function startCeremony({ announce } = {}) {
    if (session !== null) {
      // A rerender while a ceremony is live reuses its credential.
      return;
    }
    minting = true;
    try {
      if (announce) {
        process.stdout.write(`\n${regeneratedBlock({ at: nowSeconds() })}`);
      }
      session = await beginPairing({ home, stateDir });
      const { pairingId, expiresAt } = session;
      lastExpiresAt = expiresAt;
      const payload = pairingCodePayload({
        username: os.userInfo().username,
        hostKeyFingerprint: hostKey.fingerprint,
        addresses,
        bootstrapSeed: session.seed,
        expiresAt,
      });
      const columns = process.stdout.columns;
      const { code, text } = await qrScreen({
        payload,
        info: { hostname: os.hostname(), sshDir: SSH_DIR, columns, now: nowSeconds() },
      });
      displayedCode = code;
      process.stdout.write(`\n${text}\n`);
      expiryTimer = setTimeout(() => {
        expiryTimer = null;
        if (closing || phase !== "qr") {
          return;
        }
        void expireCeremony(pairingId);
      }, PAIRING_TTL_SECONDS * 1000);
      enrollWatch = setInterval(() => onEnrollmentPoll(pairingId), ENROLL_POLL_MS);
    } finally {
      minting = false;
    }
    // A regenerate requested mid-mint runs now, against a live session.
    if (pendingRegenerate) {
      pendingRegenerate = false;
      void regenerate();
    }
  }

  function startCeremonyOrDie() {
    startCeremony().catch((error) => {
      phase = "fatal";
      if (expiryTimer !== null) {
        clearTimeout(expiryTimer);
        expiryTimer = null;
      }
      if (enrollWatch !== null) {
        clearInterval(enrollWatch);
        enrollWatch = null;
      }
      toStderr(`meadow pair: could not start pairing: ${error.message}`);
      void close(1);
    });
  }

  async function revokeEnrolledDevice() {
    if (enrolled === null) {
      void close(0);
      return;
    }
    phase = "revoking";
    try {
      await removeKeyLine(home, enrolled.line);
    } catch (error) {
      toStderr(`meadow pair: revoke failed: ${error.message}`);
      phase = "enrolled";
      return;
    }
    phase = "revoked";
    process.stdout.write(`\nDevice key revoked (${commentOf(enrolled.line) || "no comment"}).\n`);
  }

  async function regenerate() {
    // A keypress can arrive while the current ceremony is still minting
    // (session not yet assigned): starting a second beginPairing there
    // would mint two live credentials and desync cleanup. Guard the whole
    // transition — the key is re-served once the live one is displayed.
    if (minting) {
      pendingRegenerate = true;
      return;
    }
    if (session !== null) {
      const { pairingId } = session;
      session = null;
      try {
        await endPairing({ home, stateDir, pairingId });
        toStderr(`meadow pair: previous code ${pairingId} revoked before minting a fresh one`);
      } catch (error) {
        toStderr(`meadow pair: previous code revoke failed: ${error.message}`);
      }
    }
    phase = "qr";
    startCeremonyOrDie();
  }

  async function copyDisplayedCode() {
    if (displayedCode === null || closing || phase !== "qr") {
      return;
    }
    const result = await copyCode(displayedCode);
    if (closing || phase !== "qr") {
      return;
    }
    if (result.copied) {
      process.stdout.write("\ncopied -- use the paste field in Meadow, or scan the QR\n");
    } else {
      process.stdout.write(`\nNo host-local clipboard helper; select the code above manually:\n${displayedCode}\n`);
    }
  }

  startCeremonyOrDie();

  readKeys((key) => {
    if (closing) {
      return;
    }
    if (phase === "revoking") {
      return;
    }
    if (key.name === "q" || key.name === "escape" || (key.ctrl && key.name === "c")) {
      void close(0);
      return;
    }
    if (phase === "enrolled") {
      if (key.name === "r") {
        void revokeEnrolledDevice();
      } else {
        void close(0);
      }
      return;
    }
    if (phase === "revoked") {
      void close(0);
      return;
    }
    if (phase === "expired") {
      if (key.name === "return") {
        phase = "qr";
        startCeremonyOrDie();
      } else {
        void close(0);
      }
      return;
    }
    if (phase === "qr") {
      if (key.name === "c" && !key.ctrl) {
        void copyDisplayedCode();
      } else if (key.name === "r") {
        void regenerate();
      }
      return;
    }
  });
}

main();
