// Protocol v1 validator boundary tests: strictness where the contract
// demands it, opaqueness where it promises passthrough.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PROTOCOL_VERSION,
  ERROR_CODES,
  MAX_FRAME_BYTES,
  CAPABILITY_KEYS,
  CLIENT_METHODS,
  METHOD_CAPABILITIES,
  validateHelloPeer,
  validateWelcomeFrame,
  validateRegisterFrame,
  validateRequestFrame,
  validateResponseFrame,
  validateEventFrame,
  validateSessionUnavailableFrame,
} from '../src/protocol.mjs';

const reg = (over = {}) => ({
  type: 'register',
  registration: {
    instanceId: 'inst-1',
    sessionId: 'sess-1',
    generation: 0,
    agent: { kind: 'omp', version: '1.0' },
    capabilities: {
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
    ...over,
  },
});

test('hello: exact protocol and peer values only', () => {
  assert.deepEqual(validateHelloPeer({ type: 'hello', protocol: 1, peer: 'client' }), {
    ok: true,
    value: { type: 'hello', protocol: 1, peer: 'client' },
  });
  // unknown protocol fails closed
  assert.equal(validateHelloPeer({ type: 'hello', protocol: 2, peer: 'client' }).code, 'unsupported_protocol');
  assert.equal(validateHelloPeer({ type: 'hello', protocol: 1, peer: 'agent' }).code, 'invalid_request');
  assert.equal(validateHelloPeer(null).code, 'unsupported_protocol');
  assert.equal(validateHelloPeer('hello').code, 'unsupported_protocol');
});

test('welcome: only the exact maxFrameBytes is valid', () => {
  assert.equal(validateWelcomeFrame({ type: 'welcome', protocol: 1, maxFrameBytes: MAX_FRAME_BYTES }).ok, true);
  assert.equal(validateWelcomeFrame({ type: 'welcome', protocol: 1, maxFrameBytes: 512 }).ok, false);
  assert.equal(validateWelcomeFrame({ type: 'welcome', protocol: 2, maxFrameBytes: MAX_FRAME_BYTES }).ok, false);
});

test('register: all capability booleans required, extra keys rejected per-key', () => {
  assert.equal(validateRegisterFrame(reg()).ok, true);
  const missing = reg();
  delete missing.registration.capabilities.interactions;
  assert.equal(validateRegisterFrame(missing).code, 'invalid_request');
  const nonBool = reg();
  nonBool.registration.capabilities.history = 1;
  assert.equal(validateRegisterFrame(nonBool).code, 'invalid_request');
  // generation must be a non-negative integer
  assert.equal(validateRegisterFrame(reg({ generation: -1 })).code, 'invalid_request');
  assert.equal(validateRegisterFrame(reg({ generation: 1.5 })).code, 'invalid_request');
  assert.equal(validateRegisterFrame(reg({ instanceId: '' })).code, 'invalid_request');
  // locator is opaque: any plain object passes, contents never inspected
  const withLocator = reg({ locator: { paneId: 'w1:pA', sessionFile: '/x/y', anything: [1, 2] } });
  assert.equal(validateRegisterFrame(withLocator).ok, true);
  assert.equal(validateRegisterFrame(reg({ locator: 'not-an-object' })).code, 'invalid_request');
});

test('register: validated value drops unknown properties', () => {
  const v = validateRegisterFrame(
    reg({
      extra: 'dropped',
      agent: { kind: 'omp', version: '1', hacked: true },
    }),
  );
  assert.equal(v.ok, true);
  assert.equal('extra' in v.value.registration, false);
  assert.equal('hacked' in v.value.registration.agent, false);
  // capabilities copy carries exactly the contract keys
  assert.deepEqual(Object.keys(v.value.registration.capabilities).sort(), [...CAPABILITY_KEYS].sort());
});

test('request: target shape, params passthrough', () => {
  assert.equal(
    validateRequestFrame({ type: 'request', id: 'b1', method: 'history.open', target: { instanceId: 'i', generation: 3 }, params: { limit: 10 } }).ok,
    true,
  );
  assert.equal(validateRequestFrame({ type: 'request', id: 'b1', method: 'x' }).ok, true); // target optional in envelope
  assert.equal(validateRequestFrame({ type: 'request', method: 'x' }).code, 'invalid_request');
  assert.equal(validateRequestFrame({ type: 'request', id: 'b1', method: 'x', params: [1] }).code, 'invalid_request');
  assert.equal(
    validateRequestFrame({ type: 'request', id: 'b1', method: 'x', target: { instanceId: 'i', generation: -1 } }).code,
    'invalid_request',
  );
});

test('response: stable error codes only, retryable required', () => {
  assert.equal(validateResponseFrame({ type: 'response', id: 'b1', result: { x: 1 } }).ok, true);
  assert.equal(validateResponseFrame({ type: 'response', id: 'b1', error: { code: 'timeout', message: 'm', retryable: true } }).ok, true);
  // foreign error codes are rejected — clients can rely on the stable set
  assert.equal(validateResponseFrame({ type: 'response', id: 'b1', error: { code: 'whatever', message: 'm', retryable: false } }).code, 'invalid_request');
  assert.equal(validateResponseFrame({ type: 'response', id: 'b1', error: { code: 'timeout', message: 'm' } }).code, 'invalid_request');
  assert.equal(validateResponseFrame({ type: 'response', id: 'b1' }).code, 'invalid_request');
  assert.equal(validateResponseFrame({ type: 'response', id: 'b1', result: 1, error: { code: 'timeout', message: 'm', retryable: false } }).code, 'invalid_request');
});

test('event: seq non-negative integer, event needs a type', () => {
  assert.equal(validateEventFrame({ type: 'event', instanceId: 'i', generation: 0, seq: 0, event: { type: 'message.started' } }).ok, true);
  assert.equal(validateEventFrame({ type: 'event', instanceId: 'i', generation: 0, seq: -1, event: { type: 'x' } }).code, 'invalid_request');
  assert.equal(validateEventFrame({ type: 'event', instanceId: 'i', generation: 0, seq: 1.5, event: { type: 'x' } }).code, 'invalid_request');
  assert.equal(validateEventFrame({ type: 'event', instanceId: 'i', generation: 0, seq: 1, event: {} }).code, 'invalid_request');
  // event payload itself is opaque — any extra fields pass
  assert.equal(
    validateEventFrame({ type: 'event', instanceId: 'i', generation: 0, seq: 1, event: { type: 'message.delta', streamId: 's', anything: null } }).ok,
    true,
  );
});

test('constants: capability/method surfaces stay coherent', () => {
  assert.equal(PROTOCOL_VERSION, 1);
  assert.equal(MAX_FRAME_BYTES, 1024 * 1024);
  // every routed method's required capability is a declared capability key
  for (const cap of Object.values(METHOD_CAPABILITIES)) {
    assert.ok(CAPABILITY_KEYS.includes(cap), `unknown capability ${cap}`);
  }
  // broker-handled methods plus routed ones enumerate the whole surface
  assert.deepEqual([...CLIENT_METHODS].sort(), [
    ...new Set(['sessions.list', 'sessions.subscribe', ...Object.keys(METHOD_CAPABILITIES)]),
  ].sort());
  assert.ok(ERROR_CODES.includes('stale_generation'));
  assert.ok(ERROR_CODES.includes('too_many_inflight'));
  assert.equal(validateSessionUnavailableFrame({ type: 'session.unavailable', instanceId: 'i', generation: 1 }).ok, true);
  assert.equal(validateSessionUnavailableFrame({ type: 'session.unavailable', instanceId: 'i', generation: -1 }).code, 'invalid_request');
});
