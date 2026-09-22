// FrameReader boundary tests: chunking, caps, strict UTF-8, fail-closed.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FrameReader, MAX_FRAME_BYTES } from '../src/frame.mjs';

function collect() {
  const frames = [];
  const r = new FrameReader({ onFrame: (f) => frames.push(f) });
  return { r, frames };
}

test('one JSON document per LF, arbitrary chunk splits', () => {
  const { r, frames } = collect();
  const wire = Buffer.concat([
    Buffer.from('{"a":1}\n'),
    Buffer.from('{"b'),
    Buffer.from('":2,"c":'),
    Buffer.from('"x"}\n\n{"d":3}\n'),
  ]);
  assert.equal(r.push(wire), true);
  assert.deepEqual(frames, [{ a: 1 }, { b: 2, c: 'x' }, { d: 3 }]);
});

test('onFrame returning false aborts and fails the connection', () => {
  let calls = 0;
  const r = new FrameReader({
    onFrame: () => (calls++ === 0 ? undefined : false),
  });
  assert.equal(r.push(Buffer.from('{}\n{}\n')), false);
  assert.equal(calls, 2);
  // A dropped connection stays dropped: further input is ignored.
  assert.equal(r.push(Buffer.from('{}\n')), false);
});

test('oversized frame fails closed (line content and pending-line caps)', () => {
  const small = new FrameReader({ maxBytes: 64, onFrame: () => {} });
  assert.equal(small.push(Buffer.alloc(32).fill('a')), true); // assembling, under cap
  assert.equal(small.push(Buffer.alloc(8).fill('b')), true); // still no LF, 40 bytes < 64
  assert.equal(small.push(Buffer.alloc(40).fill('c')), false); // 80 bytes with no LF: over cap
  // A single line over the cap fails even when it contains the LF.
  const small2 = new FrameReader({ maxBytes: 64, onFrame: () => {} });
  const over = Buffer.alloc(64 + 20).fill('a');
  over[over.length - 1] = 0x0a;
  assert.equal(small2.push(over), false);
  // Exactly at the cap INCLUDING the LF is fine.
  const edge = new FrameReader({ maxBytes: 8, onFrame: () => {} });
  assert.equal(edge.push(Buffer.from('{"a":1}\n')), true); // 8 bytes incl LF
});

test('strict UTF-8: lone continuation byte inside a JSON line fails', () => {
  const r = new FrameReader({ onFrame: () => {} });
  // {"a":"<0x80>"}
  assert.equal(r.push(Buffer.from([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x80, 0x7d, 0x0a])), false);
});
test('undecodable JSON and non-object documents fail closed', () => {
  const { r } = collect();
  assert.equal(r.push(Buffer.from('not json\n')), false);
  const r2 = new FrameReader({ onFrame: () => {} });
  assert.equal(r2.push(Buffer.from('[1,2]\n')), false); // arrays are not frames
  const r3 = new FrameReader({ onFrame: () => {} });
  assert.equal(r3.push(Buffer.from('null\n')), false);
  const r4 = new FrameReader({ onFrame: () => {} });
  assert.equal(r4.push(Buffer.from('42\n')), false);
});

test('valid multibyte UTF-8 payloads round-trip', () => {
  const { r, frames } = collect();
  const obj = { text: 'héllo — 中文 🎉' };
  assert.equal(r.push(Buffer.from(JSON.stringify(obj) + '\n', 'utf8')), true);
  assert.deepEqual(frames, [obj]);
  // 4-byte emoji split across chunks assembles correctly.
  const { r: r2, frames: frames2 } = collect();
  const wire = Buffer.from(JSON.stringify({ e: '🚀' }) + '\n', 'utf8');
  const cut = wire.indexOf(0x9f);
  assert.equal(r2.push(wire.subarray(0, cut)), true);
  assert.equal(r2.push(wire.subarray(cut)), true);
  assert.deepEqual(frames2, [{ e: '🚀' }]);
});

test('invalid UTF-8 in a completed frame fails closed', () => {
  const r = new FrameReader({ onFrame: () => {} });
  // {"a":"<0x80>"} — invalid continuation byte inside a complete line.
  assert.equal(r.push(Buffer.from([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0x80, 0x22, 0x7d, 0x0a])), false);
  // Invalid byte in the TAIL after a complete line: the complete line is
  // delivered, then the tail fails once shown invalid.
  const seen = [];
  const r2 = new FrameReader({ onFrame: (f) => seen.push(f) });
  assert.equal(r2.push(Buffer.concat([Buffer.from('{"a":1}\n'), Buffer.from([0x80, 0x0a])])), false);
  assert.deepEqual(seen, [{ a: 1 }]);
});

test('non-Buffer input is rejected without touching state', () => {
  const r = new FrameReader({ onFrame: () => {} });
  assert.equal(r.push('not a buffer'), false);
  assert.equal(r.push(null), false);
});

test('constructor validates its arguments', () => {
  assert.throws(() => new FrameReader({}), /onFrame/);
  assert.throws(() => new FrameReader({ maxBytes: 0, onFrame: () => {} }), /maxBytes/);
  assert.throws(() => new FrameReader({ maxBytes: 10.5, onFrame: () => {} }), /maxBytes/);
  // default maxBytes is the protocol cap
  const r = new FrameReader({ onFrame: () => {} });
  assert.equal(r.maxBytes, MAX_FRAME_BYTES);
});
