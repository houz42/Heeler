/**
 * omp ask adapter tests — behavioral boundaries of installAskAdapter's
 * broker-facing surface: pending→answered/cancelled/expired transitions,
 * multi-question exact-answer validation, generation invalidation, and
 * native-winner passthrough. No incidental content-list assertions.
 *
 * Runtime: node:test via tsx-style loader or the harness Main wires; these
 * assert the module's own contract, not omp's wire. The fake pi has no
 * getAllTools (unverifiable registry => registered path, fallback schema),
 * which is the same code path a real host without the API takes.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { installAskAdapter, type AskBridge, type AskPi } from "../adapters/omp/ask.ts";

/** Yield the microtask queue enough turns for runAsk to publish the
 * interaction without any wall-clock timer. The wrapper's own publishes are
 * synchronous within execute()'s first await boundary; two queued microtask
 * drains cover the tail-chain serialization plus invokeTool dispatch. */
async function aTurnTick(): Promise<void> {
	for (let i = 0; i < 4; i++) {
		await Promise.resolve();
	}
}
// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

interface EmittedEvent {
	type: "interaction.opened" | "interaction.resolved";
	payload: Record<string, unknown>;
}

/** Fake pi + a gated fake native dialog. The native invokeTool stays pending
 * like a real terminal dialog until the test settles it: resolve/reject, or
 * the delegation signal aborts (the wrapper's safe-cancel path). */
function makeFakePi(opts?: {
	nativeResult?: { content: Array<{ type: string; text: string }>; details?: unknown; isError?: boolean };
	nativeRejectsImmediately?: () => Error;
}) {
	const registeredTools: Array<Record<string, unknown>> = [];
	const pi: AskPi = {
		registerTool: t => registeredTools.push(t as Record<string, unknown>),
	};
	const { promise: dialogOpened, resolve: dialogOpenedResolve } = Promise.withResolvers<void>();
	let settleDialog: ((r: unknown) => void) | undefined;
	let lastSignal: AbortSignal | undefined;
	let nativeRejections = 0;
	const nativeCalls: Array<Record<string, unknown>> = [];
	return {
		pi,
		registeredTools,
		dialogOpened,
		get lastSignal() {
			return lastSignal;
		},
		get nativeCalls() {
			return nativeCalls;
		},
		/** Terminal user answers the dialog. */
		answerTerminal(result?: unknown) {
			settleDialog?.(
				result ?? opts?.nativeResult ?? { content: [{ type: "text", text: "native says" }], details: { native: true } },
			);
		},
		/** Extract the wrapper tool's execute and run it against the gated dialog. */
		async executeAsk(params: Record<string, unknown>, signal?: AbortSignal) {
			assert.ok(registeredTools.length > 0, "ask wrapper tool was not registered");
			const tool = registeredTools[0]!;
			const execute = tool.execute as (
				id: string,
				params: Record<string, unknown>,
				signal: AbortSignal | undefined,
				onUpdate: undefined,
				ctx: unknown,
			) => Promise<unknown>;
			const ctx = {
				invokeTool: (p: Record<string, unknown>, o?: { signal?: AbortSignal }) => {
					nativeCalls.push(p);
					lastSignal = o?.signal;
					const { promise, resolve } = Promise.withResolvers<unknown>();
					settleDialog = resolve;
					dialogOpenedResolve();
					if (opts?.nativeRejectsImmediately) {
						nativeRejections += 1;
						return Promise.reject(opts.nativeRejectsImmediately());
					}
					// Real dialog behavior: abort closes it, surfacing as a rejection.
					if (lastSignal) {
						lastSignal.addEventListener("abort", () => {
							nativeRejections += 1;
							resolve(new Error("Ask input was cancelled"));
						});
					}
					return promise.then(v => {
						if (v instanceof Error) throw v;
						return v;
					});
				},
			};
			return execute("call-1", params, signal, undefined, ctx);
		},
	};
}

function makeBridge(startGeneration = 1) {
	const events: EmittedEvent[] = [];
	let generation = startGeneration;
	const bridge: AskBridge = {
		emit: (type, payload) => events.push({ type, payload }),
		getGeneration: () => generation,
	};
	return { bridge, events, setGeneration: (g: number) => (generation = g) };
}

const QUESTIONS = {
	questions: [
		{ id: "q1", question: "First?", options: [{ label: "A" }, { label: "B" }] },
		{ id: "q2", question: "Second?", multi: true, options: [{ label: "X" }, { label: "Y" }] },
	],
};

// ---------------------------------------------------------------------------
// Pending → answered (remote wins; native winner passes through unchanged)
// ---------------------------------------------------------------------------

test("remote answer wins: pending→answered transition, remote result shape", async () => {
	const f = makeFakePi();
	const { bridge, events } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	const pending = adapter.listPending();
	assert.deepEqual(pending, { pending: [] }, "no pending before any ask");

	const askPromise = f.executeAsk(QUESTIONS as Record<string, unknown>);
	await f.dialogOpened; // the native dialog is up; the interaction is published

	const { pending: listed } = adapter.listPending();
	assert.equal(listed.length, 1, "one pending interaction replayed");
	const interaction = listed[0]!;
	assert.equal(interaction.kind, "question");
	assert.equal(interaction.generation, 1);
	assert.equal(interaction.questions.length, 2);
	assert.equal(interaction.questions[0]!.id, "q1");
	assert.deepEqual(
		interaction.questions[0]!.options.map(o => o.id),
		["idx:0", "idx:1"],
		"stable option ids",
	);
	assert.equal(interaction.questions[1]!.multi, true);
	assert.equal(interaction.questions[0]!.allowCustom, true);
	assert.equal(events[0]!.type, "interaction.opened");

	const verdict = adapter.answer({
		requestId: interaction.requestId,
		answers: [
			{ questionId: "q1", optionIds: ["idx:1"] },
			{ questionId: "q2", optionIds: ["idx:0", "idx:1"], customText: "extra" },
		],
	});
	assert.deepEqual(verdict, { accepted: true });

	const result = (await askPromise) as { content: Array<{ type: string; text: string }>; details: unknown };
	assert.ok(result.content[0]!.text.includes("User answers:"), "multi-question result format");
	const details = result.details as { results: Array<{ id: string; selectedOptions: string[]; customInput?: string }> };
	assert.equal(details.results.length, 2);
	assert.deepEqual(details.results[0]!.selectedOptions, ["B"]);
	assert.deepEqual(details.results[1]!.selectedOptions, ["X", "Y"]);
	assert.equal(details.results[1]!.customInput, "extra");

	assert.deepEqual(adapter.listPending(), { pending: [] }, "no pending after settle");
	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved.length, 1);
	assert.equal(resolved[0]!.payload.outcome, "answered");
	assert.equal(resolved[0]!.payload.source, "remote");

	adapter.dispose();
});

test("native winner returns UNCHANGED; second remote claim rejected as item_changed", async () => {
	const nativeResult = { content: [{ type: "text", text: "native says" }], details: { native: true }, isError: false };
	const f = makeFakePi({ nativeResult });
	const { bridge, events } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	const askPromise = f.executeAsk({ questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }] });
	await f.dialogOpened;
	const { pending } = adapter.listPending();
	const requestId = pending[0]!.requestId;

	// Terminal answers first — the native dialog resolves with its own result.
	f.answerTerminal();
	const result = await askPromise;
	assert.deepEqual(result, nativeResult, "native result passes through byte-identical");

	// Late remote claim on the settled request.
	const late = adapter.answer({ requestId, answers: [{ questionId: "q1", optionIds: ["idx:0"] }] });
	assert.equal(late.accepted, false);
	assert.equal((late as { code: string }).code, "item_changed");

	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved[0]!.payload.outcome, "answered");
	assert.equal(resolved[0]!.payload.source, "terminal");
	adapter.dispose();
});

// ---------------------------------------------------------------------------
// Pending → cancelled
// ---------------------------------------------------------------------------
test("remote cancel aborts the delegation signal and settles cancelled/remote", async () => {
	const f = makeFakePi();
	const { bridge, events } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	const askPromise = f.executeAsk({ questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }] });
	askPromise.catch(() => undefined); // expected rejection via safe cancel
	await f.dialogOpened;
	const { pending } = adapter.listPending();
	const requestId = pending[0]!.requestId;
	const signal = f.lastSignal;
	assert.ok(signal, "delegation signal captured");
	let aborted = false;
	signal!.addEventListener("abort", () => (aborted = true));

	const verdict = adapter.cancel({ requestId });
	assert.deepEqual(verdict, { accepted: true });
	await aTurnTick();

	assert.equal(aborted, true, "delegation signal aborted (safe cancel path)");
	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved[0]!.payload.outcome, "cancelled");
	assert.equal(resolved[0]!.payload.source, "remote");

	// Double cancel: already settled.
	const again = adapter.cancel({ requestId });
	assert.equal((again as { code: string }).code, "item_changed");
	adapter.dispose();
});

test("native rejection (Esc) settles cancelled/terminal; ask rejects verbatim", async () => {
	const nativeError = new Error("Ask input was cancelled");
	const f = makeFakePi({ nativeRejectsImmediately: () => nativeError });
	const { bridge, events } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	const askPromise = f.executeAsk({ questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }] });
	await assert.rejects(askPromise, err => err === nativeError, "native rejection propagates verbatim");

	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved[0]!.payload.outcome, "cancelled");
	assert.equal(resolved[0]!.payload.source, "terminal");
	adapter.dispose();
});

// ---------------------------------------------------------------------------
// Pending → expired (stale generation)
// ---------------------------------------------------------------------------

test("generation change expires pending asks and closes their dialogs", async () => {
	const f = makeFakePi();
	const { bridge, events, setGeneration } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	const askPromise = f.executeAsk(QUESTIONS as Record<string, unknown>);
	askPromise.catch(() => undefined);
	await f.dialogOpened;
	const { pending } = adapter.listPending();
	assert.equal(pending.length, 1);
	const requestId = pending[0]!.requestId;
	const signal = f.lastSignal;
	assert.ok(signal, "delegation signal captured");
	let aborted = false;
	signal!.addEventListener("abort", () => (aborted = true));

	setGeneration(2);

	// listPending prunes; the stale ask disappears from the replay.
	assert.deepEqual(adapter.listPending(), { pending: [] });
	// An explicit claim on the expired request reports settled (item_changed
	// carries the outcome); a NEW-generation claim would never match it.
	const late = adapter.answer({
		requestId,
		answers: [
			{ questionId: "q1", optionIds: ["idx:0"] },
			{ questionId: "q2", optionIds: ["idx:0"] },
		],
	});
	assert.equal(late.accepted, false);

	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved[0]!.payload.outcome, "expired");
	await aTurnTick();
	assert.equal(aborted, true, "expired ask's dialog closed via safe abort");
	adapter.dispose();
});

// ---------------------------------------------------------------------------
// Exact multi-question validation
// ---------------------------------------------------------------------------

test("answer validation: exact-count, unknown/duplicate questionIds, bad optionIds, single-select rules", async () => {
	const f = makeFakePi();
	const { bridge } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);
	const askPromise = f.executeAsk(QUESTIONS as Record<string, unknown>);
	await f.dialogOpened;
	const { pending } = adapter.listPending();
	const requestId = pending[0]!.requestId;
	const valid: Array<{ questionId: string; optionIds: string[] }> = [
		{ questionId: "q1", optionIds: ["idx:0"] },
		{ questionId: "q2", optionIds: ["idx:0"] },
	];

	const bad: Array<{ name: string; answers: unknown; expect: string }> = [
		{ name: "too few answers", answers: valid.slice(0, 1), expect: "expected exactly 2 answers, got 1" },
		{ name: "answers not array", answers: "nope", expect: "answers must be an array" },
		{
			name: "unknown questionId",
			answers: [valid[0]!, { questionId: "q9", optionIds: ["idx:0"] }],
			expect: "unknown questionId: q9",
		},
		{
			name: "duplicate questionId",
			answers: [valid[0]!, valid[0]!],
			expect: "duplicate answer for questionId: q1",
		},
		{
			name: "unknown optionId",
			answers: [
				{ questionId: "q1", optionIds: ["idx:5"] },
				{ questionId: "q2", optionIds: ["idx:0"] },
			],
			expect: 'unknown optionId "idx:5"',
		},
		{
			name: "duplicate optionId",
			answers: [
				{ questionId: "q1", optionIds: ["idx:0", "idx:0"] },
				{ questionId: "q2", optionIds: ["idx:0"] },
			],
			expect: 'duplicate optionId "idx:0"',
		},
		{
			name: "single-select multi pick",
			answers: [
				{ questionId: "q1", optionIds: ["idx:0", "idx:1"] },
				{ questionId: "q2", optionIds: ["idx:0"] },
			],
			expect: "single-select; at most one optionId",
		},
		{
			name: "empty single-select is a cancel",
			answers: [
				{ questionId: "q1", optionIds: [] },
				{ questionId: "q2", optionIds: ["idx:0"] },
			],
			expect: "empty single-select is a cancel",
		},
	];
	for (const c of bad) {
		const verdict = adapter.answer({ requestId, answers: c.answers });
		assert.equal(verdict.accepted, false, c.name);
		assert.equal((verdict as { code: string }).code, "invalid_request", c.name);
		assert.ok(
			(verdict as { message: string }).message.includes(c.expect),
			`${c.name}: unexpected message ${(verdict as { message: string }).message}`,
		);
	}

	// After all rejections the ask is STILL pending — invalid claims don't settle.
	const { pending: still } = adapter.listPending();
	assert.equal(still.length, 1, "invalid answers do not settle the ask");

	// A valid claim still wins.
	const ok = adapter.answer({
		requestId,
		answers: [
			{ questionId: "q2", optionIds: ["idx:1"] },
			{ questionId: "q1", optionIds: ["idx:1"] },
		],
	});
	assert.deepEqual(ok, { accepted: true }, "answers accepted in any order");
	const result = (await askPromise) as { details: { results: Array<{ id: string; selectedOptions: string[] }> } };
	assert.deepEqual(
		result.details.results.map(r => [r.id, r.selectedOptions]),
		[
			["q1", ["B"]],
			["q2", ["Y"]],
		],
	);
	adapter.dispose();
});

test("request-level validation: missing/invalid requestId and params shapes", async () => {
	const f = makeFakePi();
	const { bridge } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	for (const [name, params] of [
		["null params", null],
		["array params", ["x"]],
		["missing requestId", {}],
		["empty requestId", { requestId: "" }],
		["non-string requestId", { requestId: 42 }],
	] as Array<[string, unknown]>) {
		const a = adapter.answer(params);
		assert.equal(a.accepted, false, name);
		assert.equal((a as { code: string }).code, "invalid_request", name);
		const c = adapter.cancel(params);
		assert.equal(c.accepted, false, name);
		assert.equal((c as { code: string }).code, "invalid_request", name);
	}

	const unknown = adapter.answer({ requestId: "no-such", answers: [] });
	assert.equal((unknown as { code: string }).code, "item_not_found");
	adapter.dispose();
});

// ---------------------------------------------------------------------------
// dispose and registry gating
// ---------------------------------------------------------------------------

test("dispose expires all pending; idempotent", async () => {
	const f = makeFakePi();
	const { bridge, events } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);
	const p1 = f.executeAsk({ questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }] });
	p1.catch(() => undefined);
	await f.dialogOpened;
	assert.equal(adapter.listPending().pending.length, 1);

	adapter.dispose();
	adapter.dispose(); // idempotent

	assert.deepEqual(adapter.listPending(), { pending: [] });
	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved[0]!.payload.outcome, "expired");
});

test("queryable registry with no builtin ask => nothing registered", () => {
	const registeredTools: unknown[] = [];
	const pi: AskPi = {
		registerTool: t => registeredTools.push(t),
		getAllTools: () => [{ name: "read", sourceInfo: { source: "builtin" } }],
	};
	const { bridge } = makeBridge();
	const adapter = installAskAdapter(pi, bridge);
	assert.equal(adapter.registered, false);
	assert.equal(registeredTools.length, 0);
});

test("builtin ask metadata is reused verbatim from getAllTools", () => {
	const registeredTools: Array<Record<string, unknown>> = [];
	const nativeDescription = "Native ask description";
	const nativeParameters = { type: "object", properties: { questions: {} } };
	const pi: AskPi = {
		registerTool: t => registeredTools.push(t as Record<string, unknown>),
		getAllTools: () => [
			{ name: "ask", description: nativeDescription, parameters: nativeParameters, sourceInfo: { source: "builtin" } },
		],
	};
	const { bridge } = makeBridge();
	const adapter = installAskAdapter(pi, bridge);
	assert.equal(adapter.registered, true);
	const tool = registeredTools[0]!;
	assert.equal(tool.description, nativeDescription);
	assert.equal(tool.parameters, nativeParameters, "native schema object reused, not copied");
});

test("transport emit failure does not break the ask lifecycle", async () => {
	const f = makeFakePi();
	const bridge: AskBridge = {
		emit: () => {
			throw new Error("socket gone");
		},
		getGeneration: () => 1,
	};
	const adapter = installAskAdapter(f.pi, bridge);
	const askPromise = f.executeAsk({ questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }] });
	await f.dialogOpened;
	const { pending } = adapter.listPending();
	// Interaction still pending even though the emit failed; terminal path intact.
	assert.equal(pending.length, 1);
	const verdict = adapter.answer({ requestId: pending[0]!.requestId, answers: [{ questionId: "q1", optionIds: ["idx:0"] }] });
	assert.deepEqual(verdict, { accepted: true });
	const result = (await askPromise) as { content: Array<{ type: string; text: string }> };
	assert.ok(result.content[0]!.text.length > 0);
});

test("expiredGeneration expires old-generation pending without disabling the wrapper", async () => {
	const f = makeFakePi();
	const { bridge, events, setGeneration } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);

	// Gen-1 ask in flight.
	const ask1 = f.executeAsk({ questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }] });
	ask1.catch(() => undefined);
	await f.dialogOpened;
	const { pending } = adapter.listPending();
	const requestId = pending[0]!.requestId;

	// Generation switch: host calls expiredGeneration (non-terminal).
	setGeneration(2);
	adapter.expiredGeneration();

	assert.deepEqual(adapter.listPending(), { pending: [] });
	const late = adapter.answer({ requestId, answers: [{ questionId: "q1", optionIds: ["idx:0"] }] });
	assert.equal((late as { code: string }).code, "item_changed");
	const resolved = events.filter(e => e.type === "interaction.resolved");
	assert.equal(resolved[0]!.payload.outcome, "expired");
	await ask1.catch(() => undefined); // dialog closed via safe abort

	// The wrapper is STILL armed: a new-generation ask works end to end.
	const ask2 = f.executeAsk({ questions: [{ id: "q2", question: "New?", options: [{ label: "Z" }] }] });
	await f.dialogOpened;
	const { pending: newPending } = adapter.listPending();
	assert.equal(newPending.length, 1);
	assert.equal(newPending[0]!.generation, 2);
	const verdict = adapter.answer({
		requestId: newPending[0]!.requestId,
		answers: [{ questionId: "q2", optionIds: ["idx:0"] }],
	});
	assert.deepEqual(verdict, { accepted: true });
	const result = (await ask2) as { content: Array<{ type: string; text: string }> };
	assert.ok(result.content[0]!.text.includes("User selected: Z"));
	adapter.dispose();
});

test("dispose is permanent: execute refuses later asks with an explicit error", async () => {
	const f = makeFakePi();
	const { bridge } = makeBridge();
	const adapter = installAskAdapter(f.pi, bridge);
	adapter.dispose();

	const result = (await f.executeAsk({
		questions: [{ id: "q1", question: "One?", options: [{ label: "A" }] }],
	})) as { content: Array<{ type: string; text: string }> };
	assert.ok(
		result.content[0]!.text.includes("ask adapter is disposed"),
		`expected explicit disposed error, got: ${result.content[0]!.text}`,
	);
	assert.deepEqual(adapter.listPending(), { pending: [] });
});
