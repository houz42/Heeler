// Lifecycle coordinator tests: honest per-kind capability declaration,
// start idempotency under duplicate requestKey delivery, already-running
// refusal, occupancy-unknown refusal, forceClose identity re-resolution,
// and the unsupported stop/resume envelopes — against a scripted fake
// herdr speaking the exact one-request-per-connection NDJSON wire verified
// live on herdr 0.9.1 (protocol 22). No real herdr needed for the unit
// layer; the live proof runs against the installed server separately.

import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import {
  InterprocessLock,
  LifecycleCoordinator,
  HerdrApi,
  declaredLifecycleCapabilities,
  agentNameFor,
  HERDR_START_KINDS,
  LIFECYCLE_OPS,
  LIFECYCLE_ENVELOPE,
} from '../src/lifecycle.mjs';

let dir;
let servers = []; // every fake herdr server this test file started
let socketSeq = 0; // unique fake socket names (close() unlinks; reuse would collide)

function fakeAgent(fields = {}) {
  return {
    terminal_id: fields.terminal_id ?? 'term_fake1',
    name: fields.name ?? null,
    agent: fields.agent ?? null,
    agent_status: fields.agent_status ?? 'unknown',
    launch_pending: fields.launch_pending ?? false,
    interactive_ready: fields.interactive_ready ?? true,
    workspace_id: 'w1',
    tab_id: fields.tab_id ?? 'w1:t1',
    pane_id: fields.pane_id ?? 'w1:p1',
    focused: false,
    revision: 1,
    cwd: fields.cwd ?? '/tmp',
    ...fields.extra,
  };
}

/**
 * Scripted, STATEFUL fake herdr API server — it actually tracks the state
 * lifecycle operations mutate (tabs, panes, registered agents), so a start
 * is visible to the next agent.list and a pane.close really removes the
 * pane. `script` maps "method" to a handler overriding the default:
 *   () => reply | {__error:'code'} | (params, state) => reply.
 * Handlers may be async. state: {tabs, panes, agents} keyed by id, plus
 * callLog. Panes resolve with fakeAgent defaults when absent (a scripted
 * test can still force wire-drift shapes by setting them explicitly).
 */
async function startFakeHerdr(script = {}, opts = {}) {
  const socketPath = opts.socketPath ?? path.join(dir, `herdr-${socketSeq++}.sock`);
  const state = {
    socketPath,
    callLog: [],
    tabs: new Map(), // tab_id -> tab info
    panes: new Map(), // pane_id -> pane info (fakeAgent shape)
    agents: new Map(), // pane_id -> agent info (registered)
  };
  let paneSeq = 0;
  let tabSeq = 0;
  const defaults = {
    ping: () => ({ type: 'pong', version: '0.9.1', protocol: 22, capabilities: { live_handoff: true } }),
    'agent.list': () => ({ type: 'agent_list', agents: [...state.agents.values()] }),
    'tab.create': (p) => {
      const tabId = `w1:t${++tabSeq}`;
      const paneId = `w1:p${++paneSeq}`;
      state.tabs.set(tabId, { tab_id: tabId, workspace_id: 'w1', number: tabSeq, label: p.label ?? 'x', focused: !!p.focus, pane_count: 1, agent_status: 'unknown' });
      state.panes.set(paneId, fakeAgent({ pane_id: paneId, tab_id: tabId, name: null, agent: null, terminal_id: `term_${paneSeq}` }));
      return { type: 'tab_created', tab: state.tabs.get(tabId), root_pane: state.panes.get(paneId) };
    },
    'agent.start': (p) => {
      const pane = state.panes.get(p.pane_id) ?? fakeAgent({ pane_id: p.pane_id });
      const agent = { ...pane, name: p.name, agent: p.kind, launch_pending: false };
      state.panes.set(p.pane_id, agent);
      state.agents.set(p.pane_id, agent);
      return { type: 'agent_started', agent, argv: ['pi'] };
    },
    'pane.get': (p) => {
      const pane = state.panes.get(p.pane_id);
      if (!pane) return { __error: 'pane_not_found' };
      return { type: 'pane_info', pane };
    },
    'pane.process_info': (p) => ({
      type: 'pane_process_info',
      process_info: {
        pane_id: p.pane_id,
        shell_pid: 4242,
        foreground_process_group_id: 4242,
        foreground_processes: [{ pid: 4242, name: 'zsh', argv0: 'zsh', argv: ['-zsh'], cmdline: '-zsh', cwd: '/tmp' }],
      },
    }),
    'pane.close': (p) => {
      if (!state.panes.has(p.pane_id)) return { __error: 'pane_not_found' };
      state.panes.delete(p.pane_id);
      state.agents.delete(p.pane_id);
      return { type: 'ok' };
    },
    'tab.close': (p) => {
      if (!state.tabs.has(p.tab_id)) return { __error: 'tab_not_found' };
      state.tabs.delete(p.tab_id);
      return { type: 'ok' };
    },
  };
  await new Promise((resolve) => {
    const srv = net.createServer((sock) => {
      let buf = '';
      sock.on('data', (chunk) => {
        buf += chunk.toString('utf8');
        const nl = buf.indexOf('\n');
        if (nl < 0) return;
        const line = buf.slice(0, nl);
        buf = '';
        let frame;
        try {
          frame = JSON.parse(line);
        } catch {
          sock.write(JSON.stringify({ id: '', error: { code: 'bad_frame', message: 'undecodable' } }) + '\n');
          sock.end();
          return;
        }
        state.callLog.push({ method: frame.method, params: frame.params });
        // one request per connection: answer, then close (like the real server)
        const answer = (reply) => {
          const body = reply && reply.__error
            ? { id: frame.id, error: { code: reply.__error, message: reply.__message || 'fake error' } }
            : { id: frame.id, result: reply };
          sock.write(JSON.stringify(body) + '\n');
          sock.end();
        };
        const handler = script[frame.method] ?? defaults[frame.method] ?? (() => ({ type: 'ok' }));
        try {
          Promise.resolve(handler(frame.params, state)).then(answer, (err) =>
            answer({ __error: 'internal', __message: String(err) }),
          );
        } catch (err) {
          answer({ __error: 'internal', __message: String(err) });
        }
      });
    });
    servers.push(srv);
    srv.listen(socketPath, resolve);
  });
  state.defaults = defaults;
  return state;
}

function herdrErr(code, message = 'fake error') {
  return { __error: code, __message: message };
}

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-chat-lifecycle-'));
});

afterEach(async () => {
  await Promise.all(servers.map((s) => new Promise((r) => s.close(r))));
  servers = [];
  fs.rmSync(dir, { recursive: true, force: true });
});

let stateRootSeq = 0;

/** A fresh isolated Meadow state root so the persisted host registry and
 *  the interprocess lock file never leak between tests. */
function freshStateRoot() {
  return path.join(dir, `state-${stateRootSeq++}`);
}

async function withCoordinator(script, opts, fn) {
  const fake = await startFakeHerdr(script);
  const coordinator = new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake.socketPath, requestTimeoutMs: 2000 }),
    stateRoot: freshStateRoot(),
    ...(opts ?? {}),
  });
  return fn(coordinator, fake);
}

// ---------------------------------------------------------------------------
// capability declaration

test('declaredLifecycleCapabilities: verified kinds; unknown kinds return null', () => {
  for (const kind of HERDR_START_KINDS) {
    const caps = declaredLifecycleCapabilities(kind);
    assert.ok(caps, `kind ${kind} must have a declaration`);
    assert.equal(caps.kind, kind);
    assert.equal(caps.start.supported, true, `start must be declared supported for ${kind} (agent.start verified)`);
    assert.equal(caps.status.supported, true);
    assert.equal(caps.stop.supported, false, `stop must be declared unsupported for ${kind} (no agent.stop in herdr 0.9.1)`);
    assert.equal(caps.resume.supported, false, `resume must be declared unsupported for ${kind}`);
    assert.equal(caps.forceClose.supported, true);
    assert.equal(caps.forceClose.destructive, true);
    assert.ok(caps.stop.reason.length > 0);
    assert.equal(caps.stop.destructiveAlternative, 'lifecycle.forceClose');
    assert.ok(caps.start.evidence.length > 0);
  }
  assert.equal(declaredLifecycleCapabilities('bash'), null);
  assert.equal(declaredLifecycleCapabilities(''), null);
  assert.equal(declaredLifecycleCapabilities(null), null);
  assert.equal(declaredLifecycleCapabilities(undefined), null);
});

test('agentNameFor: deterministic, herdr name-rule conforming', () => {
  const a = agentNameFor('my-conversation/key 1');
  assert.match(a, /^mdc-[0-9a-f]{12}$/);
  assert.equal(agentNameFor('my-conversation/key 1'), a);
  assert.notEqual(agentNameFor('my-conversation/key 2'), a);
  assert.throws(() => agentNameFor(''));
  assert.throws(() => agentNameFor(null));
  // herdr's verified agent-name rule: ^[a-z][a-z0-9_-]{0,31}$
  for (const key of ['x', 'a'.repeat(1000), 'ünïcode-🔑', 'pane w1:p1 / run 2']) {
    assert.match(agentNameFor(key), /^[a-z][a-z0-9_-]{0,31}$/);
  }
});

// ---------------------------------------------------------------------------
// start: happy path

test('start: creates tab, starts agent, records identity; agent pane identity is authoritative', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const env = await c.start({ conversationKey: 'conv-a', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.envelope, LIFECYCLE_ENVELOPE);
    assert.equal(env.op, 'lifecycle.start');
    assert.equal(env.outcome, 'completed');
    assert.equal(env.result.conversation.paneId, 'w1:p1');
    assert.equal(env.result.conversation.terminalId, 'term_1');
    assert.equal(env.result.conversation.name, agentNameFor('conv-a'));
    assert.equal(env.result.conversation.kind, 'pi');
    assert.equal(env.result.launchPending, false);
    assert.ok(env.result.argv);
    // the stateful fake now registers the agent: agent.list sees it
    const listed = fake.callLog.filter((x) => x.method === 'agent.list');
    assert.ok(listed.length >= 1, 'occupancy inspection ran');
    assert.ok(fake.agents.has('w1:p1'), 'the fake registered the started agent');
  });
});

test('start: agent_started carrying a different pane id wins over the requested pane', async () => {
  await withCoordinator({
    'agent.start': () => ({
      type: 'agent_started',
      agent: fakeAgent({ pane_id: 'w1:pALTERNATE', name: 'x', terminal_id: 'term_alt', tab_id: 'w1:t9' }),
      argv: ['pi'],
    }),
  }, {}, async (c) => {
    const env = await c.start({ conversationKey: 'conv-alt', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.outcome, 'completed');
    assert.equal(env.result.conversation.paneId, 'w1:pALTERNATE');
    assert.equal(env.result.conversation.terminalId, 'term_alt');
  });
});

test('start: unknown kind refused with the supported-kind contract', async () => {
  await withCoordinator({}, {}, async (c) => {
    const env = await c.start({ conversationKey: 'conv', kind: 'definitely-not-an-agent', cwd: '/tmp' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'unknown_kind');
    assert.match(env.reason, /herdr 0.9\.1/);
  });
});

test('start: invalid params refused without touching herdr', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    for (const bad of [
      { kind: 'pi', cwd: '/tmp' }, // no conversationKey
      { conversationKey: 'k', kind: 'pi', cwd: 'relative/path' }, // cwd must be absolute
      { conversationKey: 'k' }, // no kind
      { conversationKey: '', kind: 'pi', cwd: '/tmp' },
    ]) {
      const env = await c.start(bad);
      assert.equal(env.outcome, 'refused', JSON.stringify(bad));
      assert.equal(env.code, 'invalid_params');
    }
    assert.equal(fake.callLog.length, 0, 'invalid params must not reach herdr');
  });
});

// ---------------------------------------------------------------------------
// start: idempotency under duplicate requestKey delivery

test('start: duplicate requestKey delivery replays the envelope and never creates extra tabs', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const p1 = c.start({ conversationKey: 'conv-dup', kind: 'pi', cwd: '/tmp', requestKey: 'req-1' });
    const p2 = c.start({ conversationKey: 'conv-dup', kind: 'pi', cwd: '/tmp', requestKey: 'req-1' });
    const p3 = c.start({ conversationKey: 'conv-dup', kind: 'pi', cwd: '/tmp', requestKey: 'req-1' });
    const [e1, e2, e3] = await Promise.all([p1, p2, p3]);
    assert.equal(e1.outcome, 'completed');
    assert.ok(!e1.replayed, 'the first delivery is not a replay');
    assert.equal(e2.outcome, 'completed');
    assert.ok(e2.replayed, 'duplicate delivery replays');
    assert.equal(e3.outcome, 'completed');
    assert.ok(e3.replayed);
    assert.deepEqual(e2.result.conversation, e1.result.conversation);
    const tabCreates = fake.callLog.filter((c2) => c2.method === 'tab.create');
    const starts = fake.callLog.filter((c2) => c2.method === 'agent.start');
    assert.equal(tabCreates.length, 1, 'one tab.create total across three deliveries');
    assert.equal(starts.length, 1, 'one agent.start total across three deliveries');
  });
});

test('start: concurrent different requestKeys, same conversation — second refused already_running, still one tab', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const e1 = await c.start({ conversationKey: 'conv-race', kind: 'pi', cwd: '/tmp', requestKey: 'req-a' });
    const e2 = await c.start({ conversationKey: 'conv-race', kind: 'pi', cwd: '/tmp', requestKey: 'req-b' });
    assert.equal(e1.outcome, 'completed');
    assert.equal(e2.outcome, 'refused');
    assert.equal(e2.code, 'already_running');
    assert.equal(fake.callLog.filter((c2) => c2.method === 'tab.create').length, 1);
  });
});

test('start: agent_pane_busy retried within the budget, then succeeds', async () => {
  let busyCount = 0;
  await withCoordinator({
    'agent.start': (params, state) => {
      if (busyCount++ < 2) return herdrErr('agent_pane_busy', 'not an available shell');
      return state.defaults['agent.start'](params, state);
    },
  }, { busyRetryDelayMs: 10, startShellWaitMs: 5000 }, async (c) => {
    const env = await c.start({ conversationKey: 'conv-busy', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.outcome, 'completed');
    assert.equal(busyCount, 3);
  });
});

test('start: agent_pane_busy beyond the budget refuses AND closes the created tab', async () => {
  let createdTabId = null;
  await withCoordinator({
    'tab.create': (params, state) => {
      const r = state.defaults['tab.create'](params, state);
      createdTabId = r.tab.tab_id;
      return r;
    },
    'agent.start': () => herdrErr('agent_pane_busy', 'not an available shell'),
  }, { busyRetryDelayMs: 5, startShellWaitMs: 60 }, async (c, fake) => {
    const env = await c.start({ conversationKey: 'conv-busy2', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'start_failed');
    assert.ok(env.cleanup, 'the refusal states the tab cleanup outcome');
    assert.ok(fake.callLog.some((c2) => c2.method === 'tab.close' && c2.params.tab_id === createdTabId),
      'the created tab was closed again');
  });
});

test('start: agent.start hard error closes the created tab and refuses', async () => {
  await withCoordinator({
    'agent.start': () => herdrErr('unsupported interactive agent kind', 'nope'),
  }, {}, async (c, fake) => {
    const env = await c.start({ conversationKey: 'conv-hard', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'herdr_rejected');
    assert.match(env.reason, /unsupported interactive agent kind/);
    assert.ok(fake.callLog.some((c2) => c2.method === 'tab.close'));
  });
});

test('start: tab.create result without correlated identity refuses without a start', async () => {
  await withCoordinator({
    'tab.create': () => ({ type: 'tab_created' }), // wire drift: no tab/root_pane
  }, {}, async (c, fake) => {
    const env = await c.start({ conversationKey: 'conv-drift', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'herdr_rejected');
    assert.match(env.reason, /lacked the correlated/);
    assert.ok(!fake.callLog.some((c2) => c2.method === 'agent.start'), 'no start on an unusable create result');
  });
});

// ---------------------------------------------------------------------------
// occupancy

test('start: already-running conversation refused with the live identity', async () => {
  const name = agentNameFor('conv-live');
  await withCoordinator(
    { 'agent.list': () => ({ type: 'agent_list', agents: [fakeAgent({ name, agent: 'pi', pane_id: 'w1:pLIVE', terminal_id: 'term_live' })] }) },
    {},
    async (c) => {
      const env = await c.start({ conversationKey: 'conv-live', kind: 'pi', cwd: '/tmp' });
      assert.equal(env.outcome, 'refused');
      assert.equal(env.code, 'already_running');
      assert.equal(env.existing.paneId, 'w1:pLIVE');
      assert.equal(env.existing.terminalId, 'term_live');
      assert.equal(env.existing.adopted, true, 'the live identity is adopted for later status/forceClose');
      // and the adopted record is now the status target
      const st = await c.status({ conversationKey: 'conv-live' });
      assert.equal(st.result.state, 'running');
    },
  );
});

test('start: occupancy inspection failure is a refusal, never permission', async () => {
  await withCoordinator({ 'agent.list': () => herdrErr('internal', 'boom') }, {}, async (c, fake) => {
    const env = await c.start({ conversationKey: 'conv-occ', kind: 'pi', cwd: '/tmp' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'occupancy_unknown');
    assert.match(env.reason, /unknown occupancy is a refusal/);
    assert.ok(!fake.callLog.some((c2) => c2.method === 'tab.create'), 'nothing was created on unknown occupancy');
  });
});

test('start: unreachable herdr refuses via the server gate', async () => {
  const api = new HerdrApi({ socketPath: path.join(dir, 'no-such.sock'), requestTimeoutMs: 300 });
  const c = new LifecycleCoordinator({ herdr: api });
  const env = await c.start({ conversationKey: 'conv-x', kind: 'pi', cwd: '/tmp' });
  assert.equal(env.outcome, 'refused');
  assert.equal(env.code, 'occupancy_unknown');
});

test('start: protocol-older server is unsupported, not attempted', async () => {
  await withCoordinator(
    { ping: () => ({ type: 'pong', version: '0.8.0', protocol: 19 }) },
    {},
    async (c, fake) => {
      const env = await c.start({ conversationKey: 'conv-old', kind: 'pi', cwd: '/tmp' });
      assert.equal(env.outcome, 'unsupported');
      assert.match(env.reason, /predates the verified protocol 22/);
      assert.equal(fake.callLog.filter((c2) => c2.method === 'tab.create').length, 0);
    },
  );
});

// ---------------------------------------------------------------------------
// single-writer domain
test('single-writer guard spans the whole host across sessions, not just the selected one', async () => {
  // Two coordinators on DIFFERENT herdr session sockets, SAME host label +
  // SAME persisted state root. Each fake delays its agent.start answer by
  // 60ms. If the writer guard covered only one session (or one process),
  // both starts would be in flight at once (probe.maxConcurrent 2); the
  // whole-host guard must serialize the two mutation sequences.
  const probe = { inFlight: 0, maxConcurrent: 0 };
  const slowStart = (d) => async (params, state) => {
    probe.inFlight++;
    probe.maxConcurrent = Math.max(probe.maxConcurrent, probe.inFlight);
    await new Promise((r) => setTimeout(r, d));
    probe.inFlight--;
    return state.defaults['agent.start'](params, state);
  };
  const fake1 = await startFakeHerdr({ 'agent.start': slowStart(60) });
  const fake2 = await startFakeHerdr({ 'agent.start': slowStart(60) });
  const stateRoot = freshStateRoot();
  const mk = (fake) => new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake.socketPath, requestTimeoutMs: 3000 }),
    hostLabel: 'host-x',
    stateRoot,
    lockTimeoutMs: 5000,
  });
  const c1 = mk(fake1);
  const c2 = mk(fake2);

  const [e1, e2] = await Promise.all([
    c1.start({ conversationKey: 'conv-sw1', kind: 'pi', cwd: '/tmp' }),
    c2.start({ conversationKey: 'conv-sw2', kind: 'pi', cwd: '/tmp' }),
  ]);
  assert.equal(e1.outcome, 'completed', JSON.stringify(e1));
  assert.equal(e2.outcome, 'completed', JSON.stringify(e2));
  assert.equal(probe.maxConcurrent, 1, 'whole-host mutations must not interleave across sessions');
});

// Same conversation, two sessions on one host: the second start is refused
// after DISCOVERING the live agent by probing the recorded session's socket
// (the persisted registry, not process memory, carries the record).
test('start: cross-session occupancy is discovered by probing the recorded session', async () => {
  const fake1 = await startFakeHerdr({});
  const fake2 = await startFakeHerdr({});
  const stateRoot = freshStateRoot();
  const c1 = new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake1.socketPath, requestTimeoutMs: 2000 }),
    hostLabel: 'host-y',
    stateRoot,
  });
  const first = await c1.start({ conversationKey: 'conv-x1', kind: 'pi', cwd: '/tmp' });
  assert.equal(first.outcome, 'completed');

  const c2 = new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake2.socketPath, requestTimeoutMs: 2000 }),
    hostLabel: 'host-y',
    stateRoot,
  });
  const env = await c2.start({ conversationKey: 'conv-x1', kind: 'pi', cwd: '/tmp' });
  assert.equal(env.outcome, 'refused');
  assert.equal(env.code, 'already_running');
  assert.match(env.reason, /live on herdr session .* \(verified by probing it\)/);
  assert.equal(env.existing.session, fake1.socketPath);
  assert.equal(env.existing.paneId, first.result.conversation.paneId);
  // fake2 was never asked to create anything
  assert.ok(!fake2.callLog.some((c2x) => c2x.method === 'tab.create'));
});

// Cross-session record whose session has gone silent: unverifiable
// occupancy is a refusal, never permission.
test('start: unreachable recorded session is a refusal (unverifiable occupancy)', async () => {
  const fake1 = await startFakeHerdr({});
  const fake1Server = servers[servers.length - 1]; // the server startFakeHerdr just pushed
  const stateRoot = freshStateRoot();
  const c1 = new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake1.socketPath, requestTimeoutMs: 2000 }),
    hostLabel: 'host-z',
    stateRoot,
  });
  await c1.start({ conversationKey: 'conv-x2', kind: 'pi', cwd: '/tmp' });
  // the recorded session's socket disappears (server down)
  servers.splice(servers.indexOf(fake1Server), 1); // afterEach must not close it again
  await new Promise((r) => fake1Server.close(r));

  const fake2 = await startFakeHerdr({});
  const c2 = new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake2.socketPath, requestTimeoutMs: 2000 }),
    hostLabel: 'host-z',
    stateRoot,
  });
  const env = await c2.start({ conversationKey: 'conv-x2', kind: 'pi', cwd: '/tmp' });
  assert.equal(env.outcome, 'refused');
  assert.equal(env.code, 'already_running');
  assert.match(env.reason, /cannot be reached to verify it stopped/);
  assert.ok(!fake2.callLog.some((c2x) => c2x.method === 'tab.create'));
});

// ---------------------------------------------------------------------------
// stop / resume: honest unsupported envelopes

test('stop: declared unsupported with the reason and the separate destructive alternative', async () => {
  await withCoordinator({}, {}, async (c) => {
    await c.start({ conversationKey: 'conv-stop', kind: 'pi', cwd: '/tmp' });
    const env = await c.stop({ conversationKey: 'conv-stop' });
    assert.equal(env.op, 'lifecycle.stop');
    assert.equal(env.outcome, 'unsupported');
    assert.match(env.reason, /no first-class agent\.stop/);
    assert.match(env.reason, /Ctrl\+C is not assumed/);
    assert.equal(env.destructiveAlternative, 'lifecycle.forceClose');
    assert.equal(env.kindResolved, 'pi');
    // nothing was closed behind the client's back
    const st = await c.status({ conversationKey: 'conv-stop' });
    assert.equal(st.result.state, 'running');
  });
});

test('stop: unknown conversation still says unsupported (never fabricates a stop for a kind it cannot see)', async () => {
  await withCoordinator({}, {}, async (c) => {
    const env = await c.stop({ conversationKey: 'never-started' });
    assert.equal(env.outcome, 'unsupported');
    assert.equal(env.kindResolved, null);
  });
});

test('resume: declared unsupported; no latest-file heuristic anywhere', async () => {
  await withCoordinator({}, {}, async (c) => {
    await c.start({ conversationKey: 'conv-res', kind: 'pi', cwd: '/tmp' });
    const env = await c.resume({ conversationKey: 'conv-res', conversation: 'some-durable-id' });
    assert.equal(env.op, 'lifecycle.resume');
    assert.equal(env.outcome, 'unsupported');
    assert.match(env.reason, /no first-class agent\.resume/);
    assert.match(env.reason, /exact durable conversation/);
  });
});

test('stop/resume: missing conversationKey refused as invalid_params', async () => {
  await withCoordinator({}, {}, async (c) => {
    assert.equal((await c.stop({})).code, 'invalid_params');
    assert.equal((await c.resume({})).code, 'invalid_params');
  });
});

// ---------------------------------------------------------------------------
// status

test('status: running state carries registration + process inspection evidence', async () => {
  await withCoordinator({}, {}, async (c) => {
    await c.start({ conversationKey: 'conv-st', kind: 'pi', cwd: '/tmp' });
    const env = await c.status({ conversationKey: 'conv-st' });
    assert.equal(env.outcome, 'completed');
    assert.equal(env.result.state, 'running');
    assert.equal(env.result.agent.name, agentNameFor('conv-st'));
    assert.equal(env.result.evidence.registration, 'herdr agent.list');
    assert.equal(env.result.evidence.process.shellPid, 4242);
    assert.equal(env.result.evidence.process.foreground.length, 1);
    assert.equal(env.result.evidence.process.foreground[0].name, 'zsh');
  });
});

test('status: stopped requires registration/process inspection, not prompt text', async () => {
  // The agent's registration disappears (process stopped) while the pane
  // stays alive at its shell prompt: a "stopped" claim must come from
  // registration inspection, never prompt text.
  await withCoordinator({}, {}, async (c, fake) => {
    const started = await c.start({ conversationKey: 'conv-stp', kind: 'pi', cwd: '/tmp' });
    const paneId = started.result.conversation.paneId;
    const terminalId = started.result.conversation.terminalId;
    fake.agents.delete(paneId); // registration gone
    // pane back to a plain shell pane (the agent process exited)
    fake.panes.set(paneId, fakeAgent({ pane_id: paneId, terminal_id: terminalId, name: null, agent: null }));
    const env = await c.status({ conversationKey: 'conv-stp' });
    assert.equal(env.result.state, 'stopped');
    assert.match(env.result.evidence.basis, /pane alive at its shell/);
    assert.equal(env.result.last.paneId, paneId);
  });
});

test('status: pane_not_found after a close reports stopped with the basis', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const started = await c.start({ conversationKey: 'conv-gone', kind: 'pi', cwd: '/tmp' });
    // really close the pane in the fake (agent + pane gone)
    fake.defaults['pane.close']({ pane_id: started.result.conversation.paneId }, fake);
    const env = await c.status({ conversationKey: 'conv-gone' });
    assert.equal(env.result.state, 'stopped');
    assert.match(env.result.evidence.basis, /pane closed/);
  });
});

test('status: pane id reused by a different terminal identity reports unknown, not stopped', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const started = await c.start({ conversationKey: 'conv-reuse', kind: 'pi', cwd: '/tmp' });
    const paneId = started.result.conversation.paneId;
    // agent stopped; the pane id got reused by a DIFFERENT terminal
    fake.agents.delete(paneId);
    fake.panes.set(paneId, fakeAgent({ pane_id: paneId, name: null, agent: null, terminal_id: 'term_OTHER' }));
    const env = await c.status({ conversationKey: 'conv-reuse' });
    assert.equal(env.result.state, 'unknown');
    assert.match(env.result.reason, /different terminal identity/);
  });
});

test('status: pane hosting a foreign agent under the recorded id reports unknown', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const started = await c.start({ conversationKey: 'conv-foreign', kind: 'pi', cwd: '/tmp' });
    const paneId = started.result.conversation.paneId;
    const terminalId = started.result.conversation.terminalId;
    // our agent stopped; a DIFFERENT agent now occupies the same pane id
    // (same terminal identity, so the terminal guard alone cannot catch it)
    fake.agents.delete(paneId);
    fake.panes.set(paneId, fakeAgent({ pane_id: paneId, terminal_id: terminalId, name: null, agent: 'claude' }));
    const env = await c.status({ conversationKey: 'conv-foreign' });
    assert.equal(env.result.state, 'unknown');
    assert.match(env.result.reason, /not registered under the conversation identity/);
  });
});

test('status: unmanaged, never-started conversation reports stopped with explicit basis', async () => {
  await withCoordinator({}, {}, async (c) => {
    const env = await c.status({ conversationKey: 'never-started' });
    assert.equal(env.result.state, 'stopped');
    assert.match(env.result.evidence.basis, /no agent registered under the conversation identity/);
  });
});

test('status: agent.list failure reports unknown (never invents a state)', async () => {
  await withCoordinator({ 'agent.list': () => herdrErr('internal', 'boom') }, {}, async (c) => {
    const env = await c.status({ conversationKey: 'conv-unk' });
    assert.equal(env.result.state, 'unknown');
    assert.match(env.result.reason, /agent\.list failed/);
  });
});

// ---------------------------------------------------------------------------
// forceClose

test('forceClose: closes the recorded agent pane only, after re-resolving identity', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const started = await c.start({ conversationKey: 'conv-fc', kind: 'pi', cwd: '/tmp' });
    const { paneId, terminalId } = started.result.conversation;
    const env = await c.forceClose({ conversationKey: 'conv-fc' });
    assert.equal(env.outcome, 'completed');
    assert.equal(env.result.closed, true);
    assert.equal(env.result.paneId, paneId);
    assert.equal(env.result.terminalId, terminalId);
    assert.match(env.result.guard, /re-resolved immediately before pane\.close/);
    assert.ok(fake.callLog.some((c2) => c2.method === 'pane.close' && c2.params.pane_id === paneId));
    // and never the tab
    assert.ok(!fake.callLog.some((c2) => c2.method === 'tab.close'), 'forceClose never closes the whole tab');
    assert.ok(!fake.panes.has(paneId), 'the pane really closed in the fake');
  });
});

test('forceClose: pane id reuse (different terminal_id) refuses and closes NOTHING', async () => {
  await withCoordinator({
    'pane.get': () => ({ type: 'pane_info', pane: fakeAgent({ name: null, agent: null, terminal_id: 'term_REUSED' }) }),
  }, {}, async (c, fake) => {
    await c.start({ conversationKey: 'conv-fc2', kind: 'pi', cwd: '/tmp' });
    const env = await c.forceClose({ conversationKey: 'conv-fc2' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'identity_mismatch');
    assert.equal(env.observedTerminalId, 'term_REUSED');
    assert.ok(!fake.callLog.some((c2) => c2.method === 'pane.close'), 'no pane.close was dispatched');
  });
});

test('forceClose: target gone (pane_not_found at re-resolution) reports target_gone', async () => {
  await withCoordinator({ 'pane.get': () => herdrErr('pane_not_found') }, {}, async (c) => {
    await c.start({ conversationKey: 'conv-fc3', kind: 'pi', cwd: '/tmp' });
    const env = await c.forceClose({ conversationKey: 'conv-fc3' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'target_gone');
    assert.match(env.reason, /nothing was closed/);
  });
});

test('forceClose: pane.close race (pane vanished between re-resolution and close) reports target_gone', async () => {
  await withCoordinator({ 'pane.close': () => herdrErr('pane_not_found') }, {}, async (c) => {
    await c.start({ conversationKey: 'conv-fc4', kind: 'pi', cwd: '/tmp' });
    const env = await c.forceClose({ conversationKey: 'conv-fc4' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'target_gone');
  });
});

test('forceClose: unmanaged conversationKey refuses not_managed', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    const env = await c.forceClose({ conversationKey: 'not-managed' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'not_managed');
    assert.equal(fake.callLog.filter((c2) => c2.method === 'pane.close').length, 0);
  });
});

test('forceClose: explicit {paneId, terminalId} pair is honored after re-resolution', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    // seed one real pane in the fake (a plain terminal pane, no conversation)
    const created = await fake.defaults['tab.create']({}, fake);
    const { pane_id: paneId, terminal_id: terminalId } = created.root_pane;
    const env = await c.forceClose({ paneId, terminalId });
    assert.equal(env.outcome, 'completed');
    assert.ok(fake.callLog.some((c2) => c2.method === 'pane.close' && c2.params.pane_id === paneId));
  });
});

test('forceClose: explicit pair with mismatched identity refuses without dispatch', async () => {
  await withCoordinator({
    'pane.get': () => ({ type: 'pane_info', pane: fakeAgent({ name: null, agent: null, terminal_id: 'term_OTHER' }) }),
  }, {}, async (c, fake) => {
    const env = await c.forceClose({ paneId: 'w1:p1', terminalId: 'term_expected' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'identity_mismatch');
    assert.equal(env.observedTerminalId, 'term_OTHER');
    assert.equal(fake.callLog.filter((c2) => c2.method === 'pane.close').length, 0);
  });
});

test('forceClose: requestKey idempotency replays and dispatches once', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    await c.start({ conversationKey: 'conv-fck', kind: 'pi', cwd: '/tmp' });
    const [e1, e2] = await Promise.all([
      c.forceClose({ conversationKey: 'conv-fck', requestKey: 'fc-1' }),
      c.forceClose({ conversationKey: 'conv-fck', requestKey: 'fc-1' }),
    ]);
    assert.equal(e1.outcome, 'completed');
    assert.equal(e2.outcome, 'completed');
    assert.ok(e2.replayed);
    assert.equal(fake.callLog.filter((c2) => c2.method === 'pane.close').length, 1);
  });
});

test('forceClose: inspection failure refuses to close unverified', async () => {
  await withCoordinator({ 'pane.get': () => herdrErr('internal', 'boom') }, {}, async (c, fake) => {
    await c.start({ conversationKey: 'conv-fc5', kind: 'pi', cwd: '/tmp' });
    const env = await c.forceClose({ conversationKey: 'conv-fc5' });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'inspection_failed');
    assert.equal(fake.callLog.filter((c2) => c2.method === 'pane.close').length, 0);
  });
});

// ---------------------------------------------------------------------------
// envelope invariants

test('every envelope carries the versioned lifecycle envelope tag and a known op', async () => {
  await withCoordinator({}, {}, async (c) => {
    const envs = await Promise.all([
      c.start({ conversationKey: 'conv-env', kind: 'pi', cwd: '/tmp' }),
      c.stop({ conversationKey: 'conv-env' }),
      c.resume({ conversationKey: 'conv-env' }),
      c.status({ conversationKey: 'conv-env' }),
      c.forceClose({ conversationKey: 'conv-env' }),
    ]);
    for (const env of envs) {
      assert.equal(env.envelope, 'agent-chat.lifecycle.v1');
      assert.ok(LIFECYCLE_OPS.includes(env.op), env.op);
      assert.ok(['completed', 'refused', 'unsupported'].includes(env.outcome));
    }
  });
});

// ---------------------------------------------------------------------------
// review blockers: malformed occupancy, ledger ordering, key preservation,
// and the cross-PROCESS host guard.

// Blocker 2: a successful agent.list reply with a malformed payload is NOT
// "no agents" — it is unknown occupancy and must never become a mutation.
test('start: malformed agent.list result is occupancy_unknown, never permission', async () => {
  for (const bad of [
    () => ({ type: 'agent_list' }), // missing agents array
    () => ({ type: 'agent_list', agents: 'nope' }), // agents not an array
    () => ({ type: 'agent_list', agents: [null] }), // non-object entry
    () => ({ type: 'agent_list', agents: [{ name: 42 }] }), // entry not validated later, but shape check must hold
    () => null, // no result object at all
  ]) {
    await withCoordinator({ 'agent.list': bad }, {}, async (c, fake) => {
      const env = await c.start({ conversationKey: 'conv-mal', kind: 'pi', cwd: '/tmp' });
      assert.equal(env.outcome, 'refused', JSON.stringify(bad()));
      assert.equal(env.code, 'occupancy_unknown');
      assert.match(env.reason, /wire drift|not an object/);
      assert.ok(!fake.callLog.some((x) => x.method === 'tab.create'),
        'a malformed occupancy reply must never become a mutation');
    });
  }
});

test('status: malformed agent.list result reports unknown, never a state', async () => {
  await withCoordinator({ 'agent.list': () => ({ type: 'agent_list' }) }, {}, async (c) => {
    const env = await c.status({ conversationKey: 'conv-mal-status' });
    assert.equal(env.result.state, 'unknown');
    assert.match(env.result.reason, /occupancy inspection untrustworthy/);
  });
});

// Blocker 3: forceClose replay of a COMPLETED close returns the recorded
// envelope — even though the record it consumed is already dropped, and
// even from a fresh coordinator process reading the persisted ledger.
test('forceClose: replay AFTER completion returns the recorded completed envelope, not not_managed', async () => {
  await withCoordinator({}, {}, async (c, fake) => {
    await c.start({ conversationKey: 'conv-fcr', kind: 'pi', cwd: '/tmp' });
    const e1 = await c.forceClose({ conversationKey: 'conv-fcr', requestKey: 'fc-replay-1' });
    assert.equal(e1.outcome, 'completed');
    assert.equal(e1.requestKey, 'fc-replay-1', 'the completed envelope carries its requestKey');
    // the conversation record is consumed — a ledger-less repeat is not_managed
    const bare = await c.forceClose({ conversationKey: 'conv-fcr' });
    assert.equal(bare.outcome, 'refused');
    assert.equal(bare.code, 'not_managed');
    // but the SAME requestKey replays the recorded completed envelope
    const e2 = await c.forceClose({ conversationKey: 'conv-fcr', requestKey: 'fc-replay-1' });
    assert.equal(e2.outcome, 'completed', 'the ledger is consulted before the record lookup');
    assert.equal(e2.result.closed, true);
    assert.ok(e2.replayed);
    assert.equal(e2.requestKey, 'fc-replay-1');
    assert.equal(fake.callLog.filter((x) => x.method === 'pane.close').length, 1, 'still exactly one pane.close');
  });
});

test('start: completed envelopes carry their requestKey (envelope contract)', async () => {
  await withCoordinator({}, {}, async (c) => {
    const env = await c.start({ conversationKey: 'conv-keyed', kind: 'pi', cwd: '/tmp', requestKey: 'start-keyed-1' });
    assert.equal(env.outcome, 'completed');
    assert.equal(env.requestKey, 'start-keyed-1', 'a completed start must echo the requestKey');
  });
});

// Cross-process replay: a SECOND coordinator instance (fresh ledger,
// same persisted state root) replays the first's completed start.
test('requestKey replay works across coordinator instances via the persisted ledger', async () => {
  const fake = await startFakeHerdr({});
  const stateRoot = freshStateRoot();
  const mk = () => new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake.socketPath, requestTimeoutMs: 2000 }),
    hostLabel: 'host-replay',
    stateRoot,
  });
  const e1 = await mk().start({ conversationKey: 'conv-xproc', kind: 'pi', cwd: '/tmp', requestKey: 'xp-1' });
  assert.equal(e1.outcome, 'completed');
  assert.ok(!e1.replayed);
  const e2 = await mk().start({ conversationKey: 'conv-xproc', kind: 'pi', cwd: '/tmp', requestKey: 'xp-1' });
  assert.equal(e2.outcome, 'completed');
  assert.ok(e2.replayed, 'a fresh instance replays from the persisted ledger');
  assert.deepEqual(e2.result.conversation, e1.result.conversation);
  assert.equal(fake.callLog.filter((x) => x.method === 'tab.create').length, 1, 'still one tab total');
});

// Cross-process mutation race: a SECOND PROCESS (real child_process.fork)
// must not interleave mutations with this one — the lock file is the
// arbiter. Child and parent both start an agent with a slow agent.start;
// exactly one runs at a time and both complete.
test('interprocess lock: two real processes serialize whole-host mutations', async () => {
  const probe = { count: 0, inFlight: 0, max: 0 };
  const fake = await startFakeHerdr({
    'agent.start': async (params, state) => {
      probe.count++;
      probe.inFlight++;
      probe.max = Math.max(probe.max, probe.inFlight);
      await new Promise((r) => setTimeout(r, 120));
      probe.inFlight--;
      return state.defaults['agent.start'](params, state);
    },
  });
  const stateRoot = freshStateRoot();
  const childSrc = `
import { LifecycleCoordinator, HerdrApi } from ${JSON.stringify(pathToFileURL(path.resolve('src/lifecycle.mjs')).href)};
const c = new LifecycleCoordinator({
  herdr: new HerdrApi({ socketPath: ${JSON.stringify(fake.socketPath)}, requestTimeoutMs: 5000 }),
  hostLabel: 'host-race',
  stateRoot: ${JSON.stringify(stateRoot)},
  lockTimeoutMs: 10000,
});
const env = await c.start({ conversationKey: 'conv-child', kind: 'pi', cwd: '/tmp' });
process.stdout.write(JSON.stringify(env));
`;
  const parent = new LifecycleCoordinator({
    herdr: new HerdrApi({ socketPath: fake.socketPath, requestTimeoutMs: 5000 }),
    hostLabel: 'host-race',
    stateRoot,
    lockTimeoutMs: 10000,
    lockStaleMs: 30000,
  });
  const childPromise = new Promise((resolve, reject) => {
    execFile(process.execPath, ['--input-type=module', '-e', childSrc], { cwd: process.cwd() }, (err, so, se) => {
      if (err) return reject(Object.assign(new Error(se || String(err)), { code: err.code }));
      try {
        resolve(JSON.parse(so));
      } catch (e) {
        reject(new Error(`child printed unparseable output: ${so.slice(0, 200)}`));
      }
    });
  });
  const [childEnv, parentEnv] = await Promise.all([
    childPromise,
    parent.start({ conversationKey: 'conv-parent', kind: 'pi', cwd: '/tmp' }),
  ]);
  assert.equal(childEnv.outcome, 'completed', JSON.stringify(childEnv));
  assert.equal(parentEnv.outcome, 'completed', JSON.stringify(parentEnv));
  assert.equal(probe.max, 1, 'the lock file must serialize mutations across real processes');
  assert.equal(probe.count, 2, 'both starts ran (serialized)');
  assert.equal(fake.callLog.filter((x) => x.method === 'tab.create').length, 2, 'one tab each');
});

// The reviewer's case, pinned: a LIVE-but-SLOW holder must NEVER have its
// lock taken. Process A binds the lock and stays alive, blocked, far past
// any stale budget; process B must time out (lock_timeout refusal), never
// acquire. Then A dies and B's NEXT attempt acquires — crash recovery is
// kernel-side (fds reaped), not an age guess.
test('interprocess lock: a live slow holder is never stolen from; death releases instantly', async () => {
  const lockPath = path.join(dir, 'holder-test.lock');
  // A: bind the lock exactly the way InterprocessLock does, then block
  // (alive, event-loop busy) far longer than B's acquisition budget.
  const holder = spawn(process.execPath, ['--input-type=module', '-e', `
import net from 'node:net';
import fs from 'node:fs';
const srv = net.createServer(() => {});
await new Promise((resolve, reject) => {
  srv.once('error', reject);
  srv.listen(${JSON.stringify(lockPath)}, resolve);
});
process.stdout.write('held');
setInterval(() => {}, 1000); // stay alive, loop busy
`]);
  let held = '';
  holder.stdout.on('data', (d) => (held += d.toString()));
  for (let i = 0; i < 100 && held !== 'held'; i++) await new Promise((r) => setTimeout(r, 50));
  assert.equal(held, 'held', 'the child holder must confirm it bound the lock');

  // B: a contender with a SHORT budget. The holder is alive (kernel accepts
  // probe connections). B must NOT acquire — timeout refusal, never a steal.
  const contender = new InterprocessLock(lockPath, { timeoutMs: 800 });
  const acquired = await contender.acquire();
  assert.ok(acquired !== true, 'a live slow holder must never be stolen from');
  assert.match(acquired.error, /live host-package process holds/);
  assert.match(acquired.error, /never stolen/);

  // Still held: a second contender also cannot acquire.
  const contender2 = new InterprocessLock(lockPath, { timeoutMs: 300 });
  const acquired2 = await contender2.acquire();
  assert.ok(acquired2 !== true);

  // The holder dies (SIGKILL — no release code runs). The kernel reaps its
  // bound socket; the very next acquisition must succeed with NO timeout.
  const killed = await new Promise((resolve) => {
    holder.kill('SIGKILL');
    holder.once('exit', (code, sig) => resolve({ code, sig }));
  });
  assert.equal(killed.sig, 'SIGKILL');
  const recovered = new InterprocessLock(lockPath, { timeoutMs: 5000 });
  const got = await recovered.acquire();
  assert.equal(got, true, 'a dead holder releases the lock instantly (kernel fd reaping, no age guess)');
  recovered.release();
});

// In-process: the same guarantee holds for two InterprocessLock instances
// in one process (the second contender sees the first's live bound socket).
test('interprocess lock: second in-process contender cannot acquire a held lock', async () => {
  const lockPath = path.join(dir, 'inproc.lock');
  const a = new InterprocessLock(lockPath, { timeoutMs: 2000 });
  const gotA = await a.acquire();
  assert.equal(gotA, true);
  const b = new InterprocessLock(lockPath, { timeoutMs: 400 });
  const gotB = await b.acquire();
  assert.ok(gotB !== true, 'a held lock cannot be acquired again');
  assert.match(gotB.error, /live host-package process holds/);
  a.release();
  await new Promise((r) => setTimeout(r, 150)); // release is async (close callback)
  const c = new InterprocessLock(lockPath, { timeoutMs: 2000 });
  const gotC = await c.acquire();
  assert.equal(gotC, true, 'after release the next acquisition succeeds');
  c.release();
});
