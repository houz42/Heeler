// Agent-agnostic chat broker for protocol v1 (contract: local://agent-chat-v1-contract.md).
//
// A broker is a single Unix-socket rendezvous between two peer kinds:
//   - 'adapter': registers an agent instance and serves methods/events
//   - 'client':  discovers sessions, subscribes, sends requests
//
// The broker knows ONLY registrations (instanceId, sessionId, generation,
// capabilities, opaque locator), per-registration event seq, and routing.
// It never stores agent history, never parses params, never interprets
// event payloads. Framing is transport-neutral NDJSON; the same broker
// would work over any byte stream.
//
// Wire observability: every contract-level rejection a client can hit is
// also emitted as a structured log line (see logWireError / logWireEvent),
// so a client-side generic error is traceable to the exact broker-side
// rejection (method name, caller peer identity, reason). Logging is pure
// observation — it never changes routing or error responses.
//
// Programmatic use:
//   import { startBroker } from 'agent-chat/src/broker.mjs';
//   const broker = await startBroker({ socketPath: '/tmp/chat.sock' });
//   await broker.close();      // closes conns, removes ONLY the socket this broker bound
//
// See bin/broker.mjs for the executable wrapper.

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { FrameReader, MAX_FRAME_BYTES } from './frame.mjs';
import {
  PROTOCOL_VERSION,
  METHOD_CAPABILITIES,
  validateHelloPeer,
  validateRegisterFrame,
  validateRequestFrame,
  validateResponseFrame,
  validateEventFrame,
} from './protocol.mjs';

export const DEFAULTS = Object.freeze({
  registerTimeoutMs: 5000,
  requestTimeoutMs: 30_000,
  clientQueueBytes: 4 * 1024 * 1024,
  maxClientInflight: 64,
});

const S_IFMT = 0o170000;
const S_IFSOCK = 0o140000;

function isStr(v) {
  return typeof v === 'string' && v.length > 0;
}

function isSocketMode(mode) {
  return (mode & S_IFMT) === S_IFSOCK;
}

function myUid() {
  return typeof process.getuid === 'function' ? process.getuid() : -1;
}

// ---------------------------------------------------------------------------
// Wire observability log.
//
// Every line is one JSON object on one line:
//   {"ts":"2026-09-22T19:01:04.123Z","event":"request.unrouted","method":"answer",
//    "peer":"client#c2","code":"invalid_request","detail":"unknown method"}
//
// event values (stable, grep-able):
//   hello.rejected        handshake refused (protocol/peer invalid)
//   register.rejected     adapter registration failed validation
//   request.unrouted      client request matched NO route: unknown method
//   request.route_miss    client request matched NO route: target not
//                         registered (session_unavailable / stale_generation)
//   request.gated         capability-gate rejection (unsupported_capability)
//   adapter_frame.dropped unknown/unroutable adapter frame
// Destination: the `log` option (function) when provided, else stderr.
// `log: null` disables logging entirely.

function defaultWireLogSink(ev) {
  try {
    process.stderr.write(JSON.stringify(ev) + '\n');
  } catch {} // a broken stderr must never break the broker
}

function wirePeerLabel(sock, conn) {
  // No peer-id field exists on the wire, so identity is what the broker can
  // honestly observe: the connection kind, a per-broker connection ordinal
  // (c1, c2, ... in acceptance order), and the registered instanceId for
  // adapters once known. Unix sockets carry no meaningful remote address.
  if (conn?.kind === 'adapter' && conn.instanceId) return `adapter:${conn.instanceId}`;
  return `${conn?.kind ?? 'unhelloed'}#${conn?.label ?? '?'}`;
}

function isoNow() {
  return new Date().toISOString();
}


// Resolve the option value with validation: env override must be a finite
// positive number, else the default (never a guessed bad value).
function envNum(name, dflt) {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : dflt;
}

// ---------------------------------------------------------------------------
// Socket path hygiene: same-UID fail-closed.
//
// The socket lives only in a directory owned by this user (or a foreign
// sticky dir such as /tmp where the sticky bit protects our 0600 socket).
// A preexisting path is inspected (lstat — a dangling symlink fails
// closed) and only a same-UID socket with no group/other write access may
// be removed as stale, and only when nothing answers a connect probe.
// Shutdown removes the path only while it still refers to the inode this
// process bound, so a replacement broker's live socket is never deleted.

export function verifySocketDirectory(socketPath) {
  const dir = path.dirname(socketPath);
  if (!isStr(dir) || dir === '' || dir === '/') {
    throw Object.assign(new Error(`refusing unsafe socket path: ${socketPath}`), { code: 'unsafe_socket_path' });
  }
  let dirCreated = false;
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.chmodSync(dir, 0o700);
    dirCreated = true;
  }
  if (!dirCreated) {
    const dst = fs.statSync(dir);
    if (dst.uid !== myUid()) {
      // Foreign-owned dir (e.g. /tmp): sticky bit is the guarantee —
      // others cannot unlink/rename our 0600 socket there.
      if ((dst.mode & 0o1000) === 0) {
        throw Object.assign(
          new Error(`foreign socket directory is not sticky (others could swap the socket): ${dir}`),
          { code: 'unsafe_socket_dir' },
        );
      }
    } else if ((dst.mode & 0o022) !== 0) {
      // Our own dir must be private: anyone could unlink+replace the socket.
      throw Object.assign(new Error(`socket directory is writable by others: ${dir}`), { code: 'unsafe_socket_dir' });
    }
  }
}

async function removeStaleSocket(socketPath) {
  let preexisting = null;
  try {
    preexisting = fs.lstatSync(socketPath);
  } catch (err) {
    if (err.code !== 'ENOENT') {
      throw Object.assign(new Error(`cannot inspect ${socketPath}: ${err.message}`), { code: 'unsafe_socket_path' });
    }
    return;
  }
  if (!isSocketMode(preexisting.mode)) {
    throw Object.assign(new Error(`refusing to overwrite non-socket path ${socketPath}`), { code: 'unsafe_socket_path' });
  }
  const live = await new Promise((resolve) => {
    const probe = net.connect(socketPath);
    probe.once('connect', () => {
      probe.destroy();
      resolve(true);
    });
    probe.once('error', () => resolve(false));
  });
  if (live) {
    throw Object.assign(new Error(`another broker already owns ${socketPath}`), { code: 'socket_in_use' });
  }
  // Stale socket from a crashed broker: only a same-UID socket with no
  // group/other write access may be removed (nobody could have swapped it).
  if (preexisting.uid !== myUid() || (preexisting.mode & 0o022) !== 0) {
    throw Object.assign(
      new Error(`stale socket is not safely removable (foreign owner or group/other writable): ${socketPath}`),
      { code: 'unsafe_socket_path' },
    );
  }
  fs.rmSync(socketPath, { force: true });
}

// ---------------------------------------------------------------------------
// Broker

export async function startBroker(opts = {}) {
  const socketPath = opts.socketPath;
  if (!isStr(socketPath)) {
    throw Object.assign(new TypeError('startBroker requires a socketPath'), { code: 'invalid_request' });
  }
  const cfg = {
    registerTimeoutMs: opts.registerTimeoutMs ?? envNum('AGENT_CHAT_REGISTER_TIMEOUT_MS', DEFAULTS.registerTimeoutMs),
    requestTimeoutMs: opts.requestTimeoutMs ?? envNum('AGENT_CHAT_REQUEST_TIMEOUT_MS', DEFAULTS.requestTimeoutMs),
    clientQueueBytes: opts.clientQueueBytes ?? envNum('AGENT_CHAT_CLIENT_QUEUE_BYTES', DEFAULTS.clientQueueBytes),
    maxClientInflight: opts.maxClientInflight ?? envNum('AGENT_CHAT_MAX_CLIENT_INFLIGHT', DEFAULTS.maxClientInflight),
    // Wire-observability sink: function(obj) per event. null = disabled.
    log: opts.log === undefined ? defaultWireLogSink : opts.log,
  };
  verifySocketDirectory(socketPath);
  await removeStaleSocket(socketPath);

  const broker = new Broker(socketPath, cfg);
  await broker.listen();
  return broker;
}

class Broker {
  constructor(socketPath, cfg) {
    this.socketPath = socketPath;
    this.cfg = cfg;
    this.registrations = new Map(); // instanceId -> registration
    this.conns = new Map(); // socket -> conn state
    this.corr = new Map(); // correlation id -> in-flight request
    this.subscribers = new Map(); // instanceId -> Map(client -> subscribed generation)
    this.corrSeq = 0;
    this.connSeq = 0; // per-connection ordinal for log peer labels
    this.boundInode = null;
    // No async teardown race: the exit hook is the only safety net needed
    // for process exit; programmatic close() is explicit.
    this._onExit = () => this.removeOwnedSocket();
    process.on('exit', this._onExit);
  }

  listen() {
    return new Promise((resolve, reject) => {
      this.server = net.createServer((sock) => this.onConnection(sock));
      this.server.once('error', (err) => {
        if (this.boundInode === null) {
          this.teardown();
          reject(Object.assign(new Error(`cannot listen on ${this.socketPath}: ${err.message}`), { code: 'socket_in_use' }));
        }
      });
      this.server.listen(this.socketPath, () => {
        try {
          const st = fs.lstatSync(this.socketPath);
          this.boundInode = st.ino;
          // Private socket: refuse group/other bits; umask may have granted them.
          if ((st.mode & 0o077) !== 0) {
            fs.chmodSync(this.socketPath, 0o600);
            this.boundInode = fs.lstatSync(this.socketPath).ino;
          }
        } catch {}
        resolve();
      });
    });
  }

  // --- per-connection plumbing --------------------------------------------

  // Emit one wire-observability event. Never throws, never alters routing:
  // a broken sink degrades to silence, not to a broken broker.
  logWire(event, fields) {
    if (!this.cfg.log) return;
    try {
      this.cfg.log({ ts: isoNow(), event, ...fields });
    } catch {}
  }


  onConnection(sock) {
    const conn = {
      kind: null, // 'client' | 'adapter' once hello'd
      instanceId: null,
      subs: new Set(), // subscribed instanceIds
      label: `c${++this.connSeq}`, // log peer label ordinal
      handshakeTimer: setTimeout(() => {
        if (this.conns.get(sock)?.kind == null) sock.destroy();
      }, this.cfg.registerTimeoutMs),
      reader: new FrameReader({ maxBytes: MAX_FRAME_BYTES, onFrame: (f) => this.onFrame(sock, f) }),
      inflight: 0,
    };
    this.conns.set(sock, conn);
    sock.setNoDelay(true);
    sock.on('data', (chunk) => {
      if (conn.reader.push(chunk) === false) sock.destroy();
    });
    sock.on('error', () => {}); // surfaced via 'close'
    sock.on('close', () => {
      clearTimeout(conn.handshakeTimer);
      this.cleanupConn(sock);
    });
  }

  write(sock, obj) {
    if (sock.destroyed) return false;
    sock.write(JSON.stringify(obj) + '\n');
    // Bounded write backlog: a slow consumer is disconnected, never allowed
    // to wedge the broker or the adapter.
    if (sock.writableLength > this.cfg.clientQueueBytes) sock.destroy();
    return !sock.destroyed;
  }

  clientError(sock, clientId, code, message) {
    this.write(sock, {
      type: 'response',
      id: clientId,
      error: { code, message, retryable: code === 'overloaded' },
    });
  }

  // --- frame dispatch -------------------------------------------------------

  onFrame(sock, f) {
    const conn = this.conns.get(sock);
    if (!conn) return false;
    if (!conn.kind) return this.onHandshakeFrame(sock, conn, f);
    if (conn.kind === 'adapter') return this.onAdapterFrame(sock, conn, f);
    return this.onClientFrame(sock, conn, f);
  }

  onHandshakeFrame(sock, conn, f) {
    clearTimeout(conn.handshakeTimer);
    const hello = validateHelloPeer(f);
    if (!hello.ok) {
      this.logWire('hello.rejected', { peer: wirePeerLabel(sock, conn), code: hello.code, detail: hello.message });
      this.write(sock, { type: 'error', error: { code: hello.code, message: hello.message, retryable: false } });
      sock.destroy();
      return false;
    }
    conn.kind = hello.value.peer;
    this.write(sock, { type: 'welcome', protocol: PROTOCOL_VERSION, maxFrameBytes: MAX_FRAME_BYTES });
    if (conn.kind === 'adapter') {
      // register must arrive on this fresh connection within the register window
      conn.handshakeTimer = setTimeout(() => {
        if (this.conns.get(sock)?.instanceId == null) sock.destroy();
      }, this.cfg.registerTimeoutMs);
    }
    return true;
  }

  // --- registration ----------------------------------------------------------

  registerAdapter(sock, f) {
    const { instanceId, generation } = f.registration;
    const prev = this.registrations.get(instanceId);
    if (prev && generation < prev.generation) {
      // A stale (older-generation) re-register must never evict the live route.
      this.write(sock, { type: 'error', error: { code: 'stale_generation', message: 'a newer generation is registered for this instance', retryable: false } });
      sock.destroy();
      return;
    }
    if (prev) {
      // Duplicate registration terminates the old route; the old socket's
      // cleanup sees the registration already re-pointed and stays quiet.
      prev.sock.destroy();
      this.failPending(instanceId, 'session_unavailable', 'adapter route replaced');
    }
    this.registrations.set(instanceId, {
      sock,
      ...f.registration,
      lastSeq: -1, // producer seq validated monotonic per registration
    });
    // Subscribers pinned to a superseded generation must reopen the snapshot.
    this.notifyUnavailable(instanceId, generation);
    this.write(sock, { type: 'registered', instanceId, generation });
  }

  // Fail every in-flight request routed to a route that just died, and
  // notify subscribers. Generation metadata only; registration contents are
  // never echoed to clients here.
  failPending(instanceId, code, message) {
    for (const [cid, entry] of this.corr) {
      if (entry.instanceId !== instanceId) continue;
      this.corr.delete(cid);
      clearTimeout(entry.timer);
      const conn = this.conns.get(entry.client);
      if (conn) conn.inflight--;
      this.clientError(entry.client, entry.clientId, code, message);
    }
  }

  notifyUnavailable(instanceId, exceptGen) {
    const subs = this.subscribers.get(instanceId);
    if (!subs) return;
    const reg = this.registrations.get(instanceId);
    for (const [client, gen] of [...subs]) {
      if (exceptGen !== undefined && gen === exceptGen) continue;
      subs.delete(client);
      const conn = this.conns.get(client);
      if (conn) conn.subs.delete(instanceId);
      const msg = { type: 'session.unavailable', instanceId, generation: gen };
      if (reg) msg.currentGeneration = reg.generation;
      this.write(client, msg);
    }
    if (subs.size === 0) this.subscribers.delete(instanceId);
  }

  // --- adapter frames --------------------------------------------------------

  onAdapterFrame(sock, conn, f) {
    if (f.type === 'register' && conn.instanceId == null) {
      const reg = validateRegisterFrame(f);
      if (!reg.ok) {
        this.logWire('register.rejected', { peer: wirePeerLabel(sock, conn), code: reg.code, detail: reg.message });
        this.write(sock, { type: 'error', error: { code: reg.code, message: reg.message, retryable: false } });
        sock.destroy();
        return false;
      }
      conn.instanceId = reg.value.registration.instanceId;
      this.registerAdapter(sock, reg.value);
      return !sock.destroyed;
    }
    if (conn.instanceId == null) {
      this.logWire('adapter_frame.dropped', { peer: wirePeerLabel(sock, conn), detail: `frame type ${JSON.stringify(f.type)} before register` });
      sock.destroy(); // no frames except register are valid pre-registration
      return false;
    }
    const regEntry = this.registrations.get(conn.instanceId);
    if (f.type === 'event') {
      const ev = validateEventFrame(f);
      if (!ev.ok) {
        this.write(sock, { type: 'error', error: { code: ev.code, message: ev.message, retryable: false } });
        sock.destroy();
        return false;
      }
      if (!regEntry || regEntry.sock !== sock) return true; // route replaced; drop
      if (ev.value.instanceId !== conn.instanceId || ev.value.generation !== regEntry.generation) {
        sock.destroy();
        return false;
      }
      // Producer seq must monotonically increase per registration; the
      // broker PRESERVES the validated seq (never renumbers), so throughSeq
      // watermarks stay meaningful to the client.
      if (ev.value.seq <= regEntry.lastSeq) {
        this.logWire('adapter_frame.dropped', {
          peer: wirePeerLabel(sock, conn),
          detail: `event seq ${ev.value.seq} did not increase (last ${regEntry.lastSeq})`,
        });
        this.write(sock, { type: 'error', error: { code: 'invalid_request', message: `event seq ${ev.value.seq} did not increase (last ${regEntry.lastSeq})`, retryable: false } });
        sock.destroy();
        return false;
      }
      regEntry.lastSeq = ev.value.seq;
      // Send-path observability: the adapter's delivery confirmation is
      // logged (requestKey + committed recordId) so a send.accepted line with
      // NO matching send.confirmed pins the failure to the adapter side.
      if (ev.value.event?.type === 'send.confirmed') {
        this.logWire('send.confirmed', {
          peer: wirePeerLabel(sock, conn),
          requestKey: ev.value.event.requestKey,
          recordId: ev.value.event.recordId,
          instanceId: conn.instanceId,
          seq: ev.value.seq,
        });
      }
      const subs = this.subscribers.get(conn.instanceId);
      if (subs) {
        for (const [client, gen] of [...subs]) {
          if (gen === ev.value.generation) this.write(client, ev.value);
        }
      }
      return true;
    }
    if (f.type === 'response') {
      const res = validateResponseFrame(f);
      if (!res.ok) {
        // Malformed reply for a correlated request fails THAT request
        // explicitly; the adapter connection stays (framing is intact).
        const entry = this.corr.get(String(f.id));
        if (entry) this.settle(entry, res.code, res.message);
        return true;
      }
      const entry = this.corr.get(res.value.id);
      if (!entry || entry.instanceId !== conn.instanceId) return true; // stale/foreign reply: drop
      this.settle(entry, null, null, res.value);
      return true;
    }
    this.logWire('adapter_frame.dropped', { peer: wirePeerLabel(sock, conn), detail: `unknown adapter frame type ${JSON.stringify(f.type)}` });
    sock.destroy(); // unknown adapter frame
    return false;
  }

  settle(entry, errorCode, errorMessage, response) {
    if (!this.corr.get(entry.corrId) || this.corr.get(entry.corrId) !== entry) return;
    this.corr.delete(entry.corrId);
    clearTimeout(entry.timer);
    const conn = this.conns.get(entry.client);
    if (conn) conn.inflight--;
    if (entry.client.destroyed) return;
    if (errorCode) {
      this.clientError(entry.client, entry.clientId, errorCode, errorMessage);
    } else if (response.error) {
      this.write(entry.client, { type: 'response', id: entry.clientId, error: response.error });
    } else {
      this.write(entry.client, { type: 'response', id: entry.clientId, result: response.result });
    }
  }

  // --- client frames ---------------------------------------------------------

  onClientFrame(sock, conn, f) {
    const req = validateRequestFrame(f);
    if (!req.ok) return !this.clientError(sock, f.id, req.code, req.message), true;
    const { id, method, target, params } = req.value;

    if (method === 'sessions.list') {
      const sessions = [...this.registrations.entries()].map(([instanceId, r]) => ({
        instanceId,
        sessionId: r.sessionId,
        generation: r.generation,
        agent: r.agent,
        ...(r.title !== undefined && { title: r.title }),
        ...(r.locator !== undefined && { locator: r.locator }),
        capabilities: r.capabilities,
      }));
      return this.write(sock, { type: 'response', id, result: { sessions } });
    }

    if (!target) {
      this.logWire('request.unrouted', { peer: wirePeerLabel(sock, conn), method, code: 'invalid_request', detail: `missing target` });
      return this.clientError(sock, id, 'invalid_request', `method ${method} requires target:{instanceId,generation}`);
    }
    const reg = this.registrations.get(target.instanceId);
    if (!reg) {
      this.logWire('request.route_miss', {
        peer: wirePeerLabel(sock, conn),
        method,
        target: target.instanceId,
        code: 'session_unavailable',
        detail: `no adapter registered for instance ${target.instanceId}`,
      });
      return this.clientError(sock, id, 'session_unavailable', `no adapter registered for instance ${target.instanceId}`);
    }
    if (target.generation !== reg.generation) {
      this.logWire('request.route_miss', {
        peer: wirePeerLabel(sock, conn),
        method,
        target: `${target.instanceId}@${target.generation}`,
        code: 'stale_generation',
        detail: `registered generation is ${reg.generation}`,
      });
      if (target.generation < reg.generation) {
        return this.clientError(sock, id, 'stale_generation', `generation ${target.generation} is older than registered ${reg.generation}`);
      }
      return this.clientError(sock, id, 'stale_generation', `generation ${target.generation} is newer than registered ${reg.generation}; resubscribe`);
    }

    if (method === 'sessions.subscribe') {
      let subs = this.subscribers.get(target.instanceId);
      if (!subs) this.subscribers.set(target.instanceId, (subs = new Map()));
      subs.set(sock, target.generation);
      conn.subs.add(target.instanceId);
      return this.write(sock, { type: 'response', id, result: { subscribed: true } });
    }

    const capability = METHOD_CAPABILITIES[method];
    if (capability === undefined) {
      this.logWire('request.unrouted', { peer: wirePeerLabel(sock, conn), method, code: 'invalid_request', detail: 'unknown method' });
      return this.clientError(sock, id, 'invalid_request', `unknown method ${method}`);
    }
    if (!reg.capabilities[capability]) {
      this.logWire('request.gated', {
        peer: wirePeerLabel(sock, conn),
        method,
        target: target.instanceId,
        capability,
        code: 'unsupported_capability',
        detail: `session ${reg.sessionId} does not support ${method} (capability ${capability} not declared)`,
      });
      return this.clientError(sock, id, 'unsupported_capability', `session ${reg.sessionId} does not support ${method}`);
    }

    // Routed request: the client's id is replaced by a broker correlation
    // id. Per-client in-flight cap — a single client cannot fan out
    // unbounded parallel work.
    if (conn.inflight >= this.cfg.maxClientInflight) {
      return this.clientError(sock, id, 'too_many_inflight', `client already has ${conn.inflight} requests in flight`);
    }
    const corrId = `b${++this.corrSeq}`;
    const entry = {
      corrId,
      client: sock,
      clientId: id,
      instanceId: target.instanceId,
      timer: null,
    };
    entry.timer = setTimeout(() => {
      if (this.corr.get(corrId) !== entry) return;
      this.corr.delete(corrId);
      const c = this.conns.get(sock);
      if (c) c.inflight--;
      this.clientError(sock, id, 'timeout', `adapter did not answer ${method} within ${this.cfg.requestTimeoutMs}ms`);
    }, this.cfg.requestTimeoutMs);
    this.corr.set(corrId, entry);
    conn.inflight++;
    // Send-path observability: a prompt.send the broker ROUTES is logged
    // with its requestKey, so a client-reported send failure is attributable
    // (routed-but-never-confirmed = adapter-side drop; no route log at all =
    // app/broker path). No wire change: pure logWire emission.
    if (method === 'prompt.send') {
      this.logWire('send.accepted', {
        peer: wirePeerLabel(sock, conn),
        requestKey: typeof params?.requestKey === 'string' ? params.requestKey : undefined,
        target: target.instanceId,
        corrId,
      });
    }
    this.write(reg.sock, { type: 'request', id: corrId, method, target, ...(params !== undefined && { params }) });
    return true;
  }

  // --- teardown ---------------------------------------------------------------

  cleanupConn(sock) {
    const conn = this.conns.get(sock);
    this.conns.delete(sock);
    if (!conn) return;
    if (conn.kind === 'adapter' && conn.instanceId) {
      const reg = this.registrations.get(conn.instanceId);
      if (reg && reg.sock === sock) {
        this.registrations.delete(conn.instanceId);
        this.failPending(conn.instanceId, 'session_unavailable', 'adapter disconnected');
        this.notifyUnavailable(conn.instanceId);
      }
    } else if (conn.kind === 'client') {
      for (const inst of conn.subs) {
        const subs = this.subscribers.get(inst);
        if (subs) {
          subs.delete(sock);
          if (subs.size === 0) this.subscribers.delete(inst);
        }
      }
      for (const [cid, entry] of this.corr) {
        if (entry.client === sock) {
          this.corr.delete(cid);
          clearTimeout(entry.timer);
        }
      }
    }
  }

  removeOwnedSocket() {
    if (this.boundInode === null) return true; // never bound: nothing we may remove
    let st;
    try {
      st = fs.lstatSync(this.socketPath);
    } catch (err) {
      return err.code === 'ENOENT';
    }
    if (!isSocketMode(st.mode) || st.ino !== this.boundInode) return false; // not ours anymore
    try {
      fs.rmSync(this.socketPath, { force: true });
    } catch {
      return false;
    }
    return true;
  }

  async close() {
    if (this.closePromise) return this.closePromise;
    this.closing = true;
    this.closePromise = (async () => {
      process.removeListener('exit', this._onExit);
      for (const entry of this.corr.values()) clearTimeout(entry.timer);
      this.corr.clear();
      try {
        this.server?.close();
      } catch {}
      for (const s of [...this.conns.keys()]) s.destroy();
      const removed = this.removeOwnedSocket();
      this.closed = true;
      if (!removed) {
        throw Object.assign(new Error(`socket ${this.socketPath} was replaced; not removed`), { code: 'socket_replaced' });
      }
    })();
    return this.closePromise;
  }

  teardown() {
    // Best-effort synchronous teardown after a listen failure.
    try {
      this.server?.close();
    } catch {}
    process.removeListener('exit', this._onExit);
  }
}
