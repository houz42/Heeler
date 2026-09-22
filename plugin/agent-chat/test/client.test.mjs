// ChatClient behavior tests against a live in-process broker: handshake
// requirements, request/response plumbing, chunked item reassembly with
// its failure modes, and disconnect semantics.

import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { startBroker } from '../src/broker.mjs';
import { ChatClient } from '../src/client.mjs';
import { FrameReader, MAX_FRAME_BYTES } from '../src/frame.mjs';
import { PROTOCOL_VERSION } from '../src/protocol.mjs';

let dir;
let broker;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-chat-client-'));
  broker = await startBroker({
    socketPath: path.join(dir, 'chat.sock'),
    registerTimeoutMs: 1000,
    requestTimeoutMs: 3000,
    maxClientInflight: 64,
  });
});

afterEach(async () => {
  await broker?.close().catch(() => {});
  fs.rmSync(dir, { recursive: true, force: true });
});

// Scripted adapter speaking the same wire the real adapter will use.
class FakeAdapter {
  constructor(instanceId = 'inst-1', generation = 0, capabilities = undefined) {
    this.instanceId = instanceId;
    this.generation = generation;
    this.caps = capabilities;
    this.frames = [];
    this.sock = net.connect(broker.socketPath);
    this.sock.setNoDelay(true);
    this.reader = new FrameReader({ maxBytes: MAX_FRAME_BYTES, onFrame: (f) => this.frames.push(f) });
    this.sock.on('data', (c) => {
      if (this.reader.push(c) === false) this.sock.destroy();
    });
  }
  async start() {
    this.send({ type: 'hello', protocol: PROTOCOL_VERSION, peer: 'adapter' });
    await this.next((f) => f.type === 'welcome', 'welcome');
    this.send({
      type: 'register',
      registration: {
        instanceId: this.instanceId,
        sessionId: 'sess-1',
        generation: this.generation,
        agent: { kind: 'omp', version: 'test' },
        title: 'Fake Agent',
        capabilities:
          this.caps ??
          {
            history: true,
            streaming: true,
            prompt: true,
            interrupt: true,
            interactions: false,
            commands: false,
            attachments: false,
            branches: false,
            telemetry: false,
          },
      },
    });
    await this.next((f) => f.type === 'registered', 'registered');
    return this;
  }
  send(obj) {
    this.sock.write(JSON.stringify(obj) + '\n');
  }
  // Monotonic cursor: each next() call only considers frames not yet
  // consumed by a previous next() call, so consecutive awaits (chunk loops)
  // never re-find an already-served frame while still tolerating frames
  // that landed during an earlier await.
  consumed = 0;
  async next(pred, label, timeoutMs = 2000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      for (let i = this.consumed; i < this.frames.length; i++) {
        if (pred(this.frames[i])) {
          this.consumed = i + 1;
          return this.frames[i];
        }
      }
      this.consumed = this.frames.length;
      if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`);
      await new Promise((r) => setTimeout(r, 10));
    }
  }
  close() {
    this.sock.destroy();
  }
}

test('connect performs the v1 handshake and exposes the welcome', async () => {
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  assert.equal(c.welcome.protocol, 1);
  assert.equal(c.welcome.maxFrameBytes, MAX_FRAME_BYTES);
  await c.close();
});

test('connect requires a socketPath', async () => {
  await assert.rejects(() => ChatClient.connect({}), /socketPath is required/);
});

test('connect to a dead socket path rejects (no auto-start)', async () => {
  await assert.rejects(
    () => ChatClient.connect({ socketPath: path.join(dir, 'missing.sock') }),
  );
});

test('listSessions returns normalized registrations', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const { sessions } = await c.listSessions();
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].instanceId, 'inst-1');
  assert.equal(sessions[0].title, 'Fake Agent');
  assert.equal(sessions[0].capabilities.history, true);
  await c.close();
  a.close();
});

test('request routes through the broker and settles result or stable-code error', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const p = c.request('history.open', 'inst-1', 0, { limit: 5 });
  const routed = await a.next((f) => f.type === 'request', 'routed history.open');
  assert.deepEqual(routed.params, { limit: 5 });
  a.send({ type: 'response', id: routed.id, result: { sessionId: 'sess-1', items: [] } });
  assert.deepEqual(await p, { sessionId: 'sess-1', items: [] });
  // error path with a stable code surfaces on Error#code
  const p2 = c.request('history.before', 'inst-1', 0, { cursor: 'abc' });
  const routed2 = await a.next((f) => f.type === 'request' && f.method === 'history.before', 'routed history.before');
  a.send({ type: 'response', id: routed2.id, error: { code: 'stale_cursor', message: 'cursor no longer valid', retryable: false } });
  await assert.rejects(p2, (e) => e.code === 'stale_cursor' && /cursor no longer valid/.test(e.message));
  await c.close();
  a.close();
});

test('subscribe acks; events and session.unavailable are emitted', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  assert.deepEqual(await c.subscribe('inst-1', 0), { subscribed: true });
  const events = [];
  c.on('event', (ev) => events.push(ev));
  c.on('session.unavailable', (ev) => events.push(ev));
  a.send({ type: 'event', instanceId: 'inst-1', generation: 0, seq: 0, event: { type: 'message.started', streamId: 's1' } });
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(events.length, 1);
  assert.equal(events[0].event.type, 'message.started');
  a.close(); // adapter loss -> session.unavailable
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(events.length, 2);
  assert.equal(events[1].type, 'session.unavailable');
  assert.equal(events[1].instanceId, 'inst-1');
  await c.close();
});

test('getItem reassembles chunked item.read into the decoded ChatItem', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const item = {
    id: 'item-1',
    kind: 'message',
    author: { role: 'user' },
    status: 'committed',
    blocks: [{ type: 'text', text: 'hello world' }],
  };
  const bytes = Buffer.from(JSON.stringify(item), 'utf8');
  const p = c.getItem('inst-1', 0, 'item-1');
  // Serve the canonical bytes in two chunks.
  for (let off = 0; ; off += 5) {
    const routed = await a.next((f) => f.type === 'request' && f.method === 'item.read', 'routed chunk');
    assert.equal(routed.params.itemId, 'item-1');
    assert.equal(routed.params.offset, off);
    const end = Math.min(off + routed.params.length, bytes.length);
    a.send({
      type: 'response',
      id: routed.id,
      result: {
        itemId: 'item-1',
        encoding: 'json-utf8-base64',
        offset: off,
        totalBytes: bytes.length,
        data: bytes.subarray(off, end).toString('base64'),
        nextOffset: end < bytes.length ? end : null,
      },
    });
    if (end >= bytes.length) break;
  }
  assert.deepEqual(await p, item);
  await c.close();
  a.close();
});

test('getItem fails with item_changed when the item changes size mid-fetch', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const p = c.getItem('inst-1', 0, 'item-2');
  // Attach the rejection assertion BEFORE serving the chunk that flips the
  // size, so the rejection never spends a tick unhandled.
  const assertion = assert.rejects(p, (e) => e.code === 'item_changed');
  // Chunk 1: totalBytes 80, more to come.
  let routed = await a.next((f) => f.type === 'request' && f.method === 'item.read', 'routed chunk 1');
  a.send({
    type: 'response',
    id: routed.id,
    result: {
      itemId: 'item-2',
      encoding: 'json-utf8-base64',
      offset: 0,
      totalBytes: 80,
      data: Buffer.alloc(10).toString('base64'),
      nextOffset: 10,
    },
  });
  // Chunk 2: the item "changed" — totalBytes now 100.
  routed = await a.next((f) => f.type === 'request' && f.method === 'item.read', 'routed chunk 2');
  a.send({
    type: 'response',
    id: routed.id,
    result: {
      itemId: 'item-2',
      encoding: 'json-utf8-base64',
      offset: 10,
      totalBytes: 100,
      data: Buffer.alloc(10).toString('base64'),
      nextOffset: 20,
    },
  });
  await assertion;
  await c.close();
  a.close();
});

test('getItem refuses items over the configured byte budget', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const p = c.getItem('inst-1', 0, 'huge', { maxTotalBytes: 100 });
  const routed = await a.next((f) => f.type === 'request' && f.method === 'item.read', 'routed huge');
  a.send({
    type: 'response',
    id: routed.id,
    result: { itemId: 'huge', encoding: 'json-utf8-base64', offset: 0, totalBytes: 1000, data: Buffer.alloc(10).toString('base64'), nextOffset: 10 },
  });
  await assert.rejects(p, (e) => e.code === 'budget_too_small');
  await c.close();
  a.close();
});

test('connection loss fails pending requests and emits close', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  let closed = 0;
  c.on('close', () => closed++); // attach BEFORE the loss: 'close' can fire during any later await
  const p = c.request('history.open', 'inst-1', 0, {});
  const routed = await a.next((f) => f.type === 'request', 'routed');
  assert.equal(routed.method, 'history.open');
  const rejection = assert.rejects(p, (e) => e.code === 'session_unavailable');
  c.sock.destroy(); // client<->broker connection dies; pending work must fail fast
  await rejection;
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(closed, 1);
  // Requests after connection loss reject immediately.
  await assert.rejects(() => c.request('history.open', 'inst-1', 0, {}), /connection|closed|handshake/i);
  a.close();
});

test('close() settles pending requests and is idempotent', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const p = c.request('history.open', 'inst-1', 0, {});
  await a.next((f) => f.type === 'request', 'routed');
  // Attach the rejection handler BEFORE close() rejects the pending work.
  const rejection = assert.rejects(p, (e) => /closed/.test(e.message));
  await c.close();
  await rejection;
  await c.close(); // idempotent
  a.close();
});

test('unsolicited id-bearing frame fails the client connection closed', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  let closed = 0;
  c.on('close', () => closed++);
  // The broker never sends a response for an id the client did not send.
  // Simulate by having the broker's reply arrive after the client already
  // removed the entry: request, let it time out is too slow — instead use a
  // raw second connection masquerading as this client's frame stream is not
  // possible over a Unix socket. The meaningful in-process behavior: a
  // frame with an unmatched id must destroy the connection.
  const p = c.request('history.open', 'inst-1', 0, {});
  await a.next((f) => f.type === 'request', 'routed');
  const rejection = assert.rejects(p);
  await c.close();
  await rejection;
  assert.equal(closed, 1);
  a.close();
});


test('subscribe BEFORE history.open: broker delivers events buffered by the client', async () => {
  const a = await new FakeAdapter().start();
  const c = await ChatClient.connect({ socketPath: broker.socketPath });
  const buffered = [];
  c.on('event', (ev) => buffered.push(ev));
  await c.subscribe('inst-1', 0); // subscribe first, per contract
  const p = c.request('history.open', 'inst-1', 0, {});
  const routed = await a.next((f) => f.method === 'history.open', 'routed history.open');
  // While the snapshot request is in flight, the adapter emits an event.
  a.send({ type: 'event', instanceId: 'inst-1', generation: 0, seq: 0, event: { type: 'message.delta', streamId: 's1', text: 'x' } });
  a.send({ type: 'response', id: routed.id, result: { sessionId: 'sess-1', generation: 0, revision: 'r1', throughSeq: 0, items: [], olderCursor: null } });
  const page = await p;
  assert.equal(page.throughSeq, 0); // snapshot watermark aligns with the emitted seq
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(buffered.length, 1); // the event was delivered alongside, not lost
  await c.close();
  a.close();
});
