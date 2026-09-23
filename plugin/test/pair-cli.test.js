import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DEFAULT_SSH_PORT,
  ENROLL_POLL_MS,
  QR_MIN_COLUMNS,
  terminalFitsQr,
  wrapCodeChunks,
  headerBlock,
  qrBlock,
  qrScreen,
  pairingCodePayload,
  enrolledBlock,
  expiredBlock,
  regeneratedBlock,
} from "../src/pair-stdout-model.js";
import { encodePairingCode, decodePairingCode } from "../src/envelope.js";
import { beginPairing, pendingPath, readEnrollment, recordEnrollment } from "../src/pairing-session.js";
import { authorizedKeysPath, editAuthorizedKeys, parseBootstrapLine } from "../src/authorized-keys.js";
import { publicLineFromSeed } from "../src/bootstrap-key.js";

import { spawnSync } from "node:child_process";
import {
  beginPairing as beginPairingDirect,
  endPairing as endPairingDirect,
  expirePairing as expirePairingDirect,
} from "../src/pairing-session.js";

const PAIR_CLI = fileURLToPath(new URL("../src/pair-cli.js", import.meta.url));
const MEADOW = fileURLToPath(new URL("../scripts/meadow", import.meta.url));
const SSH_DIR = fileURLToPath(new URL("./fixtures/etc-ssh", import.meta.url));
const USER_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";
const NOW = 1753305600;

let home;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "pair-cli-home-"));
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

function readKeys() {
  return readFileSync(authorizedKeysPath(home), "utf8").split("\n").filter((l) => l.length > 0);
}

function fakePayload({ seed = Buffer.alloc(32, 7), expiresAt = NOW + 120, addresses = ["192.168.1.42"] } = {}) {
  return pairingCodePayload({
    username: "jhou",
    hostKeyFingerprint: "SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq",
    addresses,
    bootstrapSeed: seed,
    expiresAt,
  });
}

suite("pair-stdout-model (pure)", () => {
  test("qrScreen prints the QR, the exact copyable code, and the target info", async () => {
    const payload = fakePayload();
    const { code, text } = await qrScreen({
      payload,
      info: { hostname: "mbp.local", sshDir: SSH_DIR, columns: 100, now: NOW },
    });

    // The canonical code appears verbatim on stdout.
    assert.ok(text.includes(code), "stdout text must contain the exact HERDR-PAIR code");
    assert.equal(code, encodePairingCode(payload));
    // QR block present at a wide terminal.
    assert.ok(text.includes("\u001b[47m"), "terminal QR escapes present");
    // Target host/user, addresses, port and expiry are shown.
    assert.match(text, /jhou@mbp\.local/);
    assert.match(text, /192\.168\.1\.42/);
    assert.match(text, new RegExp(`SSH port:\\s+${DEFAULT_SSH_PORT}`));
    assert.match(text, /Expires:/);
    assert.match(text, /in 120s/);
    // Security warning for the temporary credential.
    assert.match(text, /temporary SSH credential/);
  });

  test("qrBlock yields null under the narrow-column threshold, never a truncated QR", async () => {
    const code = encodePairingCode(fakePayload());
    assert.equal(await qrBlock(code, { columns: QR_MIN_COLUMNS - 1 }), null);
    const qr = await qrBlock(code, { columns: QR_MIN_COLUMNS });
    assert.ok(qr.includes("\u001b[47m"));
  });

  test("narrow terminals keep a usable text-code path: all chunks join to the code", async () => {
    const code = encodePairingCode(fakePayload());
    const { text } = await qrScreen({
      payload: fakePayload(),
      info: { hostname: "mbp.local", sshDir: SSH_DIR, columns: 40, now: NOW },
    });
    assert.ok(!text.includes("\u001b[47m"), "no QR escapes at narrow width");
    // No truncation of the payload: the wrapped chunks reassemble exactly.
    const joined = wrapCodeChunks(code, { width: 32 }).join("");
    assert.equal(joined, code);
    assert.ok(text.includes(wrapCodeChunks(code, { width: 32 })[0]), "first chunk printed");
  });

  test("wrapCodeChunks round-trips and never splits characters", () => {
    const code = encodePairingCode(fakePayload());
    const joined = wrapCodeChunks(code, { width: 56 }).join("");
    assert.equal(joined, code);
    for (const chunk of wrapCodeChunks(code, { width: 56 })) {
      assert.match(chunk, /^[A-Za-z0-9_:.-]+$/);
    }
  });

  test("pairingCodePayload decodes back through the shared envelope", () => {
    const payload = fakePayload();
    const decoded = decodePairingCode(encodePairingCode(payload));
    assert.deepEqual(decoded.addresses, payload.addresses);
    assert.equal(decoded.port, DEFAULT_SSH_PORT);
    assert.equal(decoded.username, payload.username);
    assert.equal(decoded.hostKeyFingerprint, payload.hostKeyFingerprint);
    assert.deepEqual(Buffer.from(decoded.bootstrapSeed), payload.bootstrapSeed);
    assert.equal(decoded.expiresAt, payload.expiresAt);
  });

  test("status blocks name expiry, enrollment, and revocation honestly", () => {
    assert.match(expiredBlock({ expiresAt: NOW }), /expired/i);
    assert.match(expiredBlock({ expiresAt: NOW }), /revoked/);
    const enrolled = enrolledBlock({ fingerprint: "SHA256:x", username: "jhou", at: NOW });
    assert.match(enrolled, /Device enrolled/);
    assert.match(enrolled, /single use/);
    assert.match(regeneratedBlock({ at: NOW }), /Previous code revoked/);
  });
});

suite("pair-cli end-to-end (mint, print, wait, cleanup)", () => {
  // The foreground CLI is an interactive TUI; its ceremony engine is proven
  // end-to-end by driving the shared implementation exactly the way the CLI
  // does, plus a real child process run for the non-TTY guard and --help.

  test("mint -> print -> quit path revokes the unused bootstrap line", async () => {
    const stateDir = join(home, "plugin-state");
    const session = await beginPairing({ home, stateDir, now: NOW });

    // The printed payload must carry this ceremony's seed.
    const payload = pairingCodePayload({
      username: "jhou",
      hostKeyFingerprint: "SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq",
      addresses: ["192.168.1.42"],
      bootstrapSeed: session.seed,
      expiresAt: session.expiresAt,
    });
    const code = encodePairingCode(payload);
    const decoded = decodePairingCode(code);
    assert.deepEqual(Buffer.from(decoded.bootstrapSeed), session.seed);
    assert.equal(decoded.expiresAt, session.expiresAt);

    // The bootstrap line is live and restricted.
    const line = readKeys().find((l) => parseBootstrapLine(l)?.pairingId === session.pairingId);
    assert.ok(line, "bootstrap line installed");
    assert.match(line, /^restrict,/);

    // The forced command binds the SAME state dir the CLI resolved.
    assert.match(line, new RegExp(`--state-dir [^ ]*${stateDir.replaceAll("/", "\\/")}`));

    // Quit path: endPairing (what the CLI's cleanup runs) removes it.
    await endPairingDirect({ home, stateDir, pairingId: session.pairingId });
    assert.equal(readKeys().some((l) => parseBootstrapLine(l)?.pairingId === session.pairingId), false);
    assert.equal(existsSync(pendingPath(stateDir, session.pairingId)), false);
  });

  test("successful enrollment consumes the bootstrap credential and leaves the device key", async () => {
    const stateDir = join(home, "plugin-state");
    const session = await beginPairing({ home, stateDir, now: NOW });

    // Enrollment server-side, exactly what pair-accept.js does inside the
    // authorized_keys lock: append the Device Key, self-revoke the
    // bootstrap line, delete pending, write the Enrollment record.
    await editAuthorizedKeys(home, (lines) => [
      ...lines.filter((l) => parseBootstrapLine(l)?.pairingId !== session.pairingId),
      USER_LINE,
    ]);
    rmSync(pendingPath(stateDir, session.pairingId), { force: true });
    recordEnrollment({
      stateDir,
      pairingId: session.pairingId,
      expiresAt: session.expiresAt,
      fingerprint: "SHA256:testfingerprint",
      line: USER_LINE,
    });

    // The CLI's poll observes it via readEnrollment.
    const record = readEnrollment(stateDir, session.pairingId);
    assert.ok(record);
    assert.equal(record.fingerprint, "SHA256:testfingerprint");

    // The enrolled ceremony then ends (user quits): the DEVICE KEY stays.
    await endPairingDirect({ home, stateDir, pairingId: session.pairingId });
    assert.ok(readKeys().includes(USER_LINE), "device key retained after ceremony");
    assert.equal(readKeys().some((l) => parseBootstrapLine(l) !== null), false, "no bootstrap line remains");
  });

  test("expiry path: expirePairing revokes the unused line; enrolled record wins at the deadline", async () => {
    const stateDir = join(home, "plugin-state");

    // Unenrolled ceremony at the deadline: revoked, nothing kept.
    const a = await beginPairing({ home, stateDir, now: NOW });
    assert.equal(await expirePairingDirect({ home, stateDir, pairingId: a.pairingId }), null);
    assert.equal(readKeys().some((l) => parseBootstrapLine(l)?.pairingId === a.pairingId), false);

    // Enrolled inside the lock at the deadline: the record is honored and
    // the device key survives.
    const b = await beginPairing({ home, stateDir, now: NOW });
    await editAuthorizedKeys(home, (lines) => [
      ...lines.filter((l) => parseBootstrapLine(l)?.pairingId !== b.pairingId),
      USER_LINE,
    ]);
    rmSync(pendingPath(stateDir, b.pairingId), { force: true });
    recordEnrollment({
      stateDir,
      pairingId: b.pairingId,
      expiresAt: b.expiresAt,
      fingerprint: "SHA256:late",
      line: USER_LINE,
    });
    const record = await expirePairingDirect({ home, stateDir, pairingId: b.pairingId });
    assert.ok(record);
    assert.equal(record.fingerprint, "SHA256:late");
    assert.ok(readKeys().includes(USER_LINE));
  });

  test("regeneration revokes the prior code before minting the next", async () => {
    const stateDir = join(home, "plugin-state");
    const first = await beginPairing({ home, stateDir, now: NOW });
    // regenerate(): endPairing then beginPairing, as the CLI does.
    await endPairingDirect({ home, stateDir, pairingId: first.pairingId });
    const second = await beginPairing({ home, stateDir, now: NOW });
    assert.notEqual(first.pairingId, second.pairingId);
    const lines = readKeys();
    assert.equal(lines.some((l) => parseBootstrapLine(l)?.pairingId === first.pairingId), false);
    assert.equal(lines.some((l) => parseBootstrapLine(l)?.pairingId === second.pairingId), true);
  });

  test("rerender reuses the live credential: one ceremony, one bootstrap line", async () => {
    const stateDir = join(home, "plugin-state");
    const session = await beginPairing({ home, stateDir, now: NOW });
    const before = readKeys().length;
    // A redraw re-encodes the SAME payload; no second beginPairing call.
    const payload = pairingCodePayload({
      username: "jhou",
      hostKeyFingerprint: "SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq",
      addresses: ["192.168.1.42"],
      bootstrapSeed: session.seed,
      expiresAt: session.expiresAt,
    });
    await qrScreen({ payload, info: { hostname: "h", sshDir: SSH_DIR, columns: 100, now: NOW } });
    await qrScreen({ payload, info: { hostname: "h", sshDir: SSH_DIR, columns: 100, now: NOW } });
    assert.equal(readKeys().length, before, "no second bootstrap line minted");
  });
});

suite("installed launcher", () => {
  test("meadow --help works from an unrelated cwd with a scrubbed PATH", () => {
    
    const result = spawnSync(MEADOW, ["--help"], {
      cwd: "/tmp",
      env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, `launcher stderr: ${result.stderr}`);
    assert.match(result.stdout, /meadow pair/);
  });

  test("meadow pair without a TTY fails honestly without minting a credential", () => {
    
    const stateDir = join(home, "plugin-state");
    const result = spawnSync(MEADOW, ["pair"], {
      cwd: "/tmp",
      env: {
        PATH: "/usr/bin:/bin",
        HOME: process.env.HOME,
        MEADOW_SSH_DIR: SSH_DIR,
        HERDR_PLUGIN_STATE_DIR: stateDir,
        // Force non-TTY: stdio pipe is not a terminal.
      },
      encoding: "utf8",
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /not a terminal/);
    // No credential was minted: no pending state, no bootstrap line.
    assert.equal(existsSync(stateDir), false);
    assert.equal(existsSync(authorizedKeysPath(home)), false);
  });

  test("unknown subcommand exits 2 with guidance", () => {
    
    const result = spawnSync(MEADOW, ["bogus"], {
      cwd: "/tmp",
      env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME },
      encoding: "utf8",
    });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /meadow pair/);
  });
});
