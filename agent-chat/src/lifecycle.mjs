// Host-side agent lifecycle coordinator (Meadow v3 design, section
// "Verified primitives and proposed lifecycle operations").
//
// ONE coordinator owns lifecycle mutations for one herdr session socket;
// the single-writer guard covers the WHOLE HOST SECURITY DOMAIN across
// herdr sessions AND across host-package processes:
//   - in-process: an async mutex per hostLabel (this process);
//   - interprocess: an exclusive-create lock file under the Meadow state
//     root (`lifecycle/<hostHash>/mutation.lock`), same model as the
//     consolidation's broker owner socket — the filesystem is the
//     arbiter, so two host-package processes cannot both mutate.
// A per-host persisted registry (`conversations.json`) carries records and
// completed requestKey envelopes across processes, and cross-session
// occupancy is DISCOVERED by probing the recorded session's herdr socket,
// never guessed from memory. Clients never race multi-step sequences
// against herdr themselves.
//
// herdr surface this module is built on — VERIFIED, never assumed:
//   - `herdr api schema --json` on herdr 0.9.1 (protocol 22) lists
//     agent.start, agent.list, agent.get, pane.get, pane.split, pane.close,
//     pane.process_info, tab.create, tab.close. It has NO first-class
//     agent.stop and NO agent.resume (verified 2026-09-23). Do not
//     fabricate them; stop/resume are declared unsupported until herdr
//     grows them or an adapter verifies a per-kind mechanism.
//   - Live probes on 0.9.1 additionally pinned: the API socket serves one
//     request per connection; `tab.create` returns a correlated
//     {tab, root_pane} identity; `agent.start` on a fresh tab pane can
//     answer `agent_pane_busy` until the pane's shell reaches its prompt
//     (the AGENTS.md 0.8.0 "async only" note does NOT hold on 0.9.1
//     fresh panes) and then returns {type:'agent_started', agent:{...,
//     launch_pending}} whose agent identity is authoritative;
//     `pane.close` answers {type:'ok'}; `agent.get` on a closed pane
//     answers `agent_not_found`.
//
// Honesty rules encoded here (all from the design):
//   - start/status/forceClose are supported (verified primitives);
//     stop/resume are declared UNSUPPORTED with the reason, and the
//     explicitly destructive pane close is a SEPARATE operation
//     (lifecycle.forceClose), never masquerading as graceful stop.
//   - Repeated delivery of one requestKey replays the recorded envelope
//     and must not create extra tabs/panes. The ledger is consulted BEFORE
//     any mutable lookup, and completed envelopes persist in the host
//     registry so a replay from another process still replays.
//   - An already-running conversation is refused; occupancy that cannot
//     be inspected — unreachable herdr, a malformed agent.list result, an
//     unreadable host registry — is a REFUSAL, never permission.
//   - Destructive close re-resolves the pane from the recorded stable
//     terminal identity immediately before dispatch and refuses on
//     mismatch. herdr 0.9.1 has no atomic expected-identity close, so the
//     envelope states the guard that WAS applied instead of simulating
//     safety by comparing ids only in the client.
//
// The lifecycle envelope is host-package surface; it is deliberately NOT
// part of the agent-chat v1 broker wire (protocol.mjs is untouched).
// The client UI that drives these operations is a follow-up slice.

import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

export const LIFECYCLE_ENVELOPE = 'agent-chat.lifecycle.v1';

/** herdr protocol this coordinator's semantics were verified against. */
export const MIN_HERDR_PROTOCOL = 22;

export const HERDR_EVIDENCE =
  'herdr 0.9.1, protocol 22; verified via `herdr api schema --json` and live socket probes on 2026-09-23';

/** Kinds `herdr agent start --kind` accepts (verified: its --help on 0.9.1). */
export const HERDR_START_KINDS = Object.freeze([
  'pi', 'claude', 'codex', 'gemini', 'cursor', 'devin', 'agy', 'cline', 'omp',
  'mastracode', 'opencode', 'copilot', 'kimi', 'kiro', 'droid', 'amp', 'grok',
  'hermes', 'kilo', 'qodercli', 'qwen', 'letta', 'maki', 'muse',
]);

export const LIFECYCLE_OPS = Object.freeze([
  'lifecycle.start',
  'lifecycle.stop',
  'lifecycle.resume',
  'lifecycle.status',
  'lifecycle.forceClose',
]);

export const LIFECYCLE_OUTCOMES = Object.freeze(['completed', 'refused', 'unsupported']);

export const REFUSAL_CODES = Object.freeze([
  'invalid_params',
  'unknown_kind',
  'already_running',
  'occupancy_unknown',
  'lock_timeout',
  'lock_failed',
  'target_gone',
  'identity_mismatch',
  'inspection_failed',
  'not_managed',
  'herdr_rejected',
  'start_failed',
  'internal_error',
]);

// ---------------------------------------------------------------------------
// Capability manifest — VERIFIED per-kind lifecycle semantics.
//
// Every kind currently shares the same herdr-verified surface; the table is
// still per-kind so a future adapter-verified mechanism (e.g. a verified
// idle-only exit command, or a native resume flag) can diverge one kind
// without touching the others. `declaredLifecycleCapabilities` returns null
// for unknown kinds — never a fabricated entry.

const NO_AGENT_STOP =
  'herdr 0.9.1 (protocol 22) has no first-class agent.stop and no verified ' +
  'idle-only exit command; Ctrl+C is not assumed to mean graceful exit ' +
  '(in a TUI it may only interrupt a turn)';

const NO_AGENT_RESUME =
  'herdr 0.9.1 (protocol 22) has no first-class agent.resume; resume must ' +
  'target the exact durable conversation from the adapter catalog, never a ' +
  '"latest file" heuristic';

export function declaredLifecycleCapabilities(kind) {
  if (typeof kind !== 'string' || !HERDR_START_KINDS.includes(kind)) return null;
  return Object.freeze({
    kind,
    start: Object.freeze({
      supported: true,
      evidence: 'herdr agent.start returns a correlated agent_started identity (verified live)',
    }),
    stop: Object.freeze({
      supported: false,
      reason: NO_AGENT_STOP,
      destructiveAlternative: 'lifecycle.forceClose',
    }),
    resume: Object.freeze({ supported: false, reason: NO_AGENT_RESUME }),
    status: Object.freeze({
      supported: true,
      evidence: 'herdr agent.list + pane.get + pane.process_info (schema + live probes)',
    }),
    forceClose: Object.freeze({
      supported: true,
      destructive: true,
      evidence: 'herdr pane.close (verified live: {type:"ok"})',
    }),
  });
}

// ---------------------------------------------------------------------------
// Conversation identity.
//
// The coordinator names every agent it starts deterministically from the
// conversation key, matching herdr's agent-name rule ^[a-z][a-z0-9_-]{0,31}$
// (verified live via agent.rename on 0.7.5 and exercised via agent.start on
// 0.9.1). The deterministic name is the occupancy marker: a second start of
// the same conversation — from any process or herdr session on this host —
// is detectable via agent.list against the recorded session.

export function agentNameFor(conversationKey) {
  if (typeof conversationKey !== 'string' || conversationKey.length === 0) {
    throw new TypeError('conversationKey must be a non-empty string');
  }
  const digest = crypto.createHash('sha256').update(conversationKey, 'utf8').digest('hex').slice(0, 12);
  return `mdc-${digest}`;
}

// ---------------------------------------------------------------------------
// herdr API client. One request per connection (verified: the socket serves
// one request per connection; a second write on a served connection EPIPEs).
// Parse leniently — herdr adds fields; never trust shapes beyond what the
// op needs, and never mutate on a parse that did not happen.

const DEFAULT_RPC_TIMEOUT_MS = 15_000;
const MAX_RESPONSE_BYTES = 1024 * 1024;

function rpcFail(code, message) {
  return { ok: false, error: { code, message } };
}

export class HerdrApi {
  constructor(opts = {}) {
    if (typeof opts.socketPath !== 'string' || opts.socketPath === '') {
      throw new TypeError('socketPath is required');
    }
    this.socketPath = opts.socketPath;
    this.requestTimeoutMs = positiveInt(opts.requestTimeoutMs, DEFAULT_RPC_TIMEOUT_MS);
    this.connect = typeof opts.connect === 'function' ? opts.connect : (p) => net.createConnection(p);
  }

  /**
   * One NDJSON request/response over a fresh connection.
   * Resolves {ok:true, result} | {ok:false, error:{code,message}}; never rejects.
   */
  rpc(method, params = {}) {
    if (typeof method !== 'string' || method === '') return Promise.resolve(rpcFail('invalid_request', 'method is required'));
    if (params === null || typeof params !== 'object' || Array.isArray(params)) {
      return Promise.resolve(rpcFail('invalid_request', 'params must be an object'));
    }
    let sock;
    try {
      sock = this.connect(this.socketPath);
    } catch (err) {
      return Promise.resolve(rpcFail('connect_failed', err.message));
    }
    return new Promise((resolve) => {
      let settled = false;
      let buf = '';
      const finish = (v) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        sock.destroy();
        resolve(v);
      };
      const timer = setTimeout(
        () => finish(rpcFail('timeout', `herdr rpc ${method} timed out after ${this.requestTimeoutMs}ms`)),
        this.requestTimeoutMs,
      );
      sock.on('error', (err) =>
        finish(rpcFail(err && err.code === 'ENOENT' ? 'socket_missing' : 'connect_failed', (err && err.message) || 'socket error')),
      );
      sock.on('connect', () => {
        try {
          sock.write(JSON.stringify({ id: 'meadow-lifecycle', method, params }) + '\n');
        } catch (err) {
          finish(rpcFail('connect_failed', err.message));
        }
      });
      sock.on('data', (chunk) => {
        if (settled) return;
        buf += chunk.toString('utf8');
        const nl = buf.indexOf('\n');
        if (nl < 0) {
          if (buf.length > MAX_RESPONSE_BYTES) finish(rpcFail('bad_frame', 'herdr response exceeds 1 MiB'));
          return;
        }
        const line = buf.slice(0, nl);
        let frame;
        try {
          frame = JSON.parse(line);
        } catch {
          return finish(rpcFail('bad_frame', 'undecodable herdr response line'));
        }
        // One request per connection: the first frame settles this rpc.
        if (frame && typeof frame === 'object' && frame.error) {
          const e = frame.error;
          return finish(rpcFail(typeof e.code === 'string' && e.code ? e.code : 'herdr_error', typeof e.message === 'string' ? e.message : ''));
        }
        return finish({ ok: true, result: frame && typeof frame === 'object' ? frame.result : undefined });
      });
    });
  }

  ping() { return this.rpc('ping', {}); }
  agentList() { return this.rpc('agent.list', {}); }
  agentGet(target) { return this.rpc('agent.get', { target }); }
  paneGet(paneId) { return this.rpc('pane.get', { pane_id: paneId }); }
  paneProcessInfo(paneId) { return this.rpc('pane.process_info', { pane_id: paneId }); }
  tabCreate(params) { return this.rpc('tab.create', params); }
  agentStart(params) { return this.rpc('agent.start', params); }
  paneClose(paneId) { return this.rpc('pane.close', { pane_id: paneId }); }
  tabClose(tabId) { return this.rpc('tab.close', { tab_id: tabId }); }
}

/**
 * VALIDATED agent.list occupancy. A successful herdr reply that does not
 * carry a well-formed agents array is NOT "no agents" — it is unknown
 * occupancy, and unknown occupancy is a refusal, never permission.
 * Returns {ok:true, agents:[...]} (each entry a plain object) or
 * {ok:false, reason}.
 */
function validatedAgentList(result) {
  if (result === null || typeof result !== 'object' || Array.isArray(result)) {
    return { ok: false, reason: 'agent.list result was not an object (wire drift)' };
  }
  if (!Array.isArray(result.agents)) {
    return { ok: false, reason: 'agent.list result carried no agents array (wire drift)' };
  }
  for (const a of result.agents) {
    if (a === null || typeof a !== 'object' || Array.isArray(a)) {
      return { ok: false, reason: 'agent.list agents array contained a non-object entry (wire drift)' };
    }
    // AgentInfo.name is OPTIONAL (string|null) on protocol 22 — the live
    // server omits it for unnamed agents. Absent = unnamed = valid; only a
    // PRESENT name of a non-string non-null type cannot be matched for
    // occupancy, which makes the whole inspection untrustworthy.
    if (a.name !== undefined && a.name !== null && typeof a.name !== 'string') {
      return { ok: false, reason: 'agent.list carried an entry whose name is neither string nor null (wire drift)' };
    }
  }
  return { ok: true, agents: result.agents };
}

// ---------------------------------------------------------------------------
// Interprocess whole-host mutation lock — a BOUND UNIX SOCKET.
//
// The lock is not a file with an age heuristic; it is a socket bound by the
// holder (the consolidation's broker owner-socket mechanism, which is
// kernel-enforced mutual exclusion, not a timeout guess):
//   - BIND is the atomic acquire: exactly one process can ever bind the
//     path; every other contender gets EADDRINUSE. There is no takeover
//     while the holder lives — the kernel releases the name only when
//     the holder's socket closes (explicit release, or process death:
//     the kernel reaps its fds). A live-but-slow holder can never be
//     robbed, however long it holds.
//   - LIVENESS is proved by connect probes, which the KERNEL answers even
//     while the holder's event loop is blocked: if anything accepts, the
//     holder is alive and the contender keeps waiting until its budget
//     expires (then refuses lock_timeout — it never steals).
//   - CRASH RECOVERY is kernel-side and instant: a dead holder's bound
//     name disappears with its fds; the next contender's bind succeeds.
//     A stale PATH (holder crashed leaving the file) is removed only
//     after a connect probe proves nothing answers, and a bind race on
//     the removed name is settled by EADDRINUSE — still atomic.
//
// The lock is held only for the duration of one mutation, never for a
// coordinator's lifetime.

const LOCK_PROBE_TIMEOUT_MS = 500;
const LOCK_RETRY_DELAY_MS = 50;

// AF_UNIX sun_path is 104 bytes on macOS, 108 on Linux. A lock path longer
// than the platform limit cannot be bound at all (listen EINVAL), so when
// the state dir is too deep the lock falls back to a deterministic SHORT
// path in the OS tmpdir: the name is a hash of the full intended path, so
// every process derives the same lock for the same host domain. The tmpdir
// is user-scoped on macOS (/var/folders/<user>/T) and sticky /tmp on Linux
// — the same-UID discipline the broker's socket hygiene relies on.
const LOCK_PATH_MAX = process.platform === 'darwin' ? 104 : 108;

function resolveLockPath(intended) {
  if (Buffer.byteLength(intended, 'utf8') <= LOCK_PATH_MAX - 1) return intended;
  const hash = crypto.createHash('sha256').update(intended, 'utf8').digest('hex').slice(0, 24);
  return path.join(os.tmpdir(), `mdc-lock-${hash}.sock`);
}

export class InterprocessLock {
  constructor(lockPath, opts = {}) {
    this.lockPath = lockPath;
    this.timeoutMs = positiveInt(opts.timeoutMs, 15_000);
    this.token = `${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
    this.server = null; // the bound listening socket WHILE we hold the lock
  }

  /** Is anything alive at the lock path? A connect probe the KERNEL answers
   *  even if the holder's JS event loop is blocked. */
  async #probeAlive() {
    return new Promise((resolve) => {
      const sock = net.connect(this.lockPath);
      let done = false;
      const finish = (alive) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        sock.destroy();
        resolve(alive);
      };
      const timer = setTimeout(() => finish(false), LOCK_PROBE_TIMEOUT_MS);
      sock.on('error', () => finish(false)); // ENOENT/ECONNREFUSED: no live holder
      sock.on('connect', () => finish(true)); // the live holder accepts (probe connection)
    });
  }

  async acquire() {
    const deadline = Date.now() + this.timeoutMs;
    fs.mkdirSync(path.dirname(this.lockPath), { recursive: true });
    for (;;) {
      // Atomic acquire attempt: binding is exclusive by kernel guarantee.
      const bound = await this.#tryBind();
      if (bound === true) return true;
      if (bound === 'EADDRINUSE') {
        // someone holds the name: fall through to the liveness probe
      } else if (typeof bound === 'string') {
        return { error: bound }; // fatal bind failure (permissions, bad path, ...)
      }
      // EADDRINUSE: someone holds the name. Prove whether it is ALIVE
      // (kernel answers regardless of the holder's event-loop state) —
      // a live holder is NEVER stolen from; a dead one's leftover path is
      // cleaned and retried, with the bind race still atomic.
      const alive = await this.#probeAlive();
      if (alive) {
        if (Date.now() >= deadline) {
          return { error: `a live host-package process holds ${this.lockPath}; timed out after ${this.timeoutMs}ms (the lock is never stolen from a live holder)` };
        }
        await sleep(LOCK_RETRY_DELAY_MS);
        continue;
      }
      // Nothing answers: the path is a leftover from a dead holder. Remove
      // ONLY the stale socket file (lstat: never follow symlinks), then
      // retry the bind; if a contender raced us to the name meanwhile, its
      // EADDRINUSE still decides atomically.
      try {
        const st = fs.lstatSync(this.lockPath);
        if ((st.mode & 0o170000) === 0o140000) fs.rmSync(this.lockPath, { force: true });
      } catch {} // vanished already
    }
  }

  /** Bind the lock path. true = acquired; 'EADDRINUSE' = held; string = fatal. */
  #tryBind() {
    return new Promise((resolve) => {
      const srv = net.createServer(() => {}); // accept (probe connections) and drop them
      srv.once('error', (err) => {
        srv.close();
        if (err.code === 'EADDRINUSE') return resolve('EADDRINUSE');
        resolve(`cannot bind lock socket ${this.lockPath}: ${err.message}`);
      });
      srv.listen(this.lockPath, () => {
        this.server = srv;
        resolve(true);
      });
    });
  }

  release() {
    // Closing the bound socket releases the name atomically; unlinking the
    // file afterwards removes the leftover path so the next contender's
    // bind does not depend on the probe path. If we no longer hold it
    // (impossible with bind semantics, but defensive), remove nothing.
    const srv = this.server;
    this.server = null;
    if (!srv) return;
    srv.close(() => {
      try {
        fs.rmSync(this.lockPath, { force: true });
      } catch {}
    });
  }
}

/** Run `fn` while holding the whole-host interprocess mutation lock. */
async function withHostLock(lock, fn) {
  const acquired = await lock.acquire();
  if (acquired !== true) return { __lockError: acquired.error };
  try {
    return await fn();
  } finally {
    lock.release();
  }
}

// ---------------------------------------------------------------------------
// Persisted host registry: conversation records + completed requestKey
// envelopes, shared by every host-package process on the host. Reads are
// validated — a corrupt registry is UNKNOWN OCCUPANCY, and unknown occupancy
// is a refusal, never permission. Writes are atomic (tmp + rename) and only
// happen under the interprocess mutation lock.

const REGISTRY_MAX_REQUESTS = 256; // completed envelopes kept, oldest dropped

function hostStateDir(stateRoot, hostLabel) {
  const hash = crypto.createHash('sha256').update(hostLabel, 'utf8').digest('hex').slice(0, 16);
  return path.join(stateRoot, 'lifecycle', hash);
}

function isPlain(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function isStr(v, max = 512) {
  return typeof v === 'string' && v.length > 0 && v.length <= max;
}

function validRegistryRecord(r) {
  return (
    isPlain(r) &&
    isStr(r.conversationKey) &&
    isStr(r.name) &&
    isStr(r.paneId) &&
    isStr(r.terminalId) &&
    isStr(r.session)
  );
}

function readRegistryJson(file, what) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return { ok: true, value: null };
    return { ok: false, reason: `cannot read the host ${what} (${err.code})` };
  }
  if (raw.trim() === '') return { ok: true, value: null };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, reason: `the host ${what} is not valid JSON (corrupt state)` };
  }
  return { ok: true, value: parsed };
}

function readConversations(stateDir) {
  const r = readRegistryJson(path.join(stateDir, 'conversations.json'), 'conversation registry');
  if (!r.ok) return r;
  if (r.value === null) return { ok: true, conversations: new Map() };
  if (!Array.isArray(r.value)) {
    return { ok: false, reason: 'the host conversation registry is not an array (corrupt state)' };
  }
  const map = new Map();
  for (const rec of r.value) {
    if (!validRegistryRecord(rec)) {
      return { ok: false, reason: 'the host conversation registry carries a malformed record (corrupt state)' };
    }
    map.set(rec.conversationKey, rec);
  }
  return { ok: true, conversations: map };
}

function writeConversations(stateDir, map) {
  const file = path.join(stateDir, 'conversations.json');
  const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify([...map.values()]) + '\n');
  fs.renameSync(tmp, file);
}

function readRequests(stateDir) {
  const r = readRegistryJson(path.join(stateDir, 'requests.json'), 'request ledger');
  if (!r.ok) return r;
  if (r.value === null) return { ok: true, requests: [] };
  if (!Array.isArray(r.value)) {
    return { ok: false, reason: 'the host request ledger is not an array (corrupt state)' };
  }
  for (const e of r.value) {
    if (!isPlain(e) || !isStr(e.requestKey) || !isPlain(e.envelope)) {
      return { ok: false, reason: 'the host request ledger carries a malformed entry (corrupt state)' };
    }
  }
  return { ok: true, requests: r.value };
}

function writeRequests(stateDir, requests) {
  const file = path.join(stateDir, 'requests.json');
  const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(requests.slice(-REGISTRY_MAX_REQUESTS)) + '\n');
  fs.renameSync(tmp, file);
}

// ---------------------------------------------------------------------------
// Host domain (in-process half): per-hostLabel mutex + per-conversation
// locks + the in-memory requestKey ledger. The cross-process half lives in
// the persisted registry; the two are bridged in the coordinator.

class AsyncMutex {
  #tail = Promise.resolve();
  runExclusive(fn) {
    const job = this.#tail.then(() => fn());
    this.#tail = job.then(
      () => {},
      () => {},
    );
    return job;
  }
}

const hostDomains = new Map(); // hostLabel -> domain

function domainFor(hostLabel) {
  let d = hostDomains.get(hostLabel);
  if (!d) {
    hostDomains.set(hostLabel, (d = {
      guard: new AsyncMutex(),
      conversationLocks: new Map(), // conversationKey -> AsyncMutex
      requests: new Map(), // requestKey -> {state:'in_flight',promise} | {state:'completed',envelope}
    }));
  }
  return d;
}

function conversationLock(domain, conversationKey) {
  let lock = domain.conversationLocks.get(conversationKey);
  if (!lock) domain.conversationLocks.set(conversationKey, (lock = new AsyncMutex()));
  return lock;
}

// ---------------------------------------------------------------------------
// Envelope helpers.

function isoNow() {
  return new Date().toISOString();
}

function envelope(op, requestKey, outcome, fields) {
  return {
    envelope: LIFECYCLE_ENVELOPE,
    op,
    ...(requestKey !== undefined && { requestKey }),
    outcome,
    ...fields,
  };
}

function refused(op, requestKey, code, message, extra = {}) {
  return envelope(op, requestKey, 'refused', { code, reason: message, ...extra });
}

function unsupported(op, requestKey, reason, extra = {}) {
  return envelope(op, requestKey, 'unsupported', { reason, ...extra });
}

function positiveInt(v, dflt) {
  return Number.isInteger(v) && v > 0 ? v : dflt;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function recordIdentity(rec) {
  if (!rec) return undefined;
  return {
    conversationKey: rec.conversationKey,
    kind: rec.kind,
    name: rec.name,
    paneId: rec.paneId,
    terminalId: rec.terminalId,
    tabId: rec.tabId,
    session: rec.session,
    startedAt: rec.startedAt,
    ...(rec.adopted !== undefined && { adopted: rec.adopted }),
  };
}

// ---------------------------------------------------------------------------
// The coordinator.

export class LifecycleCoordinator {
  /**
   * @param {object} opts
   * @param {HerdrApi} opts.herdr  one herdr session socket
   * @param {string} [opts.hostLabel]  the host security domain shared by all
   *   herdr sessions on that host; coordinators with the same label share the
   *   single-writer guard, conversation registry and requestKey ledger —
   *   in this process AND, via the persisted registry + lock file, across
   *   every host-package process on the host.
   * @param {string} [opts.stateRoot]  Meadow state root for the interprocess
   *   lock and persisted registry (default: XDG_STATE_HOME/meadow).
   * @param {number} [opts.startShellWaitMs]  agent_pane_busy retry budget
   * @param {number} [opts.busyRetryDelayMs]  delay between retries
   * @param {number} [opts.lockTimeoutMs]  interprocess lock acquisition
   *   budget; on expiry the mutation refuses lock_timeout — the lock is
   *   never stolen from a live holder, so this is a queue wait, not a
   *   safety valve.
   */
  constructor(opts = {}) {
    if (!opts.herdr || typeof opts.herdr.rpc !== 'function') {
      throw new TypeError('herdr (HerdrApi) is required');
    }
    this.herdr = opts.herdr;
    this.hostLabel = isStr(opts.hostLabel, 256) ? opts.hostLabel : 'localhost';
    this.domain = domainFor(this.hostLabel);
    this.stateRoot = isStr(opts.stateRoot, 4096)
      ? opts.stateRoot
      : path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), '.local', 'state'), 'meadow');
    this.stateDir = hostStateDir(this.stateRoot, this.hostLabel);
    this.startShellWaitMs = positiveInt(opts.startShellWaitMs, 10_000);
    this.busyRetryDelayMs = positiveInt(opts.busyRetryDelayMs, 250);
    this.lock = new InterprocessLock(resolveLockPath(path.join(this.stateDir, 'mutation.lock')), {
      timeoutMs: positiveInt(opts.lockTimeoutMs, 15_000),
    });
    this.log = typeof opts.log === 'function' ? opts.log : null;
    this.#server = null; // cached ping result once a compatible server answered
  }

  #server;

  #wire(event, fields) {
    if (!this.log) return;
    try {
      this.log({ ts: isoNow(), event, ...fields });
    } catch {}
  }

  // --- ledger (cross-process requestKey idempotency) -------------------------

  /**
   * SYNCHRONOUS requestKey ledger claim — runs BEFORE any await, so two
   * concurrent deliveries of one requestKey in this process can never both
   * pass: the first claims the in-memory slot, the second finds it. Also
   * consults the persisted host registry (another process's completed
   * deliveries). Returns:
   *   {replay} — a duplicate delivery; await the replayed envelope
   *   {slot}   — this delivery owns the requestKey; set slot.promise
   *   {refusal} — the ledger is corrupt; idempotency is unverifiable, and
   *              unknown idempotency state must not become a mutation
   */
  #claimLedger(op, requestKey) {
    if (requestKey === undefined) return {};
    const prior = this.domain.requests.get(requestKey);
    if (prior) {
      if (prior.state === 'completed') return { replay: Promise.resolve({ ...prior.envelope, replayed: true }) };
      return { replay: prior.promise.then((env) => ({ ...env, replayed: true })) };
    }
    const persisted = readRequests(this.stateDir);
    if (!persisted.ok) {
      return {
        refusal: refused(op, requestKey, 'occupancy_unknown',
          `cannot verify requestKey delivery (${persisted.reason}); refusing rather than risk a duplicate mutation`),
      };
    }
    const hit = persisted.requests.find((e) => e.requestKey === requestKey);
    if (hit) return { replay: Promise.resolve({ ...hit.envelope, replayed: true }) };
    const slot = { state: 'in_flight', promise: null };
    this.domain.requests.set(requestKey, slot);
    return { slot };
  }

  /** Complete an in-process slot (the persisted copy was written under the lock). */
  #settleSlot(requestKey, slot, promise) {
    if (requestKey === undefined || !slot) return;
    slot.promise = promise;
    promise.then(
      (env) => this.domain.requests.set(requestKey, { state: 'completed', envelope: env }),
      () => this.domain.requests.delete(requestKey), // an internal throw: the key may be retried
    );
  }

  // --- start ---------------------------------------------------------------

  /**
   * Start the exact conversation `conversationKey` as agent `kind` in `cwd`.
   * Idempotent per requestKey: repeated delivery replays the recorded
   * envelope and never creates extra tabs/panes. Refuses when the
   * conversation is already running (discovered via the persisted host
   * registry + live probes of the recorded session) or occupancy cannot be
   * inspected.
   */
  async start(params = {}) {
    const v = validateStartParams(params);
    if (!v.ok) return refused('lifecycle.start', params.requestKey, v.code, v.message);
    const { conversationKey, kind, cwd, label, focus, requestKey } = v.value;
    const caps = declaredLifecycleCapabilities(kind);
    if (!caps) {
      return refused('lifecycle.start', requestKey, 'unknown_kind', `kind '${kind}' is not in herdr 0.9.1's supported agent.start kinds`);
    }
    if (!caps.start.supported) {
      return unsupported('lifecycle.start', requestKey, caps.start.reason);
    }

    // Ledger FIRST — a SYNCHRONOUS claim before any mutable lookup, so
    // concurrent duplicate delivery of one requestKey cannot double-run.
    const claim = this.#claimLedger('lifecycle.start', requestKey);
    if (claim.refusal) return claim.refusal;
    if (claim.replay) return claim.replay;

    const domain = this.domain;
    const promise = this.#guarded('lifecycle.start', requestKey, (key) =>
      conversationLock(domain, conversationKey).runExclusive(() => this.#startLocked(key, v.value)),
    );
    this.#settleSlot(requestKey, claim.slot, promise);
    let env;
    try {
      env = await promise;
    } catch (err) {
      env = refused('lifecycle.start', requestKey, 'internal_error', `unexpected internal failure: ${err && err.message}`);
      if (requestKey !== undefined) this.domain.requests.set(requestKey, { state: 'completed', envelope: env });
    }
    return env;
  }

  async #startLocked(requestKey, { conversationKey, kind, cwd, label, focus }) {
    // 1. Server gate: a protocol-older server has none of the verified
    //    semantics; say unsupported rather than attempt them.
    const gate = await this.#serverGate('lifecycle.start', requestKey);
    if (gate) return gate;

    const name = agentNameFor(conversationKey);

    // 2. Registry read — whole-host occupancy, cross-process and
    //    cross-session. Corrupt/unreadable registry = unknown occupancy.
    const reg = readConversations(this.stateDir);
    if (!reg.ok) {
      return refused('lifecycle.start', requestKey, 'occupancy_unknown', `${reg.reason}; unknown occupancy is a refusal`);
    }
    const conversations = reg.conversations;
    let record = conversations.get(conversationKey) || null;

    // 3. Cross-session occupancy DISCOVERY: a record on another session's
    //    socket is probed on that socket — verified alive = already_running;
    //    verified gone = stale, cleared; unreachable = unverifiable = refusal.
    if (record && record.session !== this.herdr.socketPath) {
      const probeApi = new HerdrApi({ socketPath: record.session, requestTimeoutMs: Math.min(this.herdr.requestTimeoutMs, 5000) });
      const probe = await probeApi.agentList();
      if (!probe.ok) {
        return refused('lifecycle.start', requestKey, 'already_running',
          `conversation is recorded as started on herdr session ${record.session}, which cannot be reached to verify it stopped ` +
            `(${probe.error.code}); unverifiable occupancy is a refusal`,
          { existing: recordIdentity(record) });
      }
      const validated = validatedAgentList(probe.result);
      if (!validated.ok) {
        return refused('lifecycle.start', requestKey, 'already_running',
          `conversation is recorded as started on herdr session ${record.session}, whose occupancy reply was malformed ` +
            `(${validated.reason}); unverifiable occupancy is a refusal`,
          { existing: recordIdentity(record) });
      }
      const live = validated.agents.find((a) => a.name === record.name);
      if (live) {
        return refused('lifecycle.start', requestKey, 'already_running',
          `an agent for this conversation identity is live on herdr session ${record.session} (verified by probing it)`,
          { existing: recordIdentity(record) });
      }
      // Recorded agent is gone from its session: stale, clear it.
      conversations.delete(conversationKey);
      record = null;
    }

    // 4. Same-session occupancy inspection BEFORE creating anything.
    const list = await this.herdr.agentList();
    if (!list.ok) {
      return refused('lifecycle.start', requestKey, 'occupancy_unknown',
        `cannot inspect registered processes (agent.list: ${list.error.code}: ${list.error.message}); unknown occupancy is a refusal`);
    }
    const sameSession = validatedAgentList(list.result);
    if (!sameSession.ok) {
      // A malformed occupancy reply is NOT "no agents" — refuse.
      return refused('lifecycle.start', requestKey, 'occupancy_unknown',
        `cannot trust the occupancy inspection (${sameSession.reason}); unknown occupancy is a refusal`);
    }
    const live = sameSession.agents.find((a) => a.name === name);
    if (live) {
      // Adopt the live identity so later ops (status/forceClose) target it.
      const adopted = recordFromAgent(conversationKey, live, this.herdr.socketPath, { adopted: true });
      conversations.set(conversationKey, adopted);
      writeConversations(this.stateDir, conversations);
      return refused('lifecycle.start', requestKey, 'already_running',
        'an agent for this conversation identity is already registered in this herdr session',
        { existing: recordIdentity(adopted) });
    }
    if (record) conversations.delete(conversationKey); // recorded agent is gone from this session: stale

    // 5. Create the destination tab and start the agent in it.
    const tab = await this.herdr.tabCreate({
      cwd,
      ...(label !== undefined && { label }),
      ...(focus !== undefined && { focus }),
    });
    if (!tab.ok) {
      return refused('lifecycle.start', requestKey, 'herdr_rejected', `tab.create failed (${tab.error.code}): ${tab.error.message}`);
    }
    const tabInfo = tab.result && tab.result.tab;
    const rootPane = tab.result && tab.result.root_pane;
    if (!tabInfo || typeof tabInfo.tab_id !== 'string' || !rootPane || typeof rootPane.pane_id !== 'string') {
      return refused('lifecycle.start', requestKey, 'herdr_rejected',
        'tab.create result lacked the correlated {tab,root_pane} identity (wire drift); refusing without a start');
    }
    this.#wire('lifecycle.tab_created', { tabId: tabInfo.tab_id, paneId: rootPane.pane_id });

    // 6. agent.start: a fresh pane can answer agent_pane_busy until its
    //    shell reaches the prompt (verified live on 0.9.1) — bounded retry.
    const deadline = Date.now() + this.startShellWaitMs;
    for (;;) {
      const st = await this.herdr.agentStart({ name, kind, pane_id: rootPane.pane_id, timeout_ms: 30_000 });
      if (st.ok) {
        const agent = st.result && st.result.agent;
        if (!agent || typeof agent.pane_id !== 'string' || typeof agent.terminal_id !== 'string') {
          const cleanup = await this.#cleanupTab(tabInfo.tab_id);
          return refused('lifecycle.start', requestKey, 'herdr_rejected',
            'agent_started result lacked the correlated agent identity (pane_id/terminal_id); the created tab was closed',
            { cleanup });
        }
        const rec = {
          conversationKey,
          kind,
          name,
          paneId: agent.pane_id, // authoritative (may differ from the requested pane)
          terminalId: agent.terminal_id,
          tabId: typeof agent.tab_id === 'string' ? agent.tab_id : tabInfo.tab_id,
          session: this.herdr.socketPath,
          startedAt: isoNow(),
          launchPending: !!agent.launch_pending,
        };
        conversations.set(conversationKey, rec);
        writeConversations(this.stateDir, conversations);
        this.#wire('lifecycle.started', { conversationKey, paneId: rec.paneId, terminalId: rec.terminalId });
        return envelope('lifecycle.start', requestKey, 'completed', {
          result: {
            conversation: recordIdentity(rec),
            launchPending: rec.launchPending,
            ...(Array.isArray(st.result.argv) && { argv: st.result.argv }),
          },
        });
      }
      if (st.error.code !== 'agent_pane_busy') {
        const cleanup = await this.#cleanupTab(tabInfo.tab_id);
        return refused('lifecycle.start', requestKey, 'herdr_rejected',
          `agent.start failed (${st.error.code}): ${st.error.message}`, { cleanup });
      }
      if (Date.now() >= deadline) {
        const cleanup = await this.#cleanupTab(tabInfo.tab_id);
        return refused('lifecycle.start', requestKey, 'start_failed',
          `pane did not reach its interactive shell prompt within ${this.startShellWaitMs}ms (agent_pane_busy)`,
          { cleanup });
      }
      await sleep(this.busyRetryDelayMs);
    }
  }

  async #cleanupTab(tabId) {
    const t = await this.herdr.tabClose(tabId);
    if (t.ok) return { closed: true };
    return {
      closed: false,
      note: `tab.close(${tabId}) failed (${t.error.code}): a tab may remain; close it in herdr`,
    };
  }

  // --- stop / resume ---------------------------------------------------------

  /**
   * Graceful stop. UNSUPPORTED on herdr 0.9.1: no first-class agent.stop and
   * no verified idle-only exit command. The explicitly destructive
   * alternative is forceClose — it is separate on purpose.
   */
  async stop(params = {}) {
    const conversationKey = params.conversationKey;
    if (!isStr(conversationKey)) {
      return refused('lifecycle.stop', params.requestKey, 'invalid_params', 'conversationKey is required');
    }
    const kind = await this.#resolveKind(conversationKey);
    const caps = kind ? declaredLifecycleCapabilities(kind) : null;
    const reason = caps && !caps.stop.supported
      ? caps.stop.reason
      : `${NO_AGENT_STOP}${kind === null ? ' (the target kind could not be resolved from a record or a live registration; no kind on this server has a verified graceful stop)' : ''}`;
    return unsupported('lifecycle.stop', params.requestKey, reason, {
      kindResolved: kind,
      destructiveAlternative: 'lifecycle.forceClose',
    });
  }

  /**
   * Resume the EXACT durable conversation. UNSUPPORTED on herdr 0.9.1: no
   * first-class agent.resume, and "latest file" heuristics are forbidden.
   */
  async resume(params = {}) {
    const conversationKey = params.conversationKey;
    if (!isStr(conversationKey)) {
      return refused('lifecycle.resume', params.requestKey, 'invalid_params', 'conversationKey is required');
    }
    const kind = await this.#resolveKind(conversationKey);
    const caps = kind ? declaredLifecycleCapabilities(kind) : null;
    const reason = caps && !caps.resume.supported ? caps.resume.reason : NO_AGENT_RESUME;
    return unsupported('lifecycle.resume', params.requestKey, reason, { kindResolved: kind });
  }

  async #resolveKind(conversationKey) {
    const rec = this.#registryRecord(conversationKey);
    if (rec && rec.kind) return rec.kind;
    const name = agentNameFor(conversationKey);
    const list = await this.herdr.agentList();
    if (!list.ok) return null;
    const validated = validatedAgentList(list.result);
    if (!validated.ok) return null;
    const live = validated.agents.find((a) => a.name === name);
    return (live && typeof live.agent === 'string' && live.agent) || null;
  }

  #registryRecord(conversationKey) {
    const reg = readConversations(this.stateDir);
    if (!reg.ok) return null;
    return reg.conversations.get(conversationKey) || null;
  }

  // --- status ----------------------------------------------------------------

  /**
   * Conversation state: 'running' | 'stopped' | 'unknown'. "Stopped" is
   * derived from registration/process inspection (agent.list, pane.get),
   * never from shell-prompt text or the absence of one status event.
   */
  async status(params = {}) {
    const conversationKey = params.conversationKey;
    if (!isStr(conversationKey)) {
      return refused('lifecycle.status', params.requestKey, 'invalid_params', 'conversationKey is required');
    }
    const name = agentNameFor(conversationKey);
    const reg = readConversations(this.stateDir);
    if (!reg.ok) {
      return unknownStatus(conversationKey, `${reg.reason}; occupancy cannot be trusted`);
    }
    const record = reg.conversations.get(conversationKey) || null;
    const list = await this.herdr.agentList();
    if (!list.ok) {
      return envelope('lifecycle.status', params.requestKey, 'completed', {
        result: {
          conversationKey,
          state: 'unknown',
          reason: `agent.list failed (${list.error.code}): ${list.error.message}`,
        },
      });
    }
    const validated = validatedAgentList(list.result);
    if (!validated.ok) {
      // Malformed occupancy reply: never invent a state from it.
      return unknownStatus(conversationKey, `occupancy inspection untrustworthy (${validated.reason})`);
    }
    const live =
      validated.agents.find((a) => a.name === name) ||
      (record ? validated.agents.find((a) => a.pane_id === record.paneId) : undefined);
    if (live) {
      // Running: herdr holds a live registration. Enrich with process
      // inspection when it answers (best-effort, never fabricated).
      const proc = await this.herdr.paneProcessInfo(live.pane_id);
      return envelope('lifecycle.status', params.requestKey, 'completed', {
        result: {
          conversationKey,
          state: 'running',
          agent: {
            name: live.name,
            paneId: live.pane_id,
            terminalId: live.terminal_id,
            tabId: live.tab_id,
            kind: typeof live.agent === 'string' ? live.agent : null,
            agentStatus: live.agent_status,
            launchPending: !!live.launch_pending,
          },
          evidence: {
            registration: 'herdr agent.list',
            ...(proc.ok && {
              process: summarizeProcessInfo(proc.result && proc.result.process_info),
            }),
          },
        },
      });
    }
    if (!record) {
      return envelope('lifecycle.status', params.requestKey, 'completed', {
        result: {
          conversationKey,
          state: 'stopped',
          evidence: { basis: 'no agent registered under the conversation identity (herdr agent.list)' },
        },
      });
    }
    if (record.session !== this.herdr.socketPath) {
      // The record belongs to another session: discover there, do not guess.
      const probeApi = new HerdrApi({ socketPath: record.session, requestTimeoutMs: Math.min(this.herdr.requestTimeoutMs, 5000) });
      const probe = await probeApi.agentList();
      if (!probe.ok) {
        return unknownStatus(conversationKey,
          `recorded on herdr session ${record.session}, which cannot be reached to verify state (${probe.error.code})`);
      }
      const probeValidated = validatedAgentList(probe.result);
      if (!probeValidated.ok) {
        return unknownStatus(conversationKey,
          `recorded on herdr session ${record.session}, whose occupancy reply was malformed (${probeValidated.reason})`);
      }
      const liveThere = probeValidated.agents.find((a) => a.name === record.name);
      if (liveThere) {
        return envelope('lifecycle.status', params.requestKey, 'completed', {
          result: {
            conversationKey,
            state: 'running',
            agent: {
              name: liveThere.name,
              paneId: liveThere.pane_id,
              terminalId: liveThere.terminal_id,
              tabId: liveThere.tab_id,
              kind: typeof liveThere.agent === 'string' ? liveThere.agent : null,
              agentStatus: liveThere.agent_status,
            },
            evidence: { registration: `herdr agent.list on session ${record.session} (cross-session discovery)` },
          },
        });
      }
      return envelope('lifecycle.status', params.requestKey, 'completed', {
        result: {
          conversationKey,
          state: 'unknown',
          reason: `recorded on herdr session ${record.session} where the agent is no longer registered; ` +
            'stale-registry reclamation happens on the next start mutation, not on a read',
        },
      });
    }
    const pane = await this.herdr.paneGet(record.paneId);
    if (pane.ok) {
      const p = pane.result && pane.result.pane;
      if (!p || typeof p !== 'object' || typeof p.terminal_id !== 'string') {
        return unknownStatus(conversationKey, 'pane.get result lacked pane identity (wire drift)');
      }
      if (p.terminal_id !== record.terminalId) {
        return unknownStatus(conversationKey, 'the recorded pane id now belongs to a different terminal identity');
      }
      if (typeof p.agent === 'string' && p.agent) {
        return unknownStatus(conversationKey, 'the pane hosts an agent that is not registered under the conversation identity');
      }
      return envelope('lifecycle.status', params.requestKey, 'completed', {
        result: {
          conversationKey,
          state: 'stopped',
          evidence: { basis: 'pane alive at its shell, no agent registered (pane.get + agent.list)' },
          last: recordIdentity(record),
        },
      });
    }
    if (pane.error.code === 'pane_not_found') {
      return envelope('lifecycle.status', params.requestKey, 'completed', {
        result: {
          conversationKey,
          state: 'stopped',
          evidence: { basis: 'pane closed (pane.get: pane_not_found) + no registration (agent.list)' },
          last: recordIdentity(record),
        },
      });
    }
    return unknownStatus(conversationKey, `pane.get failed (${pane.error.code}): ${pane.error.message}`);
  }

  // --- forceClose -------------------------------------------------------------

  /**
   * Explicitly DESTRUCTIVE close of exactly one agent pane, identified either
   * by a managed conversationKey (its registry record) or an explicit
   * {paneId, terminalId} pair. The requestKey ledger is consulted BEFORE the
   * mutable record lookup, so a replay of a completed close returns the
   * recorded envelope (never a fresh not_managed). Re-resolves the pane
   * identity immediately before dispatch and refuses on mismatch — pane ids
   * are opaque and reusable, and herdr 0.9.1 has no atomic expected-identity
   * close, so the envelope states the guard that was applied.
   */
  async forceClose(params = {}) {
    const requestKey = params.requestKey;
    if (requestKey !== undefined && !isStr(requestKey, 256)) {
      return refused('lifecycle.forceClose', requestKey, 'invalid_params', 'requestKey must be a non-empty string <=256 chars');
    }

    // Ledger FIRST — a SYNCHRONOUS claim BEFORE the mutable record lookup
    // (review blocker 3): a completed close replays its recorded envelope
    // even though the record it consumed is already dropped.
    const claim = this.#claimLedger('lifecycle.forceClose', requestKey);
    if (claim.refusal) return claim.refusal;
    if (claim.replay) return claim.replay;

    // Target resolution (may itself refuse, e.g. not_managed).
    const target = this.#resolveForceCloseTarget(params);
    if (target.error) {
      const env = refused('lifecycle.forceClose', requestKey, target.code, target.error);
      if (requestKey !== undefined && claim.slot) this.#settleSlot(requestKey, claim.slot, Promise.resolve(env));
      return env;
    }

    const domain = this.domain;
    const promise = this.#guarded('lifecycle.forceClose', requestKey, (key) => {
      const body = () => this.#forceCloseLocked(key, target.value);
      return target.value.conversationKey !== undefined
        ? conversationLock(domain, target.value.conversationKey).runExclusive(body)
        : body();
    });
    this.#settleSlot(requestKey, claim.slot, promise);
    let env;
    try {
      env = await promise;
    } catch (err) {
      env = refused('lifecycle.forceClose', requestKey, 'internal_error', `unexpected internal failure: ${err && err.message}`);
      if (requestKey !== undefined) this.domain.requests.set(requestKey, { state: 'completed', envelope: env });
    }
    return env;
  }

  #resolveForceCloseTarget(params) {
    if (isStr(params.conversationKey)) {
      const rec = this.#registryRecord(params.conversationKey);
      if (!rec) {
        return {
          code: 'not_managed',
          error: 'no coordinator record for this conversation; refusing to close an unverified pane ' +
            '(an explicit {paneId, terminalId} pair can be closed after re-resolution)',
        };
      }
      return { value: { conversationKey: params.conversationKey, paneId: rec.paneId, terminalId: rec.terminalId, record: rec } };
    }
    if (isStr(params.paneId) && isStr(params.terminalId)) {
      return { value: { paneId: params.paneId, terminalId: params.terminalId } };
    }
    return {
      code: 'invalid_params',
      error: 'provide conversationKey (managed) or an explicit {paneId, terminalId} pair',
    };
  }

  async #forceCloseLocked(requestKey, target) {
    // Re-resolve from stable identity immediately before dispatch.
    const pane = await this.herdr.paneGet(target.paneId);
    if (!pane.ok) {
      if (pane.error.code === 'pane_not_found') {
        this.#dropRecord(target);
        return refused('lifecycle.forceClose', requestKey, 'target_gone',
          'the pane no longer exists (pane.get: pane_not_found); nothing was closed',
          { paneId: target.paneId });
      }
      return refused('lifecycle.forceClose', requestKey, 'inspection_failed',
        `cannot re-resolve the pane before dispatch (pane.get: ${pane.error.code}): ${pane.error.message}; refusing to close unverified`);
    }
    const p = pane.result && pane.result.pane;
    if (!p || typeof p !== 'object' || typeof p.terminal_id !== 'string') {
      return refused('lifecycle.forceClose', requestKey, 'inspection_failed',
        'pane.get result lacked pane identity (wire drift); refusing to close unverified');
    }
    if (p.terminal_id !== target.terminalId) {
      // The pane id was reused by another terminal: close nothing.
      this.#dropRecord(target);
      return refused('lifecycle.forceClose', requestKey, 'identity_mismatch',
        `pane ${target.paneId} now belongs to terminal ${p.terminal_id}, not the recorded ${target.terminalId}; refused so the wrong pane is never closed`,
        { observedTerminalId: p.terminal_id });
    }
    const close = await this.herdr.paneClose(target.paneId);
    if (!close.ok) {
      if (close.error.code === 'pane_not_found') {
        this.#dropRecord(target);
        return refused('lifecycle.forceClose', requestKey, 'target_gone',
          'the pane disappeared between re-resolution and close; nothing was closed by us',
          { paneId: target.paneId });
      }
      return refused('lifecycle.forceClose', requestKey, 'herdr_rejected',
        `pane.close failed (${close.error.code}): ${close.error.message}`);
    }
    this.#dropRecord(target);
    this.#wire('lifecycle.force_closed', { paneId: target.paneId, terminalId: target.terminalId });
    return envelope('lifecycle.forceClose', requestKey, 'completed', {
      result: {
        closed: true,
        paneId: target.paneId,
        terminalId: target.terminalId,
        guard: 'pane.get -> terminal_id re-resolved immediately before pane.close ' +
          '(herdr 0.9.1 has no atomic expected-identity close; a pane-id reuse race remains and is stated, not hidden)',
      },
    });
  }

  #dropRecord(target) {
    if (target.conversationKey === undefined) return;
    // Only remove OUR conversation's record; keep the rest intact.
    const reg = readConversations(this.stateDir);
    if (!reg.ok) return;
    const existing = reg.conversations.get(target.conversationKey);
    if (existing && target.record && existing.paneId === target.record.paneId && existing.terminalId === target.record.terminalId) {
      reg.conversations.delete(target.conversationKey);
      writeConversations(this.stateDir, reg.conversations);
    }
  }

  // --- shared plumbing ---------------------------------------------------------

  /**
   * Whole-host mutation guard: in-process domain mutex, then the
   * INTERPROCESS lock file (two host-package processes cannot both mutate),
   * then the op. The op + requestKey are threaded through the closure so
   * completed envelopes carry them (review blocker 3).
   */
  #guarded(op, requestKey, fn) {
    // The op + requestKey are bound in the CLOSURE (never instance state:
    // a second queued operation on the same coordinator must not clobber
    // the first's key while it waits for the guard).
    return this.domain.guard.runExclusive(() =>
      withHostLock(this.lock, async () => {
        // Under the interprocess lock: a duplicate of this requestKey may
        // have COMPLETED in another process while we waited. Replay it.
        if (requestKey !== undefined) {
          const persisted = readRequests(this.stateDir);
          if (persisted.ok) {
            const hit = persisted.requests.find((e) => e.requestKey === requestKey);
            if (hit) return { ...hit.envelope, replayed: true };
          }
        }
        const env = await fn(requestKey);
        // Persist the completed envelope while STILL holding the lock, so
        // a concurrent process's re-check can never miss it.
        if (requestKey !== undefined && env && typeof env === 'object') {
          try {
            const persisted = readRequests(this.stateDir);
            if (persisted.ok) {
              const kept = persisted.requests.filter((e) => e.requestKey !== requestKey);
              kept.push({ requestKey, envelope: env });
              writeRequests(this.stateDir, kept);
            }
          } catch {} // a failed persist degrades replay, never correctness
        }
        return env;
      }).then((out) => {
        if (out && out.__lockError) {
          const code = out.__lockError.includes('timed out') ? 'lock_timeout' : 'lock_failed';
          return refused(op, requestKey, code, out.__lockError);
        }
        return out;
      }),
    );
  }

  /**
   * Returns an envelope to short-circuit with, or null to proceed.
   * Caches the ping result once a protocol-compatible server answered.
   */
  async #serverGate(op, requestKey) {
    if (this.#server) return null;
    const ping = await this.herdr.ping();
    if (!ping.ok) {
      return refused(op, requestKey, 'occupancy_unknown',
        `herdr unreachable (ping: ${ping.error.code}: ${ping.error.message}); unknown occupancy is a refusal`);
    }
    const proto = ping.result && ping.result.protocol;
    if (typeof proto !== 'number' || proto < MIN_HERDR_PROTOCOL) {
      return unsupported(op, requestKey,
        `herdr server protocol ${String(proto)} predates the verified protocol ${MIN_HERDR_PROTOCOL} semantics; lifecycle operations are unsupported on it`);
    }
    this.#server = ping.result;
    return null;
  }
}

// ---------------------------------------------------------------------------
// helpers

function unknownStatus(conversationKey, reason) {
  return envelope('lifecycle.status', undefined, 'completed', {
    result: { conversationKey, state: 'unknown', reason },
  });
}

function recordFromAgent(conversationKey, a, session, extra = {}) {
  return {
    conversationKey,
    kind: typeof a.agent === 'string' ? a.agent : null,
    name: a.name,
    paneId: a.pane_id,
    terminalId: a.terminal_id,
    tabId: a.tab_id,
    session,
    startedAt: isoNow(),
    launchPending: !!a.launch_pending,
    ...extra,
  };
}

function summarizeProcessInfo(info) {
  if (!info || typeof info !== 'object') return undefined;
  return {
    shellPid: info.shell_pid ?? null,
    foregroundProcessGroupId: info.foreground_process_group_id ?? null,
    foreground: Array.isArray(info.foreground_processes)
      ? info.foreground_processes.map((pr) => ({
          pid: pr.pid,
          name: pr.name,
          argv0: typeof pr.argv0 === 'string' ? pr.argv0 : null,
          cwd: typeof pr.cwd === 'string' ? pr.cwd : null,
        }))
      : [],
  };
}

function validateStartParams(params) {
  if (params === null || typeof params !== 'object' || Array.isArray(params)) {
    return { ok: false, code: 'invalid_params', message: 'params must be an object' };
  }
  if (!isStr(params.conversationKey)) {
    return { ok: false, code: 'invalid_params', message: 'conversationKey is required (non-empty string, <=512 chars)' };
  }
  if (!isStr(params.kind, 64)) {
    return { ok: false, code: 'invalid_params', message: 'kind is required' };
  }
  if (typeof params.cwd !== 'string' || !path.isAbsolute(params.cwd) || params.cwd.length > 4096) {
    return {
      ok: false,
      code: 'invalid_params',
      message: 'cwd must be an absolute path (resolve it at operation time; the caller owns provenance)',
    };
  }
  if (params.label !== undefined && (typeof params.label !== 'string' || params.label.length > 200)) {
    return { ok: false, code: 'invalid_params', message: 'label must be a string <=200 chars' };
  }
  if (params.focus !== undefined && typeof params.focus !== 'boolean') {
    return { ok: false, code: 'invalid_params', message: 'focus must be boolean' };
  }
  if (params.requestKey !== undefined && !isStr(params.requestKey, 256)) {
    return { ok: false, code: 'invalid_params', message: 'requestKey must be a non-empty string <=256 chars' };
  }
  return {
    ok: true,
    value: {
      conversationKey: params.conversationKey,
      kind: params.kind,
      cwd: params.cwd,
      ...(params.label !== undefined && { label: params.label }),
      ...(params.focus !== undefined && { focus: params.focus }),
      ...(params.requestKey !== undefined && { requestKey: params.requestKey }),
    },
  };
}
