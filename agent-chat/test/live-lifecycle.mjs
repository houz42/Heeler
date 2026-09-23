// LIVE verification of the lifecycle coordinator against the installed
// herdr server (0.9.1, protocol 22). Not part of `npm test` (no real herdr
// on CI); run explicitly:
//
//   node test/live-lifecycle.mjs [/path/to/herdr.sock]
//
// Exercises the design's acceptance requirements with real state:
//   1. a real start with idempotency under duplicate requestKey delivery
//      (exactly one tab/agent created),
//   2. an already-running conversation refused,
//   3. the honest capability declaration (stop/resume unsupported),
//   4. status transitions running -> stopped (real process inspection),
//   5. forceClose re-resolution + real pane close,
//   and cleans up after itself (closes what it created).

import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { LifecycleCoordinator, HerdrApi, declaredLifecycleCapabilities, agentNameFor } from '../src/lifecycle.mjs';

const socketPath = process.argv[2] || path.join(os.homedir(), '.config/herdr/herdr.sock');
const cwd = '/tmp';
const run = `${Date.now()}-${process.pid}`;
const conversationKey = `meadow-live-proof-${run}`;

const events = [];
const api = new HerdrApi({ socketPath, requestTimeoutMs: 20_000 });
const coordinator = new LifecycleCoordinator({
  herdr: api,
  hostLabel: `live-${os.hostname()}`,
  log: (ev) => events.push(ev),
});

let failures = 0;
function check(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(
      () => console.log(`ok   ${name}`),
      (err) => {
        failures++;
        console.error(`FAIL ${name}\n     ${err && err.stack ? err.stack.split('\n').slice(0, 4).join('\n     ') : err}`);
      },
    );
}

try {
  await check('herdr reachable + protocol 22', async () => {
    const ping = await api.ping();
    assert.ok(ping.ok, `ping failed: ${JSON.stringify(ping.error)}`);
    assert.equal(ping.result.protocol, 22);
    console.log(`     server ${ping.result.version} protocol ${ping.result.protocol}`);
  });

  await check('honest capability declaration: start/status/forceClose yes, stop/resume unsupported', async () => {
    const caps = declaredLifecycleCapabilities('pi');
    assert.ok(caps.start.supported);
    assert.ok(caps.status.supported);
    assert.ok(caps.forceClose.supported && caps.forceClose.destructive);
    assert.equal(caps.stop.supported, false);
    assert.equal(caps.resume.supported, false);
    assert.match(caps.stop.reason, /no first-class agent\.stop/);
    assert.equal(caps.stop.destructiveAlternative, 'lifecycle.forceClose');
  });

  // 1. Real start, duplicate requestKey delivery in flight.
  const startParams = { conversationKey, kind: 'pi', cwd, label: `meadow-live-${run}`.slice(0, 40), requestKey: `start-${run}` };
  let started;
  await check('real start: tab + agent created; duplicate delivery creates no extra tab/pane', async () => {
    const [e1, e2, e3] = await Promise.all([
      coordinator.start(startParams),
      coordinator.start(startParams),
      coordinator.start(startParams),
    ]);
    assert.equal(e1.outcome, 'completed', JSON.stringify(e1));
    assert.ok(!e1.replayed);
    for (const e of [e2, e3]) {
      assert.equal(e.outcome, 'completed');
      assert.ok(e.replayed, 'duplicate delivery must replay');
      assert.deepEqual(e.result.conversation, e1.result.conversation);
    }
    started = e1;
    assert.ok(started.result.conversation.paneId, 'authoritative agent pane id');
    assert.ok(started.result.conversation.terminalId);
    assert.equal(started.result.conversation.name, agentNameFor(conversationKey));
  });

  // tab count sanity: the label we chose appears exactly once
  await check('exactly one destination tab carries the conversation label', async () => {
    const tabs = await api.rpc('tab.list', {});
    assert.ok(tabs.ok, JSON.stringify(tabs.error));
    const mine = tabs.result.tabs.filter((t) => t.label && t.label.includes(`meadow-live-${run}`.slice(0, 40)));
    assert.equal(mine.length, 1, `expected 1 created tab, saw ${mine.length}`);
  });

  // 2. Already-running conversation refused
  await check('already-running conversation refused (live registration seen)', async () => {
    const env = await coordinator.start({ ...startParams, requestKey: `second-${run}` });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'already_running');
    assert.equal(env.existing.paneId, started.result.conversation.paneId);
  });

  // 3. Honest unsupported declarations
  await check('stop and resume honestly unsupported on a live conversation', async () => {
    const stop = await coordinator.stop({ conversationKey });
    assert.equal(stop.outcome, 'unsupported');
    assert.match(stop.reason, /no first-class agent\.stop/);
    assert.equal(stop.destructiveAlternative, 'lifecycle.forceClose');
    const resume = await coordinator.resume({ conversationKey });
    assert.equal(resume.outcome, 'unsupported');
    assert.match(resume.reason, /no first-class agent\.resume/);
  });

  // 4. Status: running with real process evidence
  await check('status: running, backed by registration + real process inspection', async () => {
    const env = await coordinator.status({ conversationKey });
    assert.equal(env.outcome, 'completed');
    assert.equal(env.result.state, 'running');
    assert.equal(env.result.agent.paneId, started.result.conversation.paneId);
    assert.ok(env.result.evidence.process, 'process inspection evidence present');
    assert.ok(Number.isInteger(env.result.evidence.process.shellPid) || env.result.evidence.process.shellPid === null);
  });

  // 5. forceClose: re-resolution + real close
  await check('forceClose: re-resolves identity then really closes only the agent pane', async () => {
    const env = await coordinator.forceClose({ conversationKey, requestKey: `fc-${run}` });
    assert.equal(env.outcome, 'completed', JSON.stringify(env));
    assert.equal(env.result.closed, true);
    assert.equal(env.result.paneId, started.result.conversation.paneId);
    assert.match(env.result.guard, /re-resolved immediately before/);
  });

  await check('status after close: stopped, from inspection not prompt text', async () => {
    const env = await coordinator.status({ conversationKey });
    assert.equal(env.outcome, 'completed');
    assert.equal(env.result.state, 'stopped');
    assert.ok(env.result.evidence.basis);
  });

  await check('forceClose after gone: target_gone, nothing closed (explicit identity re-resolution)', async () => {
    const env = await coordinator.forceClose({
      paneId: started.result.conversation.paneId,
      terminalId: started.result.conversation.terminalId,
      requestKey: `fc2-${run}`,
    });
    assert.equal(env.outcome, 'refused');
    assert.equal(env.code, 'target_gone');
  });
} finally {
  // Cleanup: close the tab we created if anything remains.
  try {
    const tabs = await api.rpc('tab.list', {});
    if (tabs.ok) {
      for (const t of tabs.result.tabs.filter((x) => x.label && x.label.includes(`meadow-live-${run}`.slice(0, 40)))) {
        await api.tabClose(t.tab_id);
        console.log(`cleanup: closed leftover tab ${t.tab_id}`);
      }
    }
  } catch {}
}

console.log(failures === 0 ? '\nLIVE PROOF: all checks passed' : `\nLIVE PROOF: ${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
