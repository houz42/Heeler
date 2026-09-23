#!/usr/bin/env node
// Foreground paired-device management CLI (v3 design: Meadow Host helper —
// `meadow devices` lists enrolled device keys and `meadow devices revoke
// <fingerprint>` removes exactly one after a fingerprint-confirmation).
//
// Pure presentation and one-target orchestration on top of the ADR 0007
// primitives: the device lines were appended by pair-accept.js, the
// Enrollment records are read through listEnrollments, and revocation is
// removeKeyLine — the same blob-matched one-key removal the pairing popup
// offers. No broker, agent, or ceremony state is ever touched, and ceremony
// (bootstrap) lines are never listed as devices or revocable here.
//
// Exit codes: 0 success (including "nothing to revoke"), 1 runtime failure,
// 2 usage error, 3 declined confirmation / unknown fingerprint.

import os from "node:os";
import { createInterface } from "node:readline/promises";
import { listEnrollments } from "./pairing-session.js";
import { readAuthorizedKeysLines, removeKeyLine } from "./authorized-keys.js";
import { findDeviceByFingerprint, isRevokeConfirmation, listPairedDevices } from "./devices-model.js";

function isoTime(unixSeconds) {
  return new Date(unixSeconds * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC";
}

function resolveStateDir() {
  if (process.env.HERDR_PLUGIN_STATE_DIR) {
    return process.env.HERDR_PLUGIN_STATE_DIR;
  }
  const stateHome = process.env.XDG_STATE_HOME ?? `${os.homedir()}/.local/state`;
  return `${stateHome}/herdr/plugins/heeler`;
}

function fatal(message) {
  process.stderr.write(`meadow devices: ${message}\n`);
  process.exit(1);
}

function usage() {
  process.stdout.write(
    [
      "meadow devices — list and revoke enrolled Meadow device keys",
      "",
      "Usage:",
      "  meadow devices                    list every enrolled device key",
      "  meadow devices revoke <fingerprint>  remove one device key (asks",
      "                                      you to re-type its fingerprint)",
      "",
      "Fingerprints are the SHA256:… values the listing prints — the same",
      "fingerprint `meadow pair` reports when a phone enrolls.",
      "",
      "Environment:",
      "  HERDR_PLUGIN_STATE_DIR  pairing state dir (default ~/.local/state/herdr/plugins/heeler)",
      "",
    ].join("\n"),
  );
}

async function listingFor(home, stateDir) {
  const lines = readAuthorizedKeysLines(home);
  const enrollments = listEnrollments(stateDir);
  return listPairedDevices({ lines, enrollments });
}

function printListing(listing) {
  if (listing.devices.length === 0) {
    process.stdout.write("No enrolled Meadow device keys.\n");
    process.stdout.write(
      listing.ceremonies > 0
        ? `(A pairing ceremony is in flight; its bootstrap key is not a device key.)\n`
        : "Pair a phone with \`meadow pair\` to enroll its device key.\n",
    );
    return;
  }
  for (const device of listing.devices) {
    process.stdout.write(`${device.fingerprint}\n`);
    process.stdout.write(`  label:      ${device.label || "(none)"}\n`);
    process.stdout.write(
      device.enrolledAt === null
        ? "  enrolled:   unknown (no ceremony record survived)\n"
        : `  enrolled:   ${isoTime(device.enrolledAt)} (pairing ${device.pairingId})\n`,
    );
    process.stdout.write("  last used:  not tracked\n");
  }
  const extra =
    (listing.ceremonies > 0 ? `; ${listing.ceremonies} pairing ceremony line(s) not shown` : "") +
    (listing.otherLines > 0 ? `; ${listing.otherLines} unrelated key(s) left alone` : "");
  process.stdout.write(`\n${listing.devices.length} device key(s)${extra}\n`);
}

async function revoke(home, fingerprint) {
  const stateDir = resolveStateDir();
  const listing = await listingFor(home, stateDir);
  const device = findDeviceByFingerprint(listing, fingerprint);
  if (device === null) {
    process.stderr.write(
      `meadow devices: no enrolled Meadow device key with fingerprint ${fingerprint}\n`,
    );
    if (listing.devices.length > 0) {
      process.stderr.write("Enrolled fingerprints:\n");
      for (const other of listing.devices) {
        process.stderr.write(`  ${other.fingerprint}\n`);
      }
    }
    process.exit(3);
  }

  process.stdout.write("This removes ONE device key from this host's authorized_keys:\n");
  process.stdout.write(`  fingerprint: ${device.fingerprint}\n`);
  process.stdout.write(`  label:      ${device.label || "(none)"}\n`);
  process.stdout.write(`  key line:   ${device.line}\n`);
  process.stdout.write(`No other keys, the broker, or any agent are touched.\n`);
  const answer = await createInterface({ input: process.stdin }).question(
    `Re-type the fingerprint to revoke (Ctrl-C to cancel): `,
  );
  if (!isRevokeConfirmation(answer, device)) {
    process.stdout.write("Cancelled: the answer did not match the fingerprint exactly.\n");
    process.exit(3);
  }

  const removed = await removeKeyLine(home, device.line);
  if (!removed) {
    // Lost a race with a concurrent editor: refuse silently-succeeding.
    fatal("authorized_keys changed underneath the revoke; nothing removed");
  }
  process.stdout.write(`Revoked ${device.fingerprint}. That device's next connect is refused.\n`);
}

function main() {
  const home = os.homedir();
  const args = process.argv.slice(2);
  // The meadow launcher (and users) may invoke this entrypoint as
  // `meadow devices [revoke ...]` or `node devices-cli.js devices ...`;
  // drop the literal route word, the same way pair-cli ignores its "pair".
  const argv = args[0] === "devices" ? args.slice(1) : args;
  const [command, ...rest] = argv;

  if (command === "--help" || command === "-h" || command === "help") {
    usage();
    process.exit(0);
  }
  if (command === "revoke") {
    const fingerprint = rest[0];
    if (rest.length !== 1 || fingerprint === undefined || fingerprint === "") {
      process.stderr.write("meadow devices: revoke takes exactly one fingerprint\n\n");
      usage();
      process.exit(2);
    }
    revoke(home, fingerprint).catch((error) => fatal(error.message));
    return;
  }
  if (command !== undefined || rest.length > 0) {
    process.stderr.write(`meadow devices: unknown argument '${command ?? rest[0]}'\n\n`);
    usage();
    process.exit(2);
  }
  listingFor(home, resolveStateDir())
    .then(printListing)
    .catch((error) => fatal(error.message));
}

main();
