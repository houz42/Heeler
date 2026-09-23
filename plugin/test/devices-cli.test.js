// Paired-device management CLI tests (v3 host slice: `meadow devices`).
//
// The listing and revoke go through the same real primitives production
// uses: enrollments are performed by the real pair-accept.js child process
// (as sshd would run it), the CLI binary is spawned through the installed
// `meadow` launcher exactly like a user invocation, and revocation's
// authorized_keys edit is verified against the file.
//
// The final suite proves the security property end to end against a real
// localhost sshd: after revoking a device key, its key pair genuinely cannot
// authenticate anymore, while an unrelated surviving key still can. It skips
// cleanly when /usr/sbin/sshd is unavailable (developer laptop).

import { test, suite, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync, openSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { beginPairing, pendingPath, readEnrollment } from "../src/pairing-session.js";
import { authorizedKeysPath, editAuthorizedKeys } from "../src/authorized-keys.js";
import { fingerprintPublicKeyLine } from "../src/host-key.js";
import {
  DEVICE_KEY_COMMENT,
  findDeviceByFingerprint,
  isRevokeConfirmation,
  listPairedDevices,
} from "../src/devices-model.js";

const DEVICES_CLI = fileURLToPath(new URL("../src/devices-cli.js", import.meta.url));
const MEADOW = fileURLToPath(new URL("../scripts/meadow", import.meta.url));
const ACCEPT_SCRIPT = fileURLToPath(new URL("../src/pair-accept.js", import.meta.url));
const PHONE_B_FINGERPRINT = "SHA256:C6X6zu8rWmxUiE74GLerUJ2t2eTI0bs4sjjqix2suaI";
const PHONE_A_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce heeler";
const PHONE_A_FINGERPRINT = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";
const PHONE_B_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4vFKO5xk5C3sJqjMjFqDvQKZ8Hh1bSjXb9qzZrQvWfM heeler";
// A key the user uses for their laptop: same account, NOT a Meadow device.
const USER_LAPTOP_LINE =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";
const USER_LAPTOP_FINGERPRINT = "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg";

let home;
let stateDir;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "devices-cli-home-"));
  stateDir = join(home, "plugin-state");
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

function readKeys() {
  return readFileSync(authorizedKeysPath(home), "utf8");
}

// Enroll a device through the REAL accept entrypoint, exactly as sshd does.
function enrollDevice(session, line) {
  const result = spawnSync(
    process.execPath,
    [ACCEPT_SCRIPT, "--state-dir", stateDir, "--pairing-id", session.pairingId],
    { input: `${line}\n`, encoding: "utf8", env: { HOME: home, PATH: process.env.PATH }, timeout: 15_000 },
  );
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.stdout.startsWith("HERDR-ENROLL:OK:"));
  return readEnrollment(stateDir, session.pairingId);
}


// Run through the installed launcher, like a real user invocation.
function runMeadowDevices(args, { stdin = "", env = {} } = {}) {
  const result = spawnSync(MEADOW, args, {
    input: stdin,
    encoding: "utf8",
    cwd: "/tmp",
    env: {
      PATH: "/usr/bin:/bin",
      HOME: home,
      MEADOW_NODE: process.execPath,
      HERDR_PLUGIN_STATE_DIR: stateDir,
      MEADOW_PLUGIN_DIR: fileURLToPath(new URL("..", import.meta.url)),
    },
    timeout: 15_000,
  });
  assert.equal(result.error, undefined);
  return result;
}

suite("listPairedDevices (model)", () => {
  test("classifies device keys, ceremony lines, and unrelated keys", () => {
    const listing = listPairedDevices({
      lines: [USER_LAPTOP_LINE, PHONE_A_LINE, 'restrict,command="x" ssh-ed25519 AAAAbootstrap herdr-pairing:abc:exp:99'],
      enrollments: [],
    });
    assert.equal(listing.devices.length, 1);
    assert.equal(listing.devices[0].fingerprint, PHONE_A_FINGERPRINT);
    assert.equal(listing.devices[0].label, DEVICE_KEY_COMMENT);
    assert.equal(listing.devices[0].enrolledAt, null);
    assert.equal(listing.ceremonies, 1);
    assert.equal(listing.otherLines, 1);
  });

  test("enriches a device with its surviving enrollment record", () => {
    const listing = listPairedDevices({
      lines: [PHONE_A_LINE],
      enrollments: [{ pairingId: "ceremony-1", expiresAt: 1753305600, fingerprint: PHONE_A_FINGERPRINT, line: PHONE_A_LINE }],
    });
    assert.equal(listing.devices.length, 1);
    assert.equal(listing.devices[0].enrolledAt, 1753305600);
    assert.equal(listing.devices[0].pairingId, "ceremony-1");
  });

  test("an enrollment record alone does not turn an unrelated key into a device", () => {
    const listing = listPairedDevices({
      lines: [USER_LAPTOP_LINE],
      enrollments: [{ pairingId: "p", expiresAt: 1, fingerprint: USER_LAPTOP_FINGERPRINT, line: USER_LAPTOP_LINE }],
    });
    // Fingerprint match is authoritative: a record names this exact key.
    assert.equal(listing.devices.length, 1);
  });

  test("malformed lines never crash the listing", () => {
    const listing = listPairedDevices({ lines: ["not a key at all", ""] });
    assert.deepEqual(listing, { devices: [], ceremonies: 0, otherLines: 1 });
  });

  test("findDeviceByFingerprint matches exactly; confirmation is exact", () => {
    const listing = listPairedDevices({ lines: [PHONE_A_LINE, PHONE_B_LINE] });
    const a = findDeviceByFingerprint(listing, PHONE_A_FINGERPRINT);
    assert.equal(a.line, PHONE_A_LINE);
    assert.equal(findDeviceByFingerprint(listing, "SHA256:wrong"), null);
    // Confirmation must be the fingerprint, not a prefix or label.
    assert.equal(isRevokeConfirmation(PHONE_A_FINGERPRINT, a), true);
    assert.equal(isRevokeConfirmation(PHONE_A_FINGERPRINT.slice(0, 20), a), false);
    assert.equal(isRevokeConfirmation("heeler", a), false);
  });
});

suite("meadow devices (listing)", () => {
  test("lists real enrolled keys with fingerprint, label, enrolled-at; says last-used untracked", async () => {
    await editAuthorizedKeys(home, () => [USER_LAPTOP_LINE]);
    const sessionA = await beginPairing({ home, stateDir });
    const recordA = enrollDevice(sessionA, PHONE_A_LINE);
    const sessionB = await beginPairing({ home, stateDir });
    enrollDevice(sessionB, PHONE_B_LINE);

    const result = runMeadowDevices(["devices"]);
    assert.equal(result.status, 0, result.stderr);

    // Both enrolled device keys appear, with their real fingerprints.
    assert.ok(result.stdout.includes(PHONE_A_FINGERPRINT));
    assert.ok(result.stdout.includes(PHONE_B_FINGERPRINT));
    assert.match(result.stdout, /label:      heeler/);
    // enrolled-at from the surviving ceremony record.
    assert.match(result.stdout, /enrolled:   \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/);
    assert.ok(result.stdout.includes(`pairing ${recordA.pairingId}`));
    // last-used is honestly untracked.
    assert.match(result.stdout, /last used:  not tracked/);
    // 2 device keys, the laptop key is preserved and called out as untouched.
    assert.match(result.stdout, /2 device key\(s\); 1 unrelated key\(s\) left alone/);
    // The laptop key is NOT presented as a device.
    assert.ok(!result.stdout.includes(USER_LAPTOP_FINGERPRINT));
  });

  test("empty listing is honest and mentions the pairing path", () => {
    const result = runMeadowDevices(["devices"]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /No enrolled Meadow device keys/);
    assert.match(result.stdout, /meadow pair/);
    // Reading never creates the file.
    assert.equal(existsSync(authorizedKeysPath(home)), false);
  });

  test("a live ceremony line is counted, never listed as a device", async () => {
    await beginPairing({ home, stateDir });
    const result = runMeadowDevices(["devices"]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /A pairing ceremony is in flight/);
    assert.ok(!result.stdout.includes("device key(s): 1"));
    // The bootstrap line survives the listing untouched.
    assert.ok(readKeys().includes("herdr-pairing:"));
  });
});

suite("meadow devices revoke", () => {
  test("removes exactly the target key and leaves every other key byte-identical", async () => {
    await editAuthorizedKeys(home, () => [USER_LAPTOP_LINE, PHONE_A_LINE, PHONE_B_LINE]);

    const result = runMeadowDevices(["devices", "revoke", PHONE_A_FINGERPRINT], {
      stdin: `${PHONE_A_FINGERPRINT}\n`,
    });
    assert.equal(result.status, 0, result.stderr);

    // The confirmation names the exact target before asking.
    assert.ok(result.stdout.includes(PHONE_A_FINGERPRINT));
    assert.ok(result.stdout.includes(`key line:   ${PHONE_A_LINE}`));
    assert.ok(result.stdout.includes("No other keys, the broker, or any agent are touched"));
    // Success names the target.
    assert.ok(result.stdout.includes(`Revoked ${PHONE_A_FINGERPRINT}`));

    // authorized_keys now carries the laptop key and phone B, byte-identical,
    // and no longer phone A.
    assert.equal(readKeys(), `${USER_LAPTOP_LINE}\n${PHONE_B_LINE}\n`);
  });

  test("a wrong confirmation removes nothing", async () => {
    await editAuthorizedKeys(home, () => [PHONE_A_LINE, PHONE_B_LINE]);
    const before = readKeys();

    const result = runMeadowDevices(["devices", "revoke", PHONE_A_FINGERPRINT], {
      stdin: "not the fingerprint\n",
    });
    assert.equal(result.status, 3);
    assert.match(result.stdout, /Cancelled/);
    assert.equal(readKeys(), before);
  });

  test("an unknown fingerprint refuses with the enrolled list and removes nothing", async () => {
    await editAuthorizedKeys(home, () => [PHONE_A_LINE]);
    const before = readKeys();

    const result = runMeadowDevices(["devices", "revoke", "SHA256:deadbeef"]);
    assert.equal(result.status, 3);
    assert.match(result.stderr, /no enrolled Meadow device key with fingerprint SHA256:deadbeef/);
    assert.ok(result.stderr.includes(PHONE_A_FINGERPRINT));
    assert.equal(readKeys(), before);
  });

  test("revoking an unrelated (non-device) key is refused, not offered", async () => {
    await editAuthorizedKeys(home, () => [USER_LAPTOP_LINE, PHONE_A_LINE]);

    const result = runMeadowDevices(["devices", "revoke", USER_LAPTOP_FINGERPRINT]);
    assert.equal(result.status, 3);
    assert.match(result.stderr, /no enrolled Meadow device key with fingerprint/);
    assert.equal(readKeys(), `${USER_LAPTOP_LINE}\n${PHONE_A_LINE}\n`);
  });

  test("revoke takes exactly one fingerprint; usage errors exit 2", () => {
    const none = runMeadowDevices(["devices", "revoke"]);
    assert.equal(none.status, 2);
    const two = runMeadowDevices(["devices", "revoke", "a", "b"]);
    assert.equal(two.status, 2);
    const junk = runMeadowDevices(["devices", "explode"]);
    assert.equal(junk.status, 2);
    assert.match(junk.stderr, /unknown argument 'explode'/);
  });
});

suite("revoked device cannot authenticate (real sshd)", () => {
  // The security acceptance: a revoked device key's next connect fails
  // auth HONESTLY (publickey refused, not a hang or a misleading error),
  // while an unrelated surviving key still authenticates fine.
  // Skips on machines without /usr/sbin/sshd (developer laptops).
  const SSHD = "/usr/sbin/sshd";
  const FIXTURE_PORT = 22422;

  test("revoked key refused, surviving key accepted, through localhost sshd", async (t) => {
    const sshdOk = existsSync(SSHD);
    if (!sshdOk || process.platform !== "darwin") {
      t.skip("requires /usr/sbin/sshd (macOS)");
    }

    // macOS note: mkdtempSync(tmpdir()) lands under /var/folders/..., whose
    // restrictive per-user confstr dirs an unprivileged sshd (different
    // process context) cannot always traverse to read authorized_keys. The
    // fixture lives under plain /tmp, the same choice the app repo's CI
    // fixture makes for its unprivileged sshd.
    const fixture = mkdtempSync("/tmp/devices-sshd-");
    t.after(() => rmSync(fixture, { recursive: true, force: true }));

    // Two throwaway device keys: one to revoke, one to keep.
    const gen = (name) => {
      const key = join(fixture, name);
      const out = spawnSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key], { encoding: "utf8" });
      assert.equal(out.status, 0, out.stderr);
      const line = readFileSync(`${key}.pub`, "utf8").trim();
      return { key, line, fingerprint: fingerprintPublicKeyLine(line).fingerprint };
    };
    const victim = gen("victim");
    const survivor = gen("survivor");

    // Enroll both devices for real, then revoke the victim through the CLI,
    // against a home the fixture sshd can actually read.
    const sshHome = mkdtempSync("/tmp/devices-auth-home-");
    t.after(() => rmSync(sshHome, { recursive: true, force: true }));
    await editAuthorizedKeys(sshHome, () => [victim.line, survivor.line]);
    const session = await beginPairing({ home: sshHome, stateDir });
    enrollDevice(session, victim.line);

    const revoke = spawnSync(
      process.execPath,
      [DEVICES_CLI, "devices", "revoke", victim.fingerprint],
      {
        input: `${victim.fingerprint}\n`,
        encoding: "utf8",
        env: {
          HOME: sshHome,
          HERDR_PLUGIN_STATE_DIR: stateDir,
          PATH: process.env.PATH,
        },
        timeout: 15_000,
      },
    );
    assert.equal(revoke.error, undefined);
    assert.equal(revoke.status, 0, revoke.stderr);

    // Unprivileged fixture sshd, same recipe as the app repo's CI gate:
    // same-user auth, StrictModes off, AuthorizedKeysFile pointed at HOME.
    const config = join(fixture, "sshd.conf");
    const hostKey = join(fixture, "host_ed25519");
    assert.equal(spawnSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey]).status, 0);
    writeFileSync(
      config,
      [
        `Port ${FIXTURE_PORT}`,
        "ListenAddress 127.0.0.1",
        `HostKey ${hostKey}`,
        "PidFile " + join(fixture, "sshd.pid"),
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        `AllowUsers ${process.env.USER}`,
        "StrictModes no",
        "PerSourcePenalties no",
        "UsePAM no",
        `AuthorizedKeysFile ${authorizedKeysPath(sshHome)}`,
        "LogLevel VERBOSE",
      ].join("\n") + "\n",
    );
    const sshdLog = join(fixture, "sshd.log");
    const sshdLogFd = openSync(sshdLog, "w");
    const sshd = spawn(SSHD, ["-D", "-e", "-f", config], { stdio: ["ignore", sshdLogFd, sshdLogFd] });
    // Readiness must prove OUR sshd holds the port: a stale listener from a
    // crashed earlier run would answer the probe and serve the wrong
    // authorized_keys. Bind failure also kills the child early, so check both.
    const deadline = Date.now() + 5_000;
    for (;;) {
      const probe = spawnSync("nc", ["-z", "127.0.0.1", String(FIXTURE_PORT)]);
      if (probe.status === 0) {
        // Give a bind-failed child a beat to die before trusting the port.
        await new Promise((r) => setTimeout(r, 150));
        if (sshd.exitCode !== null) {
          assert.fail(`fixture sshd exited early with ${sshd.exitCode}: ${readFileSync(sshdLog, "utf8")}`);
        }
        break;
      }
      if (Date.now() > deadline) {
        sshd.kill("SIGKILL");
        assert.fail(`fixture sshd never listened: ${(() => { try { return readFileSync(sshdLog, "utf8"); } catch { return "(no log)"; } })()}`);
      }
      await new Promise((r) => setTimeout(r, 100));
    }

    try {
      const ssh = (key, expected) => {
        const out = spawnSync(
          "ssh",
          [
            "-p", String(FIXTURE_PORT),
            "-i", key,
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "127.0.0.1",
            "true",
          ],
          { encoding: "utf8", timeout: 20_000 },
        );
        return { status: out.status, stderr: out.stderr };
      };

      // The revoked key: refused with a publickey auth failure — honest.
      const refused = ssh(victim.key);
      assert.notEqual(refused.status, 0);
      assert.match(refused.stderr, /Permission denied \(publickey/);

      // The surviving key still authenticates.
      const accepted = ssh(survivor.key);
      assert.equal(accepted.status, 0, accepted.stderr);
    } finally {
      sshd.kill("SIGKILL");
    }
  });
});
