// Client library for the agent-chat broker protocol v1.
//
//   import { ChatClient } from 'agent-chat/src/client.mjs';
//   const c = await ChatClient.connect({ socketPath });
//   const { sessions } = await c.listSessions();
//   await c.subscribe(instanceId, generation);   // subscribe BEFORE history.open; buffer events
//   const page = await c.request('history.open', instanceId, generation, { limit });
//   const item = await c.getItem(instanceId, generation, itemId);  // reassembles item.read chunks
//   c.on('event', (ev) => { ... });   // {type:'event',instanceId,generation,seq,event}
//   c.on('session.unavailable', (ev) => { ... }); // resubscribe + reopen snapshot
//   c.on('close', () => { ... });    // any lost connection: old state is void
//   await c.close();
//
// The library keeps each request's rejector so close()/connection loss can
// fail in-flight work fast instead of hanging on a dying socket. Requests
// carry the broker's stable error codes on Error#code.

import net from 'node:net';
import { EventEmitter } from 'node:events';
import { FrameReader, MAX_FRAME_BYTES } from './frame.mjs';
import { PROTOCOL_VERSION } from './protocol.mjs';

const CONNECT_TIMEOUT_MS = num('AGENT_CHAT_CONNECT_TIMEOUT_MS', 5000);
const REQUEST_TIMEOUT_MS = num('AGENT_CHAT_REQUEST_TIMEOUT_MS', 30_000);
// Bound on a reassembled item/blob's totalBytes; anything larger is refused
// rather than buffered (the wire max frame is 1 MiB per chunk).
const ITEM_MAX_TOTAL_BYTES = num('AGENT_CHAT_ITEM_MAX_TOTAL_BYTES', 64 * 1024 * 1024);

function num(name, dflt) {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : dflt;
}

function err(code, message) {
  return Object.assign(new Error(message), { code });
}

export class ChatClient extends EventEmitter {
  sock = null;
  pending = new Map(); // id -> {resolve, reject, timer}
  reader = null;
  idSeq = 0;
  closed = false;
  welcome = null; // broker {type:'welcome',protocol,maxFrameBytes} ack

  static async connect(opts = {}) {
    const p = opts.socketPath;
    if (typeof p !== 'string' || p === '') throw err('invalid_request', 'socketPath is required');
    const connectTimeoutMs = opts.connectTimeoutMs ?? CONNECT_TIMEOUT_MS;
    const sock = net.connect(p);
    sock.setNoDelay(true);
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        sock.destroy();
        reject(err('timeout', `connect timeout to ${p}`));
      }, connectTimeoutMs);
      sock.once('connect', () => {
        clearTimeout(t);
        resolve();
      });
      sock.once('error', (e) => {
        clearTimeout(t);
        reject(e);
      });
    });
    const c = new ChatClient();
    c.sock = sock;
    c.attach(sock);
    // Wire v1 hello: the broker must acknowledge with protocol 1.
    const welcome = await c.callHandshake({ type: 'hello', protocol: PROTOCOL_VERSION, peer: 'client' });
    c.welcome = welcome;
    c.connected = true;
    return c;
  }

  attach(sock) {
    this.reader = new FrameReader({
      maxBytes: MAX_FRAME_BYTES,
      onFrame: (f) => this.onFrame(f),
    });
    sock.on('data', (chunk) => {
      if (this.reader.push(chunk) === false) {
        // Oversized/undecodable/non-UTF-8 frame: protocol is broken; fail everything.
        this.reader = null;
        sock.destroy();
      }
    });
    sock.on('error', () => {}); // surfaced via 'close'
    sock.on('close', () => this.onClose());
  }

  // Any lost connection immediately fails every pending request and emits
  // 'close'; callers must resubscribe + reopen — old-generation state is void.
  onClose() {
    this.connected = false;
    this.failAll('session_unavailable', 'broker connection closed');
    this.emit('close');
  }

  failAll(code, message) {
    for (const [, { timer, reject }] of this.pending) {
      clearTimeout(timer);
      reject(err(code, message));
    }
    this.pending.clear();
  }

  onFrame(f) {
    if (!this.welcome) {
      // Handshake phase: only the welcome ack or a handshake error is valid.
      const hs = this.pending.get('hello');
      if (hs && f.type === 'welcome' && f.protocol === PROTOCOL_VERSION && Number.isInteger(f.maxFrameBytes)) {
        this.pending.delete('hello');
        clearTimeout(hs.timer);
        hs.resolve(f);
        return;
      }
      if (hs && f.type === 'error' && f.error && typeof f.error === 'object') {
        this.pending.delete('hello');
        clearTimeout(hs.timer);
        hs.reject(err(f.error.code || 'unsupported_protocol', f.error.message || 'broker rejected handshake'));
        return;
      }
      this.sock.destroy(); // no other frames are valid before welcome
      return;
    }
    const req = f.id !== undefined ? this.pending.get(f.id) : undefined;
    if (req) {
      this.pending.delete(f.id);
      clearTimeout(req.timer);
      if (f.error) req.reject(err(f.error.code || 'internal_error', f.error.message || 'broker error'));
      else req.resolve(f.result);
      return;
    }
    if (f.type === 'event' || f.type === 'session.unavailable') return this.emit(f.type, f);
    // Anything else after handshake: unmatched id / unknown frame. A broker
    // never sends unsolicited id-bearing frames — fail closed, drop the
    // connection, never half-live.
    this.sock.destroy();
  }

  // Handshake exchange — resolved by the welcome frame.
  callHandshake(obj) {
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, timer: null };
      entry.timer = setTimeout(() => {
        this.pending.delete('hello');
        reject(err('timeout', 'timeout: no broker welcome'));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set('hello', entry);
      this.sock.write(JSON.stringify(obj) + '\n', (e) => {
        if (e) {
          this.pending.delete('hello');
          clearTimeout(entry.timer);
          reject(e);
        }
      });
    });
  }
  call(obj) {
    if (this.closed) return Promise.reject(err('invalid_request', 'client is closed'));
    if (!this.welcome) return Promise.reject(err('invalid_request', 'client handshake not completed'));
    if (this.connected === false || (this.sock && this.sock.destroyed)) {
      return Promise.reject(err('session_unavailable', 'broker connection closed'));
    }
    const id = `c${++this.idSeq}`;
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, timer: null };
      entry.timer = setTimeout(() => {
        this.pending.delete(id);
        reject(err('timeout', `timeout: no reply to ${obj.method ?? obj.type} (id ${id})`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, entry);
      try {
        this.sock.write(JSON.stringify({ ...obj, id }) + '\n');
      } catch (e) {
        this.pending.delete(id);
        clearTimeout(entry.timer);
        reject(e);
      }
    });
  }

  // --- client methods (contract method names) ------------------------------

  listSessions() {
    return this.call({ type: 'request', method: 'sessions.list' });
  }

  subscribe(instanceId, generation) {
    return this.call({ type: 'request', method: 'sessions.subscribe', target: { instanceId, generation } });
  }

  request(method, instanceId, generation, params) {
    return this.call({ type: 'request', method, target: { instanceId, generation }, ...(params !== undefined && { params }) });
  }

  // Reassemble a chunked canonical-item/blob fetch into raw bytes.
  // item.read: replies echo `itemId`, encoding 'json-utf8-base64' (the
  // bytes are the canonical ChatItem JSON). blob.read: replies echo
  // `blobId`, encoding 'raw-base64' (raw blob bytes, e.g. an image).
  // Bounded: totalBytes capped by maxTotalBytes; offset regressions, size
  // changes, and short deliveries throw (never silently truncate).
  async readChunked(method, instanceId, generation, { itemId, offset = 0, chunkLength = 65536, maxTotalBytes = ITEM_MAX_TOTAL_BYTES }) {
    const isItem = method === 'item.read';
    const idField = isItem ? 'itemId' : 'blobId';
    const expectedEncoding = isItem ? 'json-utf8-base64' : 'raw-base64';
    const params = isItem ? { itemId, offset, length: chunkLength } : { blobId: itemId, offset, length: chunkLength };
    let totalBytes = null;
    const parts = [];
    let received = 0;
    let at = offset;
    for (;;) {
      const res = await this.request(method, instanceId, generation, { ...params, offset: at });
      if (
        !res ||
        res[idField] !== itemId ||
        res.encoding !== expectedEncoding ||
        !Number.isInteger(res.offset) ||
        res.offset !== at ||
        !Number.isInteger(res.totalBytes) ||
        res.totalBytes < 0 ||
        typeof res.data !== 'string' ||
        (res.nextOffset !== null && res.nextOffset !== undefined && !Number.isInteger(res.nextOffset))
      ) {
        throw err('item_changed', `malformed chunk from ${method} for ${itemId}`);
      }
      if (totalBytes === null) {
        totalBytes = res.totalBytes;
        if (totalBytes > maxTotalBytes) {
          throw err('budget_too_small', `${itemId} is ${totalBytes} bytes, over the ${maxTotalBytes} byte limit`);
        }
      } else if (res.totalBytes !== totalBytes) {
        throw err('item_changed', `${itemId} changed size mid-fetch`);
      }
      let buf;
      try {
        buf = Buffer.from(res.data, 'base64');
      } catch {
        throw err('item_changed', `chunk for ${itemId} is not valid base64`);
      }
      received += buf.length;
      if (received > totalBytes) {
        throw err('item_changed', `${itemId} delivered more bytes than advertised`);
      }
      parts.push(buf);
      if (res.nextOffset == null) break;
      if (res.nextOffset <= at) {
        throw err('item_changed', `chunk for ${itemId} made no forward progress`);
      }
      at = res.nextOffset;
    }
    if (received !== totalBytes) {
      throw err('item_changed', `${itemId} incomplete: got ${received} of ${totalBytes} bytes`);
    }
    return { itemId, offset, totalBytes, bytes: Buffer.concat(parts) };
  }

  // Fetch a full ChatItem by id: reassembles item.read chunks and JSON-decodes
  // the canonical bytes. Throws Error#code item_changed if the item's
  // revision changes mid-fetch (caller must refetch from scratch).
  async getItem(instanceId, generation, itemId, opts = {}) {
    const { bytes } = await this.readChunked('item.read', instanceId, generation, { itemId, ...opts });
    try {
      return JSON.parse(bytes.toString('utf8'));
    } catch {
      throw err('item_changed', `${itemId} bytes are not valid JSON`);
    }
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.failAll('invalid_request', 'client closed');
    const sock = this.sock;
    if (sock && !sock.destroyed) {
      sock.end();
      await new Promise((r) => {
        sock.once('close', r);
        setTimeout(r, 2000); // don't hang on a wedged peer
      });
    }
  }
}
