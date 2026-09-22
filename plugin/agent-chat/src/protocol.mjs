// Wire protocol v1 for the agent-chat broker (contract: local://agent-chat-v1-contract.md).
//
// Pure validators and constants only — no I/O, no transport types, no
// ChatItem knowledge beyond the shapes this module must enforce at the
// runtime boundary. Consumers: broker.mjs (server-side boundary),
// client.mjs (client-side boundary), adapters (registration frames).
//
// Validation style: every validate* returns {ok:true, value} with a
// defensively-copied plain object (foreign input is never trusted by
// reference — prototypes and unexpected properties are dropped), or
// {ok:false, code, message} with a stable contract error code. Validators
// are strict about types but lenient about UNKNOWN properties: the peer
// may add fields; the broker routes only validated envelope fields and
// passes opaque params through untouched. Params payloads are validated
// by the adapter, not here.

export const PROTOCOL_VERSION = 1;

/** Inclusive cap for one frame INCLUDING its terminating LF byte. */
export const MAX_FRAME_BYTES = 1024 * 1024;

// Stable error codes (contract). The broker never invents others, so
// clients and adapters can switch on them.
export const ERROR_CODES = Object.freeze([
  'invalid_request',
  'unsupported_protocol',
  'unsupported_capability',
  'session_unavailable',
  'ambiguous_session',
  'stale_generation',
  'stale_cursor',
  'cursor_invalid',
  'item_not_found',
  'item_changed',
  'budget_too_small',
  'too_many_inflight',
  'overloaded',
  'timeout',
  'internal_error',
]);

export function isErrorCode(code) {
  return typeof code === 'string' && ERROR_CODES.includes(code);
}

// Capability keys a registration must declare (all required, all boolean).
export const CAPABILITY_KEYS = Object.freeze([
  'history',
  'streaming',
  'prompt',
  'interrupt',
  'interactions',
  'commands',
  'attachments',
  'branches',
  'telemetry',
]);

// Client methods the broker routes after registration checks, and the
// capability bit each requires. Methods not listed here are rejected with
// invalid_request before any routing (the broker is not a generic proxy).
// sessions.list / sessions.subscribe are handled by the broker itself.
export const METHOD_CAPABILITIES = Object.freeze({
  'history.open': 'history',
  'history.before': 'history',
  'item.read': 'history',
  'blob.read': 'history',
  'prompt.send': 'prompt',
  interrupt: 'interrupt',
  'commands.list': 'commands',
  'interactions.list': 'interactions',
  'interactions.answer': 'interactions',
  'interactions.cancel': 'interactions',
  // v2 (slice 1, agent details): telemetry capability gates the agent's
  // live context/model reporting and explicit model changes.
  'session.telemetry': 'telemetry',
  'models.list': 'telemetry',
  'model.set': 'telemetry',
});

export const CLIENT_METHODS = Object.freeze([
  'sessions.list',
  'sessions.subscribe',
  ...Object.keys(METHOD_CAPABILITIES),
]);

// ---------------------------------------------------------------------------
// primitives

function isStr(v) {
  return typeof v === 'string' && v.length > 0;
}

function isPlain(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function fail(code, message) {
  return { ok: false, code, message };
}

/** Accept only finite integers in [0, safeMax]. */
function isCount(v, safeMax = Number.MAX_SAFE_INTEGER) {
  return Number.isInteger(v) && v >= 0 && v <= safeMax;
}

function pick(src, keys) {
  const out = {};
  for (const k of keys) if (src[k] !== undefined) out[k] = src[k];
  return out;
}

// ---------------------------------------------------------------------------

export function validateHelloPeer(f) {
  if (!isPlain(f) || f.type !== 'hello' || f.protocol !== PROTOCOL_VERSION) {
    return fail(
      'unsupported_protocol',
      `expected {type:'hello',protocol:${PROTOCOL_VERSION},peer:'client'|'adapter'}`,
    );
  }
  if (f.peer !== 'client' && f.peer !== 'adapter') {
    return fail('invalid_request', "hello.peer must be 'client' or 'adapter'");
  }
  return { ok: true, value: { type: 'hello', protocol: PROTOCOL_VERSION, peer: f.peer } };
}

export function validateWelcomeFrame(f) {
  if (
    !isPlain(f) ||
    f.type !== 'welcome' ||
    f.protocol !== PROTOCOL_VERSION ||
    !isCount(f.maxFrameBytes, MAX_FRAME_BYTES) ||
    f.maxFrameBytes !== MAX_FRAME_BYTES
  ) {
    return fail('invalid_request', 'malformed welcome frame');
  }
  return { ok: true, value: { type: 'welcome', protocol: PROTOCOL_VERSION, maxFrameBytes: f.maxFrameBytes } };
}

function validateCapabilities(f) {
  const caps = f.capabilities;
  if (!isPlain(caps)) return { ok: false };
  for (const key of CAPABILITY_KEYS) {
    if (typeof caps[key] !== 'boolean') return { ok: false };
  }
  return { ok: true, value: pick(caps, CAPABILITY_KEYS) };
}

// register: {type:'register', registration:{instanceId,sessionId,generation,
//   agent:{kind,version}, title?, locator?, capabilities:{...8 booleans}}}
export function validateRegisterFrame(f) {
  if (!isPlain(f) || f.type !== 'register') {
    return fail('invalid_request', "expected {type:'register',registration:{...}}");
  }
  const r = f.registration;
  if (
    !isPlain(r) ||
    !isStr(r.instanceId) ||
    !isStr(r.sessionId) ||
    !Number.isInteger(r.generation) ||
    r.generation < 0 ||
    !isPlain(r.agent) ||
    !isStr(r.agent.kind) ||
    typeof r.agent.version !== 'string' ||
    (r.title !== undefined && typeof r.title !== 'string') ||
    (r.locator !== undefined && !isPlain(r.locator))
  ) {
    return fail('invalid_request', 'malformed registration');
  }
  const caps = validateCapabilities(r);
  if (!caps.ok) {
    return fail('invalid_request', `registration.capabilities requires all boolean keys: ${CAPABILITY_KEYS.join(', ')}`);
  }
  // locator is discovery-only opaque metadata: copied by reference, never
  // parsed here or by the broker beyond this existence/type check.
  const value = {
    type: 'register',
    registration: {
      instanceId: r.instanceId,
      sessionId: r.sessionId,
      generation: r.generation,
      agent: { kind: r.agent.kind, version: r.agent.version },
      ...(r.title !== undefined && { title: r.title }),
      ...(r.locator !== undefined && { locator: r.locator }),
      capabilities: caps.value,
    },
  };
  return { ok: true, value };
}

export function validateRegisteredFrame(f) {
  if (!isPlain(f) || f.type !== 'registered' || !isStr(f.instanceId) || !Number.isInteger(f.generation) || f.generation < 0) {
    return fail('invalid_request', 'malformed registered frame');
  }
  return { ok: true, value: { type: 'registered', instanceId: f.instanceId, generation: f.generation } };
}

// request: {type:'request', id, method, target?:{instanceId,generation}, params?:object}
// (broker->adapter always carries target; a client omitting target is the
// broker's ambiguity concern, validated in broker.mjs, not here)
export function validateRequestFrame(f) {
  if (
    !isPlain(f) ||
    f.type !== 'request' ||
    !isStr(f.id) ||
    !isStr(f.method) ||
    (f.params !== undefined && !isPlain(f.params))
  ) {
    return fail('invalid_request', "expected {type:'request',id,method,target?,params?}");
  }
  if (f.target !== undefined) {
    if (!isPlain(f.target) || !isStr(f.target.instanceId) || !Number.isInteger(f.target.generation) || f.target.generation < 0) {
      return fail('invalid_request', 'request.target requires instanceId and integer generation>=0');
    }
  }
  const value = {
    type: 'request',
    id: f.id,
    method: f.method,
    ...(f.target !== undefined && { target: { instanceId: f.target.instanceId, generation: f.target.generation } }),
    ...(f.params !== undefined && { params: f.params }),
  };
  return { ok: true, value };
}

// response: {type:'response', id, result} OR {type:'response', id, error:{code,message,retryable}}
// The error code must be a stable contract code so clients can branch on it.
export function validateResponseFrame(f) {
  if (!isPlain(f) || f.type !== 'response' || !isStr(f.id)) {
    return fail('invalid_request', "expected {type:'response',id,result|error}");
  }
  if ('error' in f && 'result' in f) {
    return fail('invalid_request', 'response carries both result and error');
  }
  if ('error' in f) {
    const e = f.error;
    if (!isPlain(e) || !isErrorCode(e.code) || typeof e.message !== 'string' || typeof e.retryable !== 'boolean') {
      return fail(
        'invalid_request',
        `response.error requires {code:<stable contract code>,message,retryable:boolean}`,
      );
    }
    return { ok: true, value: { type: 'response', id: f.id, error: { code: e.code, message: e.message, retryable: e.retryable } } };
  }
  if ('result' in f) return { ok: true, value: { type: 'response', id: f.id, result: f.result } };
  return fail('invalid_request', 'response carries neither result nor error');
}

// event: {type:'event', instanceId, generation, seq, event:{type,...}}
// seq is the ADAPTER's sequence, validated monotonic per registration by
// the broker; the broker preserves it (never renumbers).
export function validateEventFrame(f) {
  if (
    !isPlain(f) ||
    f.type !== 'event' ||
    !isStr(f.instanceId) ||
    !Number.isInteger(f.generation) ||
    f.generation < 0 ||
    !Number.isInteger(f.seq) ||
    f.seq < 0 ||
    !isPlain(f.event) ||
    !isStr(f.event.type)
  ) {
    return fail('invalid_request', "expected {type:'event',instanceId,generation,seq,event:{type,...}}");
  }
  return {
    ok: true,
    value: { type: 'event', instanceId: f.instanceId, generation: f.generation, seq: f.seq, event: f.event },
  };
}

// session.unavailable: {type:'session.unavailable', instanceId, generation, currentGeneration?}
// generation = the subscriber's subscribed (now dead) generation.
export function validateSessionUnavailableFrame(f) {
  if (!isPlain(f) || f.type !== 'session.unavailable' || !isStr(f.instanceId) || !Number.isInteger(f.generation) || f.generation < 0) {
    return fail('invalid_request', 'malformed session.unavailable frame');
  }
  if (f.currentGeneration !== undefined && (!Number.isInteger(f.currentGeneration) || f.currentGeneration < 0)) {
    return fail('invalid_request', 'malformed session.unavailable.currentGeneration');
  }
  return { ok: true, value: pick(f, ['type', 'instanceId', 'generation', 'currentGeneration']) };
}
