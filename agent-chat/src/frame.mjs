// Shared NDJSON framing for the agent-chat broker protocol v1.
//
// One JSON document per line, terminated by a single LF (0x0a). A frame is
// capped at `maxBytes` UTF-8 bytes INCLUDING the LF. Strict UTF-8: bytes
// that decode with replacement characters (lone surrogates, overlongs,
// truncated sequences spanning a chunk boundary) fail the connection —
// never silently corrupted text. push() returns false when the peer must
// be dropped (oversized frame, undecodable JSON, non-UTF-8, non-object
// document); fail closed — there is no partial-frame recovery.
//
// Transport-agnostic: only Node's Buffer, no socket, protocol, or
// API-specific types. Usable by any NDJSON-over-stream peer.

import { MAX_FRAME_BYTES } from './protocol.mjs';

export { MAX_FRAME_BYTES };

export class FrameReader {
  // opts: {maxBytes?: number, onFrame: (obj: object) => boolean|void}
  // onFrame returning false aborts parsing and fails the connection.
  constructor({ maxBytes = MAX_FRAME_BYTES, onFrame }) {
    if (!Number.isInteger(maxBytes) || maxBytes <= 0) throw new TypeError('maxBytes must be a positive integer');
    if (typeof onFrame !== 'function') throw new TypeError('onFrame must be a function');
    this.maxBytes = maxBytes;
    this.onFrame = onFrame;
    this.buf = Buffer.alloc(0);
  }

  // Feed a received chunk; returns false when the connection must be dropped.
  push(chunk) {
    if (!Buffer.isBuffer(chunk)) return false;
    if (chunk.length === 0) return this.buf.length === 0;
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
    if (this.buf.length > this.maxBytes && !this.buf.includes(0x0a)) return false;
    for (;;) {
      const nl = this.buf.indexOf(0x0a);
      if (nl === -1) break;
      const line = this.buf.subarray(0, nl); // LF excluded from content cap
      this.buf = this.buf.subarray(nl + 1);
      if (line.length === 0) continue; // tolerate stray blank lines
      let obj;
      try {
        obj = JSON.parse(decodeStrictUtf8(line));
      } catch {
        return false;
      }
      if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) return false;
      if (this.onFrame(obj) === false) return false;
    }
    // A line still assembling must fit the cap (LF included): a frame may
    // deliver no LF for maxBytes bytes before it is rejected.
    return this.buf.length < this.maxBytes;
  }
}

// Strict UTF-8 decode: throws on any invalid sequence instead of emitting
// U+FFFD replacement characters.
function decodeStrictUtf8(buf) {
  const s = buf.toString('utf8');
  return s.includes('\ufffd') ? badUtf8(buf) : s;
}

function badUtf8() {
  throw new Error('invalid UTF-8');
}
