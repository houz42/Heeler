// Paired-device listing and revocation (v3 design: Meadow Host helper —
// "Settings lists paired clients", realized host-locally as the foreground
// `meadow devices` CLI).
//
// The authoritative record of a paired device is its authorized_keys line:
// pair-accept.js appended it atomically during Enrollment and removeKeyLine
// revokes by matching the key blob. This module never edits authorized_keys
// itself — revocation goes through removeKeyLine, one key, under the same
// exclusive lock every other mutation takes.
//
// Classification:
//   - ceremony line: carries the herdr-pairing marker (bootstrap key, live
//     or stale). Counted for context, never listed or revocable here; their
//     lifecycle belongs to pairing (TTL expiry, sweeps, endPairing).
//   - device key: an enrolled Meadow app Device Key. The app enrolls with
//     comment "heeler" (SSHPairingConnector.deviceKeyComment), and a fresh
//     Enrollment record names the exact fingerprint and line.
//   - other line: anything else. Never listed as a device, never touched by
//     a revoke — a revoke that removes exactly one target and preserves
//     every unrelated key is the core contract.
//
// last-used is not tracked anywhere on the host (sshd logs are not parsed),
// so the listing reports that honestly rather than inventing a timestamp.

import { keyBlobOf, commentOf, parseBootstrapLine } from "./authorized-keys.js";
import { fingerprintPublicKeyLine } from "./host-key.js";

/** The comment the Meadow app enrolls its Device Key with. */
export const DEVICE_KEY_COMMENT = "heeler";

/**
 * Build the paired-device listing from the current authorized_keys lines and
 * the surviving Enrollment records. Pure: no filesystem access, so callers
 * and tests decide where the inputs come from.
 *
 * @param {object} options
 * @param {string[]} options.lines authorized_keys lines (no trailing newline)
 * @param {object[]} [options.enrollments] Enrollment records from
 *   listEnrollments; when one names a key's fingerprint its ceremony
 *   pairing-id and expiry become that device's enrolledAt source
 * @returns {{devices: object[], ceremonies: number, otherLines: number}}
 */
export function listPairedDevices({ lines, enrollments = [] }) {
  const byFingerprint = new Map();
  for (const record of enrollments) {
    if (typeof record.fingerprint === "string" && record.fingerprint !== "") {
      byFingerprint.set(record.fingerprint, record);
    }
  }

  const devices = [];
  let ceremonies = 0;
  let otherLines = 0;
  for (const line of lines) {
    if (line.trim() === "") {
      continue;
    }
    if (parseBootstrapLine(line) !== null) {
      ceremonies += 1;
      continue;
    }
    let keyType;
    let fingerprint;
    try {
      ({ keyType, fingerprint } = fingerprintPublicKeyLine(line));
    } catch {
      otherLines += 1;
      continue;
    }
    const comment = commentOf(line);
    const enrollment = byFingerprint.get(fingerprint) ?? null;
    const isDevice = comment === DEVICE_KEY_COMMENT || enrollment !== null;
    if (!isDevice) {
      otherLines += 1;
      continue;
    }
    devices.push({
      fingerprint,
      keyType,
      label: comment,
      line,
      enrolledAt: enrollment === null ? null : enrollment.expiresAt,
      pairingId: enrollment === null ? null : enrollment.pairingId,
    });
  }
  return { devices, ceremonies, otherLines };
}

/**
 * Find one device by exact fingerprint (SHA256:…, as printed by the listing
 * and by pair-accept's HERDR-ENROLL:OK line).
 *
 * @returns {object|null} the device entry, or null when no enrolled device
 *   key carries that fingerprint
 */
export function findDeviceByFingerprint(listing, fingerprint) {
  return listing.devices.find((device) => device.fingerprint === fingerprint) ?? null;
}

/** True when the answer confirms revoking exactly this device. */
export function isRevokeConfirmation(answer, device) {
  return answer.trim() === device.fingerprint;
}
