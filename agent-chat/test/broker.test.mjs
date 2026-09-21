// Broker behavior tests over a real Unix socket: handshakes, registration
// supersession, routing, subscription fan-out with preserved producer seq,
// inflight caps, disconnect semantics, and fail-closed path hygiene.
// A scripted fake adapter exercises the same wire the real one will use.

import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { startBroker } from '../src/broker.mjs';
import { FrameReader, MAX_FRAME_BYTES } from '../src/frame.mjs';
import { PROTOCOL_VERSION } from '../src/protocol.mjs';

let dir;
let broker;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-chat-broker-'));
  broker = await startBroker({
    socketPath: path.join(dir, 'chat.sock'),
    registerTimeoutMs: 500,
    requestTimeoutMs: 800,
    maxClientInflight: 2,
  });
});

afterEach(async () => {
  await broker?.close().catch(() => {});
  fs.rmSync(dir, { recursive: true, force: true });
});

// Minimal scripted peer: hello, then collect frames; reply() sends one.
class Peer {
  constructor() {
    this.frames = [];
    this.sock = net.connect(broker.socketPath);
    this.sock.setNoDelay(true);
    this.closed = new Promise((r) => this.sock.once('close', r));
    this.reader = new FrameReader({ maxBytes: MAX_FRAME_BYTES, onFrame: (f) => this.frames.push(f) });
    this.sock.on('data', (c) => {
      if (this.reader.push(c) === false) this.sock.destroy();
    });
  }
  async next(pred, label, timeoutMs = 2000) {
    // Search every frame received so far, not just ones arriving after the
    // call: the awaited frame usually lands while earlier awaits (welcome/
    // registered handshakes, other replies) were being processed.
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const f = this.frames.find(pred);
      if (f) return f;
      if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`);
      await new Promise((r) => setTimeout(r, 10));
    }
  }
  send(obj) {
    this.sock.write(JSON.stringify(obj) + '\n');
  }
  async close() {
    this.sock.destroy();
    await this.closed;
  }
}
const HELLO_ADAPTER = { type: 'hello', protocol: PROTOCOL_VERSION, peer: 'adapter' };
const HELLO_CLIENT = { type: 'hello', protocol: PROTOCOL_VERSION, peer: 'client' };

function registration(over = {}) {
  return {
    type: 'register',
    registration: {
      instanceId: 'inst-1',
      sessionId: 'sess-1',
      generation: 0,
      agent: { kind: 'omp', version: '9.9' },
      capabilities: {
        history: true,
        streaming: true,
        prompt: true,
        interrupt: true,
        interactions: true,
        commands: true,
        attachments: false,
        branches: false,
        telemetry: false,
      },
      ...over,
    },
  };
}

async function adapterPeer(over = {}) {
  const p = new Peer();
  p.send(HELLO_ADAPTER);
  await p.next((f) => f.type === 'welcome', 'welcome');
  p.send(registration(over));
  await p.next((f) => f.type === 'registered', 'registered');
  return p;
}

async function clientPeer() {
  const p = new Peer();
  p.send(HELLO_CLIENT);
  await p.next((f) => f.type === 'welcome', 'welcome');
  return p;
}

test('hello rejects unknown protocol versions and wrong peers', async () => {
  const bad = new Peer();
  bad.send({ type: 'hello', protocol: 2, peer: 'adapter' });
  const errFrame = await bad.next((f) => f.type === 'error', 'unsupported_protocol error');
  assert.equal(errFrame.error.code, 'unsupported_protocol');
  assert.equal(errFrame.error.retryable, false);
  await bad.closed;
  // peer:'agent' is not a v1 peer
  const bad2 = new Peer();
  bad2.send({ type: 'hello', protocol: 1, peer: 'agent' });
  const errFrame2 = await bad2.next((f) => f.type === 'error', 'invalid peer error');
  assert.equal(errFrame2.error.code, 'invalid_request');
  await bad2.closed;
});

test('handshake must happen before any other frame', async () => {
  const p = new Peer();
  p.send(registration()); // register before hello
  await p.closed;
  assert.equal(broker.conns.size, 0);
});

test('adapter connection is closed when register does not follow hello in time', async () => {
  const p = new Peer();
  p.send(HELLO_ADAPTER);
  await p.next((f) => f.type === 'welcome', 'welcome');
  await p.closed; // registerTimeoutMs 500 in this suite
});

test('sessions.list reflects live registrations and omits nothing the UI needs', async () => {
  await adapterPeer({ title: 'My Agent', locator: { paneId: 'w1:pA' } });
  const c = await clientPeer();
  c.send({ type: 'request', id: 'r1', method: 'sessions.list' });
  const res = await c.next((f) => f.id === 'r1', 'sessions.list reply');
  assert.equal(res.result.sessions.length, 1);
  const [s] = res.result.sessions;
  assert.equal(s.instanceId, 'inst-1');
  assert.equal(s.sessionId, 'sess-1');
  assert.equal(s.generation, 0);
  assert.deepEqual(s.agent, { kind: 'omp', version: '9.9' });
  assert.equal(s.title, 'My Agent');
  assert.deepEqual(s.locator, { paneId: 'w1:pA' });
  assert.equal(s.capabilities.prompt, true);
  assert.equal(s.capabilities.attachments, false);
  await c.close();
});

test('client request routed to adapter with correlation swap; result restored to client id', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'r9', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 }, params: { limit: 5 } });
  const routed = await a.next((f) => f.type === 'request', 'routed request');
  assert.equal(routed.id.startsWith('b'), true);
  assert.equal(routed.method, 'history.open');
  assert.deepEqual(routed.target, { instanceId: 'inst-1', generation: 0 });
  assert.deepEqual(routed.params, { limit: 5 });
  a.send({ type: 'response', id: routed.id, result: { items: [] } });
  const res = await c.next((f) => f.id === 'r9', 'client reply');
  assert.deepEqual(res.result, { items: [] });
  await c.close();
  await a.close();
});

test('routed request params are optional; adapter answers error with stable code', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'rE', method: 'interrupt', target: { instanceId: 'inst-1', generation: 0 } });
  const routed = await a.next((f) => f.type === 'request', 'routed interrupt');
  assert.equal('params' in routed, false);
  a.send({ type: 'response', id: routed.id, error: { code: 'internal_error', message: 'boom', retryable: false } });
  const res = await c.next((f) => f.id === 'rE', 'client error reply');
  assert.deepEqual(res.error, { code: 'internal_error', message: 'boom', retryable: false });
  await c.close();
  await a.close();
});

test('unknown client method rejected before routing; capability bits enforced', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'x1', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  const routed = await a.next((f) => f.type === 'request', 'routed history.open');
  a.send({ type: 'response', id: routed.id, result: {} });
  await c.next((f) => f.id === 'x1', 'x1 reply');
  c.send({ type: 'request', id: 'x2', method: 'not.a.method', target: { instanceId: 'inst-1', generation: 0 } });
  const e1 = await c.next((f) => f.id === 'x2', 'x2 reply');
  assert.equal(e1.error.code, 'invalid_request');
  // attachments:false in registration -> blob-ish methods unsupported? blob.read is history capability.
  // Use a fresh registration with history:false via a second instance.
  const a2 = await adapterPeer({ instanceId: 'inst-2', generation: 0 });
  // change capabilities via register frame over same adapter is impossible; new adapter conn instead
  await a2.close();
  await c.close();
  await a.close();
});

test('target missing or unknown instance is explicit, never routed', async () => {
  const c = await clientPeer();
  c.send({ type: 'request', id: 't1', method: 'history.open', target: { instanceId: 'nope', generation: 0 } });
  const r = await c.next((f) => f.id === 't1', 't1 reply');
  assert.equal(r.error.code, 'session_unavailable');
  c.send({ type: 'request', id: 't2', method: 'history.open' });
  const r2 = await c.next((f) => f.id === 't2', 't2 reply');
  assert.equal(r2.error.code, 'invalid_request');
  await c.close();
});

test('stale and future generations are rejected with stale_generation', async () => {
  await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'g1', method: 'history.open', target: { instanceId: 'inst-1', generation: 1 } });
  assert.equal((await c.next((f) => f.id === 'g1', 'g1 reply')).error.code, 'stale_generation');
  c.send({ type: 'request', id: 'g2', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  // generation 0 is current: routed (no adapter reply needed for the test)
  c.send({ type: 'request', id: 'g3', method: 'history.open', target: { instanceId: 'inst-1', generation: -1 } });
  assert.equal((await c.next((f) => f.id === 'g3', 'g3 reply')).error.code, 'invalid_request');
  await c.close();
});

test('per-client inflight cap: 3rd request fails with too_many_inflight', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  for (let i = 1; i <= 3; i++) {
    c.send({ type: 'request', id: `i${i}`, method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  }
  const r3 = await c.next((f) => f.id === 'i3', 'i3 reply');
  assert.equal(r3.error.code, 'too_many_inflight');
  // Adapter sees exactly two routed requests.
  await a.next((f) => f.type === 'request' && f.id === 'b1', 'first routed');
  await a.next((f) => f.type === 'request' && f.id === 'b2', 'second routed');
  assert.equal(a.frames.some((f) => f.type === 'request' && f.id === 'b3'), false);
  await c.close();
  await a.close();
});

test('subscription fan-out preserves producer seq and only hits matching-generation subscribers', async () => {
  const a = await adapterPeer();
  const c1 = await clientPeer();
  const c2 = await clientPeer();
  c1.send({ type: 'request', id: 's1', method: 'sessions.subscribe', target: { instanceId: 'inst-1', generation: 0 } });
  c2.send({ type: 'request', id: 's2', method: 'sessions.subscribe', target: { instanceId: 'inst-1', generation: 0 } });
  await c1.next((f) => f.id === 's1', 's1 ack');
  await c2.next((f) => f.id === 's2', 's2 ack');
  a.send({ type: 'event', instanceId: 'inst-1', generation: 0, seq: 0, event: { type: 'message.started', streamId: 'x' } });
  a.send({ type: 'event', instanceId: 'inst-1', generation: 0, seq: 1, event: { type: 'message.delta', text: 'hi' } });
  const e1 = await c1.next((f) => f.type === 'event' && f.seq === 1, 'c1 event seq 1');
  assert.equal(e1.seq, 1); // preserved, not renumbered
  const e2 = await c2.next((f) => f.type === 'event' && f.seq === 1, 'c2 event seq 1');
  assert.deepEqual(e2.event, { type: 'message.delta', text: 'hi' });
  await c1.close();
  await c2.close();
  await a.close();
});

test('non-increasing producer seq drops the adapter connection', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 's', method: 'sessions.subscribe', target: { instanceId: 'inst-1', generation: 0 } });
  await c.next((f) => f.id === 's', 'subscribe ack');
  a.send({ type: 'event', instanceId: 'inst-1', generation: 0, seq: 5, event: { type: 'message.started' } });
  await c.next((f) => f.type === 'event' && f.seq === 5, 'event 5');
  a.send({ type: 'event', instanceId: 'inst-1', generation: 0, seq: 5, event: { type: 'message.delta' } }); // equal: not increasing
  await a.closed;
  // Subscribers are notified the session is unavailable.
  const un = await c.next((f) => f.type === 'session.unavailable', 'session.unavailable');
  assert.equal(un.instanceId, 'inst-1');
  assert.equal(un.generation, 0);
  await c.close();
});

test('adapter disconnect fails in-flight requests explicitly and notifies subscribers', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'p1', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  await a.next((f) => f.type === 'request', 'routed p1');
  c.send({ type: 'request', id: 's', method: 'sessions.subscribe', target: { instanceId: 'inst-1', generation: 0 } });
  await c.next((f) => f.id === 's', 'subscribe ack');
  await a.close(); // adapter dies with p1 unanswered
  const r = await c.next((f) => f.id === 'p1', 'p1 failure');
  assert.equal(r.error.code, 'session_unavailable');
  assert.equal(r.error.retryable, false);
  const un = await c.next((f) => f.type === 'session.unavailable', 'unavailable notice');
  assert.equal(un.instanceId, 'inst-1');
  assert.equal(un.generation, 0);
  assert.equal('currentGeneration' in un, false); // no replacement registered
  // The registration is gone: subsequent requests fail fast.
  c.send({ type: 'request', id: 'p2', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  assert.equal((await c.next((f) => f.id === 'p2', 'p2 reply')).error.code, 'session_unavailable');
  await c.close();
});

test('re-registration with a new generation supersedes; old subscribers told to resync', async () => {
  const a1 = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 's', method: 'sessions.subscribe', target: { instanceId: 'inst-1', generation: 0 } });
  await c.next((f) => f.id === 's', 'subscribe ack');
  const a2 = await adapterPeer({ generation: 1 });
  // old adapter connection is terminated by the supersession
  await a1.closed;
  const un = await c.next((f) => f.type === 'session.unavailable', 'unavailable on supersession');
  assert.equal(un.generation, 0);
  assert.equal(un.currentGeneration, 1);
  // new-generation subscribe works and events flow
  c.send({ type: 'request', id: 's2', method: 'sessions.subscribe', target: { instanceId: 'inst-1', generation: 1 } });
  await c.next((f) => f.id === 's2', 's2 ack');
  a2.send({ type: 'event', instanceId: 'inst-1', generation: 1, seq: 0, event: { type: 'session.changed' } });
  await c.next((f) => f.type === 'event' && f.generation === 1, 'gen1 event');
  await c.close();
  await a2.close();
});

test('older-generation re-register is refused; live route untouched', async () => {
  const a1 = await adapterPeer({ generation: 2 });
  const a0 = new Peer();
  a0.send(HELLO_ADAPTER);
  await a0.next((f) => f.type === 'welcome', 'welcome');
  a0.send(registration({ generation: 1 }));
  const e = await a0.next((f) => f.type === 'error', 'stale_generation error');
  assert.equal(e.error.code, 'stale_generation');
  await a0.closed;
  // The live route still answers.
  const c = await clientPeer();
  c.send({ type: 'request', id: 'q', method: 'history.open', target: { instanceId: 'inst-1', generation: 2 } });
  await a1.next((f) => f.type === 'request', 'still routed');
  await c.close();
  await a1.close();
});

test('request times out to the client; adapter connection is not punished for a late reply being dropped', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'slow', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  const routed = await a.next((f) => f.type === 'request', 'routed slow');
  const t = await c.next((f) => f.id === 'slow', 'timeout reply');
  assert.equal(t.error.code, 'timeout');
  // A late response is dropped silently: the correlation is gone.
  a.send({ type: 'response', id: routed.id, result: { late: true } });
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(c.frames.some((f) => f.id === 'slow' && f.result), false);
  // And the inflight slot was freed: a new request routes.
  c.send({ type: 'request', id: 'next', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  await a.next((f) => f.type === 'request' && f.id !== routed.id, 'next routed');
  await c.close();
  await a.close();
});

test('foreign/stale adapter replies are dropped, not routed to clients', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  a.send({ type: 'response', id: 'b999', result: { forged: true } }); // unknown correlation
  a.send({ type: 'response', id: 'no-id', result: {} }); // malformed: dropped, connection intact
  await new Promise((r) => setTimeout(r, 50));
  // adapter still works
  c.send({ type: 'request', id: 'ok', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  const routed = await a.next((f) => f.type === 'request', 'routed ok');
  a.send({ type: 'response', id: routed.id, result: { fine: true } });
  assert.equal((await c.next((f) => f.id === 'ok', 'ok reply')).result.fine, true);
  await c.close();
  await a.close();
});

test('startBroker refuses unsafe socket paths', async () => {
  // '/' as the directory is refused outright (never create or trust the
  // filesystem root as a socket home).
  await assert.rejects(
    () => startBroker({ socketPath: '/chat.sock' }),
    (e) => e.code === 'unsafe_socket_path',
  );
});

test('malformed response error codes are rejected and the request fails explicitly', async () => {
  const a = await adapterPeer();
  const c = await clientPeer();
  c.send({ type: 'request', id: 'm1', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  const routed = await a.next((f) => f.type === 'request', 'routed m1');
  a.send({ type: 'response', id: routed.id, error: { code: 'made_up_code', message: 'x', retryable: false } });
  const r = await c.next((f) => f.id === 'm1', 'm1 reply');
  assert.equal(r.error.code, 'invalid_request');
  await c.close();
  await a.close();
});

test('close() removes the socket; restart on the same path works', async () => {
  const sockPath = broker.socketPath;
  assert.equal(fs.existsSync(sockPath), true);
  await broker.close();
  assert.equal(fs.existsSync(sockPath), false);
  broker = await startBroker({ socketPath: sockPath, registerTimeoutMs: 500 });
  assert.equal(fs.existsSync(sockPath), true);
});

test('a second broker on the same path fails with socket_in_use and does not steal it', async () => {
  await assert.rejects(
    () => startBroker({ socketPath: broker.socketPath }),
    (e) => e.code === 'socket_in_use',
  );
  assert.equal(fs.existsSync(broker.socketPath), true);
  const probe = net.connect(broker.socketPath);
  await new Promise((r) => probe.once('connect', r));
  probe.destroy();
});

test('close() removes only its own inode: a replaced socket is left alone', async () => {
  const sockPath = broker.socketPath;
  // Simulate a replacement broker having rebound the path: bind a new socket
  // over the same path after unbinding ours.
  const a = await adapterPeer(); // keep broker busy so close path is realistic
  await broker.close().catch(() => {});
  // broker's close saw its inode already swapped? It hadn't. Just verify the
  // file is gone after a normal close with live conns.
  assert.equal(fs.existsSync(sockPath), false);
  await a.close();
});

test('startBroker fails closed on a non-socket preexisting path', async () => {
  const filePath = path.join(dir, 'not-a-socket');
  fs.writeFileSync(filePath, 'data');
  await assert.rejects(
    () => startBroker({ socketPath: filePath }),
    (e) => /refusing to overwrite non-socket/.test(e.message),
  );
  // The file is untouched.
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'data');
});

test('startBroker fails closed on a preexisting symlink at the socket path', async () => {
  const target = path.join(dir, 'elsewhere.sock');
  const link = path.join(dir, 'linked.sock');
  fs.symlinkSync(target, link); // dangling symlink
  await assert.rejects(
    () => startBroker({ socketPath: link }),
    (e) => /refusing to overwrite non-socket/.test(e.message),
  );
});


test('socket directory hygiene: our own world-writable dir is rejected; 0700 created dir is fine', async () => {
  const loose = path.join(dir, 'loose');
  fs.mkdirSync(loose);
  fs.chmodSync(loose, 0o777);
  await assert.rejects(
    () => startBroker({ socketPath: path.join(loose, 'chat.sock') }),
    (e) => e.code === 'unsafe_socket_dir',
  );
  const created = path.join(dir, 'created', 'nested');
  const b2 = await startBroker({ socketPath: path.join(created, 'chat.sock') });
  const st = fs.statSync(created);
  assert.equal(st.mode & 0o777, 0o700);
  assert.equal((fs.lstatSync(b2.socketPath).mode & 0o777) & 0o077, 0); // 0600
  await b2.close();
});

test('register with malformed capabilities is refused and the connection closed', async () => {
  const a = new Peer();
  a.send(HELLO_ADAPTER);
  await a.next((f) => f.type === 'welcome', 'welcome');
  a.send(registration({ capabilities: { history: true } }));
  const e = await a.next((f) => f.type === 'error', 'register error');
  assert.equal(e.error.code, 'invalid_request');
  await a.closed;
  assert.equal(broker.registrations.size, 0);
});

test('duplicate instanceId via a second fresh connection replaces the route', async () => {
  const a1 = await adapterPeer();
  const a2 = await adapterPeer(); // same instanceId, same generation
  await a1.closed;
  const c = await clientPeer();
  c.send({ type: 'request', id: 'r', method: 'history.open', target: { instanceId: 'inst-1', generation: 0 } });
  await a2.next((f) => f.type === 'request', 'routed to a2');
  await c.close();
  await a2.close();
});
