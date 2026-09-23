// Pure presentation model for the foreground stdout pairing CLI (v3 design:
// "Native cold start and Meadow Host helper" + "Pairing display reliability").
//
// pair-popup.js paints a full-screen TUI in a herdr popup pane; this module
// is the stdout twin: everything the foreground CLI renders is derived here
// as PLAIN TEXT — no screen clears, no cursor control, no clamping to the
// viewport — so the output scrolls naturally through SSH and multiplexers
// and the copyable HERDR-PAIR payload is always on the terminal, never
// pushed into scrollback by a resize. The ceremony logic (credentials,
// expiry, enrollment polling, revocation) is shared code: pairing-session.js
// and the other ADR 0007 modules are the single protocol implementation.

import QRCode from "qrcode";

import { encodePairingCode } from "./envelope.js";
import { copyPairingCode } from "./copy-pairing-code.js";

export const DEFAULT_SSH_PORT = 22;

/** How long the QR screen waits before each enrollment-record poll. */
export const ENROLL_POLL_MS = 400;

/** Characters a wrapped chunk of the code must never split. */
const CODE_ALPHABET = /^[A-Za-z0-9_:.-]+$/;

const BOLD = "\u001b[1m";
const DIM = "\u001b[2m";
const RESET = "\u001b[0m";

function dim(text) {
  return `${DIM}${text}${RESET}`;
}

function bold(text) {
  return `${BOLD}${text}${RESET}`;
}

/** True when the terminal renders enough columns for the QR block. */
export function terminalFitsQr(columns) {
  return Number.isInteger(columns) && columns >= QR_MIN_COLUMNS;
}

export const QR_MIN_COLUMNS = 79;

/**
 * The Pairing Code payload assembled for a fresh ceremony, in the exact
 * shape encodePairingCode (envelope.js) validates.
 *
 * @param {{username: string, hostKeyFingerprint: string, addresses: string[], port?: number, bootstrapSeed: Buffer, expiresAt: number}} payload
 */
export function pairingCodePayload({ username, hostKeyFingerprint, addresses, port = DEFAULT_SSH_PORT, bootstrapSeed, expiresAt }) {
  return {
    addresses,
    port,
    username,
    hostKeyFingerprint,
    bootstrapSeed,
    expiresAt,
  };
}

/**
 * Terminal QR block. Returns null instead of a truncated rendering when the
 * terminal is too narrow (the design forbids truncating the QR to terminal
 * height/width; the wrapped text code below is the usable narrow path).
 *
 * @param {string} code canonical HERDR-PAIR string
 * @param {{columns?: number}} [size] measured terminal size
 * @returns {Promise<string | null>}
 */
export async function qrBlock(code, { columns } = {}) {
  if (!terminalFitsQr(columns)) {
    return null;
  }
  const qr = await QRCode.toString(code, { type: "terminal", small: true });
  return qr.trimEnd();
}

/**
 * Wrap the canonical code into copy-friendly chunk lines for narrow
 * terminals. Chunks are whitespace-free slices of the code itself; a human
 * (or the app's paste field) concatenates them without the line numbers.
 * Splitting the base64url body is display-only — the code stays one payload.
 *
 * @param {string} code
 * @param {{width?: number}} [options] chunk width, defaults to 56
 */
export function wrapCodeChunks(code, { width = 56 } = {}) {
  const safeWidth = Math.max(24, width);
  const chunks = [];
  for (let i = 0; i < code.length; i += safeWidth) {
    chunks.push(code.slice(i, i + safeWidth));
  }
  return chunks;
}

function isoTime(unixSeconds) {
  return new Date(unixSeconds * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC";
}


function relativeSeconds(unixSeconds, now) {
  return Math.max(0, unixSeconds - now);
}

/**
 * The full ceremony header: what is being paired, where to, for how long,
 * and the security warning for the temporary credential.
 *
 * @param {{username: string, hostname: string, addresses: string[], port: number, hostKeyFingerprint: string, expiresAt: number, now: number, sshDir: string}} info
 */
export function headerBlock({ username, hostname, addresses, port, hostKeyFingerprint, expiresAt, now, sshDir }) {
  const lines = [];
  lines.push(bold("Meadow host pairing"));
  lines.push("");
  lines.push(`Target host:   ${bold(`${username}@${hostname}`)} (you)`);
  lines.push(`SSH port:      ${port}`);
  lines.push(`Host key:      ${hostKeyFingerprint} ${dim(`(${sshDir})`)}`);
  lines.push(`Expires:       ${bold(isoTime(expiresAt))} ${dim(`(in ${relativeSeconds(expiresAt, now)}s, single use)`)}`);
  lines.push("");
  lines.push("Addresses the phone will try, in order:");
  for (const address of addresses) {
    lines.push(`  ${address}`);
  }
  lines.push("");
  lines.push(dim("This code carries a temporary SSH credential."));
  lines.push(dim("Treat it like a password: do not share, screenshot, or paste it"));
  lines.push(dim("anywhere except the Meadow app's pairing screen."));
  lines.push("");
  return lines.join("\n");
}

/**
 * The QR screen: header, then the QR (or the narrow-terminal text path),
 * then the copyable payload line(s) and key hints.
 *
 * @param {object} options
 * @param {ReturnType<typeof pairingCodePayload>} options.payload
 * @param {{hostname: string, sshDir: string, columns?: number, now: number}} options.info
 * @returns {Promise<{code: string, text: string}>} the canonical code and the
 *   full screen text to write to stdout
 */
export async function qrScreen({ payload, info }) {
  const code = encodePairingCode(payload);
  const header = headerBlock({ ...payload, hostname: info.hostname, sshDir: info.sshDir, now: info.now });
  const qr = await qrBlock(code, { columns: info.columns });
  const lines = [header];
  if (qr !== null) {
    lines.push(qr);
    lines.push("");
    lines.push(bold("Or copy this pairing code into Meadow:"));
    lines.push(code);
  } else {
    const width = Math.max(40, (info.columns ?? 80) - 8);
    const chunks = wrapCodeChunks(code, { width });
    const pad = String(chunks.length).length;
    lines.push(dim("(terminal too narrow for the QR -- paste the code below instead)"));
    lines.push("");
    for (const [index, chunk] of chunks.entries()) {
      lines.push(`${dim(`${String(index + 1).padStart(pad)}/${chunks.length}`)} ${chunk}`);
    }
    lines.push("");
    lines.push(dim("Join the chunks above into one line for Meadow's paste field, or"));
    lines.push(dim(`widen the terminal to >=${QR_MIN_COLUMNS} columns and press r to redraw.`));
  }
  lines.push("");
  lines.push(dim("Waiting for the phone... c: copy code, r: regenerate (revokes this one), q: quit"));
  return { code, text: lines.join("\n") };
}

/** Final status block after a successful Enrollment. */
export function enrolledBlock({ fingerprint, username, at }) {
  return [
    bold("Device enrolled."),
    "",
    `Device key ${fingerprint}`,
    `Enrolled by ${username} at ${isoTime(at)}`,
    "",
    "The bootstrap credential was consumed (single use). The device key",
    "now authenticates this phone to this host.",
    dim("Press r to revoke this device key, any other key to quit."),
  ].join("\n");
}

/** Status block for a ceremony that expired unenrolled. */
export function expiredBlock({ expiresAt }) {
  return [
    bold("Pairing code expired."),
    "",
    `It was valid until ${isoTime(expiresAt)} and no device used it.`,
    "The temporary credential has been revoked.",
    "",
    dim("Press return for a fresh code (revokes nothing -- this one is already"),
    dim("gone), or q to quit."),
  ].join("\n");
}

/** Status block when regeneration explicitly revoked the prior code. */
export function regeneratedBlock({ at }) {
  return [
    dim(`Previous code revoked at ${isoTime(at)}; minting a fresh one.`),
    "",
  ].join("\n");
}

/** Copy the code to the clipboard where a host-local helper exists. */
export async function copyCode(code) {
  return copyPairingCode(code);
}
