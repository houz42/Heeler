/**
 * Ask adapter (agent-chat v1) — opt-in remote-answer wrapper for omp's native `ask` tool.
 *
 * Strategy (public omp extension APIs only, no core patch): the host extension
 * calls installAskAdapter(pi, bridge) — solely under HEELER_CHAT_ASK_WRAPPER=1;
 * never installed on ordinary agents by default. When a native `ask` built-in
 * is present the adapter registers a same-name tool via pi.registerTool, which
 * replaces `ask` in the tool registry. The registering extension's tool
 * context then carries ctx.invokeTool bound to the NATIVE ask built-in
 * (ExtensionRunner.createContext resolves invokeTool against the pre-shadow
 * native instance), and the wrapper races:
 *
 *   - native terminal dialog via ctx.invokeTool(params, { signal: ours }) —
 *     the native winner's result is returned UNCHANGED (content, details,
 *     isError, any extra fields, native cancellation semantics);
 *   - a remote answer claimed through answer()/cancel(), validated against
 *     the published Interaction and built into the native result shape.
 *
 * First valid winner wins; the loser is cancelled SAFELY: aborting the
 * delegation signal closes the dialog WITHOUT the whole-turn abort a terminal
 * Esc performs (the native rejection is contained and its result discarded).
 *
 * Documented semantic deltas vs the native tool (deliberate, small):
 *  1. Registry replacement: ToolDefinition cannot express the native
 *     `concurrency: "exclusive"`, so exclusivity is restored locally by a
 *     serialization chain over ask calls only. This is NOT global scheduler
 *     parity — other tools in a batch are unaffected.
 *  2. Description/schema: when pi.getAllTools() exposes the builtin `ask` at
 *     install time, its description and parameters are reused VERBATIM.
 *     Otherwise (API absent, registry not yet populated, or the entry is an
 *     extension shadow) an embedded summary + schema mirror ships — no
 *     identical-to-native claim is made for the fallback and it may lag
 *     native.
 *  3. If the registry is queryable and contains no builtin `ask`, nothing is
 *     registered (registered === false): a shadow tool with no native dialog
 *     to delegate to would be strictly worse than absence. The host reports
 *     capabilities.interactions=true only when registered === true.
 *  4. Remote cancel = safe delegation abort only; terminal Esc keeps the
 *     native whole-turn abort, preserved verbatim through the native path.
 *     Any native rejection is reported as outcome "cancelled", source
 *     "terminal" (Esc vs turn-abort vs dialog teardown is not distinguishable
 *     at the tool boundary).
 *  5. No remote-side timeout: the native ask.timeout applies to the
 *     delegated dialog and surfaces as the native winner (timedOut results
 *     pass through unchanged). Remote pending asks are only invalidated by
 *     lifecycle — dispose() or a generation change (outcome "expired").
 *  6. Question validation mirrors the native execute checks (reserved
 *     labels, unique question ids, unique option labels within a question,
 *     non-empty). The native path re-validates the delegated params itself,
 *     so this mirror is an early rejection, not a divergence. Native has no
 *     option-count limits; none are added here.
 *
 * No Pi pi-ask dependency; no broker/socket code lives in this module — the
 * injected bridge owns the wire.
 */
import { randomUUID } from "node:crypto";

// ---------------------------------------------------------------------------
// Public structural types (no package imports so the host omp/Bun loads this)
// ---------------------------------------------------------------------------

/** Outbound interaction-event bridge owned by the host extension (wire plumbing). */
export interface AskBridge {
	/** Emit an ordered interaction event; transport errors are the host's domain. */
	emit(type: "interaction.opened" | "interaction.resolved", payload: Record<string, unknown>): void;
	/** Current agent-chat generation; a change invalidates pending asks. */
	getGeneration(): number;
}

/** Entry shape of pi.getAllTools() (session.getAllToolInfos), structural. */
export interface AskNativeToolInfo {
	name?: unknown;
	description?: unknown;
	parameters?: unknown;
	sourceInfo?: { source?: unknown } | null;
}

/** Minimal pi surface this module needs. */
export interface AskPi {
	registerTool(tool: unknown): void;
	/** Optional public pi.getAllTools(); absent on older hosts. */
	getAllTools?(): ReadonlyArray<AskNativeToolInfo>;
}

/** Structural shape of the public ExtensionContext this module relies on. */
export interface AskExtensionContext {
	/** Same-tool native delegation; present only when a native `ask` exists. */
	invokeTool?<TDetails = unknown>(
		params: Record<string, unknown>,
		options?: { signal?: AbortSignal; onUpdate?: (partial: unknown) => void },
	): Promise<{ content: Array<{ type: string; text: string }>; details?: TDetails; isError?: boolean }>;
}

export interface InteractionOption {
	id: string;
	label: string;
	description?: string;
	preview?: string;
}

export interface InteractionQuestion {
	id: string;
	text: string;
	multi: boolean;
	recommendedOptionIds?: string[];
	options: InteractionOption[];
	allowCustom: boolean;
}

/** Normalized interaction published to remote clients (agent-chat contract). */
export interface Interaction {
	requestId: string;
	generation: number;
	kind: "question";
	questions: InteractionQuestion[];
}

/** Stable-protocol verdict for interactions.answer / interactions.cancel. */
export type AskVerdict =
	| { accepted: true }
	| {
			accepted: false;
			/** Subset of the contract error codes relevant to interactions. */
			code: "invalid_request" | "stale_generation" | "item_not_found" | "item_changed";
			message: string;
		};

export interface AskAdapter {
	/** True iff a wrapper tool was registered (native ask present or unverifiable). */
	readonly registered: boolean;
	/** Broker `interactions.list`: current-generation pending asks (replay on every call). */
	listPending(): { pending: Interaction[] };
	/** Broker `interactions.answer` params: { requestId, answers: [{ questionId, optionIds, customText?, note? }] }. */
	answer(params: unknown): AskVerdict;
	/** Broker `interactions.cancel` params: { requestId }. */
	cancel(params: unknown): AskVerdict;
	/**
	 * Invalidate all pending asks of the given (or current) generation WITHOUT
	 * disabling the adapter — the wrapper tool stays registered and later asks
	 * at the new generation work normally. Idempotent; no-op when disposed.
	 * Host calls this on session/generation switch (session_start /
	 * session_switch / session_branch / session_tree) instead of disposing
	 * and re-installing, which would re-register the shadow against a
	 * registry snapshot that no longer holds the native builtin.
	 */
	expiredGeneration(generation?: number): void;
	/**
	 * Permanently retire the adapter instance: expire every pending ask,
	 * close their dialogs, and refuse ALL future asks — the wrapper tool's
	 * execute returns an explicit "adapter disposed" error result instead of
	 * racing a dialog that no longer has a remote counterpart. The shadow
	 * tool registration itself is NOT un-registered (omp's public
	 * registerTool surface has no unregister), so dispose() is one-way: the
	 * host must create a NEW adapter instance (fresh extension session) to
	 * re-arm ask interception. Host calls on session_shutdown.
	 */
	dispose(): void;
}

// ---------------------------------------------------------------------------
// Fallback ask schema mirror + summary description (native tools/ask.ts shape)
// ---------------------------------------------------------------------------

const askJsonSchema = {
	type: "object",
	properties: {
		questions: {
			type: "array",
			minItems: 1,
			items: {
				type: "object",
				properties: {
					id: { type: "string" },
					question: { type: "string" },
					header: { type: "string" },
					options: {
						type: "array",
						items: {
							type: "object",
							properties: {
								label: { type: "string" },
								description: { type: "string" },
								preview: { type: "string" },
							},
							required: ["label"],
							additionalProperties: false,
						},
					},
					multi: { type: "boolean" },
					recommended: { type: "number" },
				},
				required: ["id", "question", "options"],
				additionalProperties: false,
			},
		},
	},
	required: ["questions"],
	additionalProperties: false,
} as const;

const FALLBACK_DESCRIPTION =
	"Ask user for clarification/input during task execution. Use when multiple approaches have significantly different tradeoffs the user should weigh, or a decision materially changes the work. " +
	"Provide concise, distinct options per question (the UI adds its own controls; never include 'Other (type your own)', 'Chat about this', or 'Next →'). " +
	"`questions` groups related questions in one call. `recommended` marks the default option (0-indexed, '(Recommended)' suffix added automatically). `multi: true` allows multiple selections. " +
	"The user may answer at the terminal or through a connected remote chat client; either answer settles the call.";

const OTHER_OPTION = "Other (type your own)";
const CHAT_ABOUT_THIS_OPTION = "Chat about this";
const NEXT_OPTION = "Next →";
/** Static reserved-label table (native RESERVED_OPTION_LABELS). The theme's
 * dynamic multi-select "Done selecting" label is added only after an answer
 * exists, so it cannot collide with model-authored labels here; the native
 * path re-checks it against the delegated params anyway. */
const RESERVED_OPTION_LABELS: Record<string, true> = {
	[OTHER_OPTION]: true,
	[CHAT_ABOUT_THIS_OPTION]: true,
	[NEXT_OPTION]: true,
};

interface AskOption {
	label: string;
	description?: string;
	preview?: string;
}

interface AskQuestion {
	id: string;
	question: string;
	header?: string;
	options: AskOption[];
	multi?: boolean;
	recommended?: number;
}

/** Native sanitizeCarriageReturns (pi-tui render-utils): \r\n → \n, \r+ → space. */
function sanitizeCarriageReturns(text: string): string {
	if (!text.includes("\r")) return text;
	return text.replaceAll("\r\n", "\n").replace(/\r+/g, " ");
}

function errorTextResult(text: string): { content: Array<{ type: "text"; text: string }>; details: {} } {
	return { content: [{ type: "text" as const, text }], details: {} };
}

/** Runtime validation mirroring the native AskTool.execute checks (post-schema). */
function validateQuestions(params: Record<string, unknown>): AskQuestion[] | { error: string } {
	if (params === null || typeof params !== "object") return { error: "Error: questions must be an object" };
	const questions = (params as { questions?: unknown }).questions;
	if (!Array.isArray(questions) || questions.length === 0) {
		return { error: "Error: questions must not be empty" };
	}
	const seenIds = new Set<string>();
	const parsed: AskQuestion[] = [];
	for (const raw of questions) {
		if (raw === null || typeof raw !== "object") return { error: "Error: malformed question entry" };
		const q = raw as Record<string, unknown>;
		if (typeof q.id !== "string" || typeof q.question !== "string" || !Array.isArray(q.options)) {
			return { error: "Error: each question requires id (string), question (string), options (array)" };
		}
		const options: AskOption[] = [];
		for (const rawOpt of q.options) {
			if (rawOpt === null || typeof rawOpt !== "object" || typeof (rawOpt as { label?: unknown }).label !== "string") {
				return { error: "Error: each option requires a label (string)" };
			}
			const o = rawOpt as Record<string, unknown>;
			options.push({
				label: sanitizeCarriageReturns(o.label as string),
				...(typeof o.description === "string" ? { description: sanitizeCarriageReturns(o.description) } : {}),
				...(typeof o.preview === "string" ? { preview: sanitizeCarriageReturns(o.preview) } : {}),
			});
		}
		const question: AskQuestion = {
			id: sanitizeCarriageReturns(q.id),
			question: sanitizeCarriageReturns(q.question),
			...(typeof q.header === "string" ? { header: sanitizeCarriageReturns(q.header) } : {}),
			options,
			...(q.multi === true ? { multi: true } : {}),
			...(typeof q.recommended === "number" ? { recommended: q.recommended } : {}),
		};
		// Reserved runtime labels — native fail-closed checks, post-sanitize.
		for (const option of question.options) {
			if (RESERVED_OPTION_LABELS[option.label] === true) {
				return { error: `Error: option labels must not collide with reserved runtime labels: ${option.label}` };
			}
		}
		if (seenIds.has(question.id)) {
			return { error: `Error: question ids must be unique: ${question.id}` };
		}
		seenIds.add(question.id);
		const seenLabels = new Set<string>();
		for (const option of question.options) {
			if (seenLabels.has(option.label)) {
				return { error: `Error: option labels must be unique within a question: ${option.label}` };
			}
			seenLabels.add(option.label);
		}
		parsed.push(question);
	}
	return parsed;
}

// ---------------------------------------------------------------------------
// Native result-formatting mirrors (ask.ts formatQuestionResult /
// formatSingleQuestionResponse) so remote-built results are compatible with
// what the native rich-dialog path returns.
// ---------------------------------------------------------------------------

interface BuiltQuestionResult {
	id: string;
	question: string;
	options: string[];
	multi: boolean;
	selectedOptions: string[];
	customInput?: string;
	note?: string;
}

function formatQuestionResult(result: BuiltQuestionResult): string {
	const noteSuffix = result.note ? ` (note: ${result.note})` : "";
	if (result.customInput !== undefined) {
		return `${result.id}: "${result.customInput}"${noteSuffix}`;
	}
	if (result.selectedOptions.length > 0) {
		return result.multi
			? `${result.id}: [${result.selectedOptions.join(", ")}]${noteSuffix}`
			: `${result.id}: ${result.selectedOptions[0]}${noteSuffix}`;
	}
	return result.multi ? `${result.id}: []${noteSuffix}` : `${result.id}: (cancelled)${noteSuffix}`;
}

function formatSingleQuestionResponse(result: BuiltQuestionResult): string {
	const parts: string[] = [];
	if (result.selectedOptions.length > 0) {
		parts.push(
			result.multi
				? `User selected: ${result.selectedOptions.join(", ")}`
				: `User selected: ${result.selectedOptions[0]}`,
		);
	}
	if (result.customInput !== undefined) {
		parts.push(
			result.customInput.includes("\n")
				? `User provided custom input:\n${result.customInput.split("\n").map(l => `  ${l}`).join("\n")}`
				: `User provided custom input: ${result.customInput}`,
		);
	}
	if (result.note) {
		parts.push(
			result.note.includes("\n")
				? `User added note:\n${result.note.split("\n").map(l => `  ${l}`).join("\n")}`
				: `User added note: ${result.note}`,
		);
	}
	if (parts.length > 0) return parts.join("\n");
	return result.multi ? "User did not select any options" : "User cancelled the selection";
}

// ---------------------------------------------------------------------------
// Native metadata reuse via pi.getAllTools
// ---------------------------------------------------------------------------

function findNativeAsk(pi: AskPi): {
	hasNative: boolean;
	registryKnown: boolean;
	description?: unknown;
	parameters?: unknown;
} {
	if (typeof pi.getAllTools !== "function") return { hasNative: false, registryKnown: false };
	try {
		const tools = pi.getAllTools();
		if (!Array.isArray(tools)) return { hasNative: false, registryKnown: false };
		for (const entry of tools) {
			if (entry === null || typeof entry !== "object") continue;
			const info = entry as AskNativeToolInfo;
			if (info.name !== "ask") continue;
			// Only the pre-existing builtin counts; an extension shadow of `ask`
			// from another extension has no native dialog to delegate to.
			if (info.sourceInfo?.source !== "builtin") continue;
			return {
				hasNative: true,
				registryKnown: true,
				...(typeof info.description === "string" ? { description: info.description } : {}),
				...(info.parameters !== null && typeof info.parameters === "object" ? { parameters: info.parameters } : {}),
			};
		}
		return { hasNative: false, registryKnown: true };
	} catch {
		// Registry not ready at install time — unverifiable, fall back.
		return { hasNative: false, registryKnown: false };
	}
}

// ---------------------------------------------------------------------------
// Remote answer coordinates
// ---------------------------------------------------------------------------

interface RemoteAnswer {
	questionId: string;
	optionIndices?: number[];
	customText?: string;
	note?: string;
}

interface PendingAsk {
	requestId: string;
	generation: number;
	/** Monotonic creation order for listPending replay. */
	seq: number;
	questions: AskQuestion[];
	/** Resolved by answer() with validated pairs (first valid claim wins). */
	resolveRemote: (pairs: Array<{ answer: RemoteAnswer; question: AskQuestion }>) => void;
	/** The delegation AbortController owning the native dialog's lifetime. */
	controller: AbortController;
	settled: boolean;
}

/** Deterministic opaque option id for the Interaction wire; stable per request. */
function optionIdOf(index: number): string {
	return `idx:${index}`;
}

function optionIndexOf(oid: string): number | undefined {
	if (!oid.startsWith("idx:")) return undefined;
	const n = Number(oid.slice(4));
	return Number.isInteger(n) && n >= 0 ? n : undefined;
}

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------

export function installAskAdapter(pi: AskPi, bridge: AskBridge): AskAdapter {
	const pending = new Map<string, PendingAsk>();
	/** Bounded record of settled requests so late claims get item_changed, not item_not_found. */
	const settledLog = new Map<string, { generation: number; outcome: string }>();
	const SETTLED_LOG_CAP = 256;
	/** Serializes ask calls: the native ask is `concurrency: "exclusive"` and
	 * ToolDefinition cannot express that, so exclusivity is restored locally. */
	let tail: Promise<unknown> = Promise.resolve();
	let order = 0;
	/** One-way retire flag: after dispose(), execute refuses new asks. */
	let disposed = false;

	function safeEmit(type: "interaction.opened" | "interaction.resolved", payload: Record<string, unknown>): void {
		// A dead transport must not break the native terminal path; the host
		// owns wire errors. Remote clients simply cannot answer what they
		// never saw; the terminal dialog remains authoritative.
		try {
			bridge.emit(type, payload);
		} catch {
			/* transport owned by host */
		}
	}

	function settle(p: PendingAsk, outcome: "answered" | "cancelled" | "expired", source: "remote" | "terminal"): void {
		if (p.settled) return;
		p.settled = true;
		pending.delete(p.requestId);
		if (settledLog.size >= SETTLED_LOG_CAP) {
			const oldest = settledLog.keys().next().value;
			if (oldest !== undefined) settledLog.delete(oldest);
		}
		settledLog.set(p.requestId, { generation: p.generation, outcome });
		safeEmit("interaction.resolved", { requestId: p.requestId, generation: p.generation, outcome, source });
	}

	/** Generation changes invalidate pending asks: settle as expired + close the dialog. */
	function pruneStale(): void {
		const generation = bridge.getGeneration();
		for (const entry of [...pending.values()]) {
			if (entry.generation !== generation) {
				settle(entry, "expired", "terminal");
				entry.controller.abort();
			}
		}
	}

	/** Validate a remote answer set against the pending questions.
	 * Selections are addressed by the STABLE optionIds the Interaction
	 * published ("idx:<n>"). Exact one answer per question, in any order. */
	function validateAnswers(
		p: PendingAsk,
		answers: unknown,
	): { ok: true; pairs: Array<{ answer: RemoteAnswer; question: AskQuestion }> } | { ok: false; detail: string } {
		if (!Array.isArray(answers)) return { ok: false, detail: "answers must be an array" };
		if (answers.length !== p.questions.length) {
			return { ok: false, detail: `expected exactly ${p.questions.length} answers, got ${answers.length}` };
		}
		const byId = new Map(p.questions.map(q => [q.id, q]));
		const seen = new Set<string>();
		const pairs: Array<{ answer: RemoteAnswer; question: AskQuestion }> = [];
		for (const raw of answers) {
			if (raw === null || typeof raw !== "object") return { ok: false, detail: "each answer must be an object" };
			const a = raw as Record<string, unknown>;
			if (typeof a.questionId !== "string") return { ok: false, detail: "each answer requires questionId (string)" };
			const question = byId.get(a.questionId);
			if (question === undefined) return { ok: false, detail: `unknown questionId: ${a.questionId}` };
			if (seen.has(a.questionId)) return { ok: false, detail: `duplicate answer for questionId: ${a.questionId}` };
			seen.add(a.questionId);
			if (!Array.isArray(a.optionIds) || !a.optionIds.every(o => typeof o === "string")) {
				return { ok: false, detail: `optionIds for ${a.questionId} must be an array of strings` };
			}
			const resolved: number[] = [];
			for (const oid of a.optionIds as string[]) {
				const idx = optionIndexOf(oid);
				if (idx === undefined || idx >= question.options.length) {
					return { ok: false, detail: `unknown optionId "${oid}" for questionId ${a.questionId}` };
				}
				if (resolved.includes(idx)) {
					return { ok: false, detail: `duplicate optionId "${oid}" for questionId ${a.questionId}` };
				}
				resolved.push(idx);
			}
			if (question.multi !== true && resolved.length > 1) {
				return { ok: false, detail: `${a.questionId} is single-select; at most one optionId` };
			}
			// Native semantics: an empty single-select submission is CANCELLATION,
			// not an answer — use interactions.cancel for that.
			if (question.multi !== true && resolved.length === 0 && a.customText === undefined) {
				return { ok: false, detail: `${a.questionId}: empty single-select is a cancel; use interactions.cancel` };
			}
			if (a.customText !== undefined && typeof a.customText !== "string") {
				return { ok: false, detail: `customText for ${a.questionId} must be a string` };
			}
			if (a.note !== undefined && (typeof a.note !== "string" || a.note.length === 0)) {
				return { ok: false, detail: `note for ${a.questionId} must be a non-empty string` };
			}
			const answer: RemoteAnswer = {
				questionId: a.questionId,
				...(resolved.length > 0 ? { optionIndices: resolved } : {}),
				...(typeof a.customText === "string" ? { customText: a.customText } : {}),
				...(typeof a.note === "string" ? { note: a.note } : {}),
			};
			if (answer.optionIndices === undefined && answer.customText === undefined) {
				return { ok: false, detail: `answer for ${a.questionId} needs optionIds and/or customText` };
			}
			pairs.push({ answer, question });
		}
		return { ok: true, pairs };
	}

	/** Build the native-shaped tool result from validated remote answers.
	 * Results are canonicalized to the REQUESTED question order — the native
	 * multi-question path always aligns results to the requested order, so a
	 * remote answer submitted in a different order must not leak through. */
	function remoteResult(p: PendingAsk, pairs: Array<{ answer: RemoteAnswer; question: AskQuestion }>): {
		content: Array<{ type: "text"; text: string }>;
		details: unknown;
	} {
		const byQuestion = new Map(pairs.map(x => [x.question, x.answer]));
		const results: BuiltQuestionResult[] = p.questions.map(question => {
			const answer = byQuestion.get(question)!;
			return {
				id: question.id,
				question: question.question,
				options: question.options.map(o => o.label),
				multi: question.multi ?? false,
				selectedOptions: (answer.optionIndices ?? []).map(i => question.options[i]!.label),
				...(answer.customText !== undefined ? { customInput: answer.customText } : {}),
				...(answer.note !== undefined ? { note: answer.note } : {}),
			};
		});
		if (results.length === 1) {
			const r = results[0]!;
			return {
				content: [{ type: "text" as const, text: formatSingleQuestionResponse(r) }],
				details: {
					question: r.question,
					options: r.options,
					multi: r.multi,
					selectedOptions: r.selectedOptions,
					...(r.customInput !== undefined ? { customInput: r.customInput } : {}),
					...(r.note !== undefined ? { note: r.note } : {}),
				},
			};
		}
		return {
			content: [{ type: "text" as const, text: `User answers:\n${results.map(formatQuestionResult).join("\n")}` }],
			details: { results },
		};
	}

	/** Map a validated native question to the contract Interaction question. */
	function toInteractionQuestion(q: AskQuestion): InteractionQuestion {
		return {
			id: q.id,
			text: q.question,
			multi: q.multi === true,

			...(q.recommended !== undefined &&
			Number.isInteger(q.recommended) &&
			q.recommended >= 0 &&
			q.recommended < q.options.length
				? { recommendedOptionIds: [optionIdOf(q.recommended)] }
				: {}),
			options: q.options.map((o, i) => ({
				id: optionIdOf(i),
				label: o.label,
				...(o.description !== undefined ? { description: o.description } : {}),
				...(o.preview !== undefined ? { preview: o.preview } : {}),
			})),
			// The native dialog always offers "Other (type your own)".
			allowCustom: true,
		};
	}

	async function runAsk(
		invokeTool: (
			params: Record<string, unknown>,
			signal: AbortSignal | undefined,
		) => Promise<{ content: Array<{ type: string; text: string }>; details?: unknown; isError?: boolean }>,
		loopSignal: AbortSignal | undefined,
		params: Record<string, unknown>,
		// Native winner is returned UNCHANGED (isError and any other fields
		// pass through); remote-built results are the native-shaped subset.
	): Promise<{ content: Array<{ type: string; text: string }>; details?: unknown; isError?: boolean; [key: string]: unknown }> {
		const questionsOrError = validateQuestions(params);
		if ("error" in questionsOrError) return errorTextResult(questionsOrError.error);
		const questions = questionsOrError;

		const requestId = randomUUID();
		const generation = bridge.getGeneration();
		const controller = new AbortController();
		// Fold the loop's own turn-abort signal in: a genuine user turn-abort
		// closes the dialog through the same safe delegation-signal path.
		const delegationSignal = loopSignal
			? AbortSignal.any([loopSignal, controller.signal])
			: controller.signal;

		const remote = new Promise<Array<{ answer: RemoteAnswer; question: AskQuestion }>>(resolve => {
			pending.set(requestId, {
				requestId,
				generation,
				seq: ++order,
				questions,
				resolveRemote: resolve,
				controller,
				settled: false,
			});
		});
		const entry = pending.get(requestId)!;
		const interaction: Interaction = {
			requestId,
			generation,
			kind: "question",
			questions: questions.map(toInteractionQuestion),
		};
		safeEmit("interaction.opened", { interaction });

		const nativePromise = invokeTool(params, delegationSignal);
		try {
			// First winner wins. The loser is cancelled SAFELY: aborting the
			// delegation signal makes the native dialog close and the native
			// execute reject WITHOUT the whole-turn context.abort().
			const winner = await Promise.race([
				nativePromise.then(value => ({ source: "native" as const, value })),
				remote.then(value => ({ source: "remote" as const, value })),
			]);
			if (winner.source === "native") {
				settle(entry, "answered", "terminal");
				// Terminal result returned UNCHANGED — content, details, isError,
				// and any other native result fields all pass through untouched.
				return winner.value;
			}
			settle(entry, "answered", "remote");
			controller.abort(); // close the terminal dialog through the safe path
			// Contain the loser's settlement; its result is discarded by design.
			void nativePromise.then(
				() => undefined,
				() => undefined,
			);
			return remoteResult(entry, winner.value);
		} catch (error) {
			// Native rejection: user Esc (native already performed the whole-turn
			// abort, preserved verbatim), turn-abort, or our own safe cancel —
			// indistinguishable here; reported as terminal-side cancellation.
			settle(entry, "cancelled", "terminal");
			throw error;
		}
	}

	const native = findNativeAsk(pi);
	// Register when a native ask builtin is confirmed present, or when the
	// registry cannot be queried at all (execute fails closed to the terminal
	// path either way). With a queryable registry and no native ask builtin,
	// registering a shadow would be strictly worse than absence.
	const shouldRegister = native.hasNative || !native.registryKnown;

	let tool: unknown;
	if (shouldRegister) {
		// Reuse the native builtin's description/parameters VERBATIM when
		// available; otherwise ship the documented fallback mirror (delta 2).
		const description = typeof native.description === "string" ? native.description : FALLBACK_DESCRIPTION;
		const parameters = native.parameters !== null && typeof native.parameters === "object" ? native.parameters : askJsonSchema;
		tool = {
			name: "ask",
			label: "Ask",
			description,
			parameters,
			strict: true,
			approval: "read" as const,
			// Matches the native ask presentation: discoverable, pinned
			// top-level by XDEV_KEEP_TOP_LEVEL, so the model reaches it directly.
			loadMode: "discoverable" as const,
			async execute(
				_toolCallId: string,
				params: Record<string, unknown>,
				signal: AbortSignal | undefined,
				_onUpdate: ((partial: unknown) => void) | undefined,
				ctx: unknown,
			) {
				if (disposed) {
					return errorTextResult(
						"Error: ask adapter is disposed for this session; refusing to open a dialog with no remote counterpart",
					);
				}
				const ectx = ctx as AskExtensionContext;
				if (typeof ectx?.invokeTool !== "function") {
					return errorTextResult(
						"Error: ask adapter cannot delegate to the native ask tool (no native built-in resolved); refusing to answer without the terminal path",
					);
				}
				// Serialize asks only; this does not exclude other tools in the batch.
				const run = tail.then(
					() => runAsk((p, sig) => ectx.invokeTool!(p, { signal: sig }), signal, params),
					() => runAsk((p, sig) => ectx.invokeTool!(p, { signal: sig }), signal, params),
				);
				tail = run.catch(() => undefined);
				return run;
			},
		};
		pi.registerTool(tool);
	}

	// -- broker-routed handlers ---------------------------------------------

	function claimEntry(
		params: unknown,
	): { ok: true; entry: PendingAsk } | { ok: false; verdict: Extract<AskVerdict, { accepted: false }> } {
		if (params === null || typeof params !== "object" || Array.isArray(params)) {
			return { ok: false, verdict: { accepted: false, code: "invalid_request", message: "params must be an object" } };
		}
		const { requestId } = params as { requestId?: unknown };
		if (typeof requestId !== "string" || requestId.length === 0) {
			return { ok: false, verdict: { accepted: false, code: "invalid_request", message: "requestId (string) is required" } };
		}
		pruneStale();
		const entry = pending.get(requestId);
		if (entry === undefined) {
			const settled = settledLog.get(requestId);
			if (settled !== undefined) {
				return {
					ok: false,
					verdict: {
						accepted: false,
						code: "item_changed",
						message: `ask ${requestId} already settled (${settled.outcome})`,
					},
				};
			}
			return { ok: false, verdict: { accepted: false, code: "item_not_found", message: `no pending ask ${requestId}` } };
		}
		if (entry.generation !== bridge.getGeneration()) {
			// Belt and suspenders: pruneStale covers this, but the generation
			// could be bumped concurrently between prune and here.
			settle(entry, "expired", "terminal");
			entry.controller.abort();
			return {
				ok: false,
				verdict: { accepted: false, code: "stale_generation", message: `ask ${requestId} belongs to an invalidated generation` },
			};
		}
		return { ok: true, entry };
	}

	function answer(params: unknown): AskVerdict {
		const claimed = claimEntry(params);
		if (!claimed.ok) return claimed.verdict;
		const entry = claimed.entry;
		const answers = (params as { answers?: unknown }).answers;
		const verdict = validateAnswers(entry, answers);
		if (!verdict.ok) {
			return { accepted: false, code: "invalid_request", message: verdict.detail };
		}
		// First valid claim wins synchronously: a duplicate concurrent answer
		// sees item_changed even before the race resumes.
		settle(entry, "answered", "remote");
		entry.resolveRemote(verdict.pairs);
		return { accepted: true };
	}

	function cancel(params: unknown): AskVerdict {
		const claimed = claimEntry(params);
		if (!claimed.ok) return claimed.verdict;
		const entry = claimed.entry;
		// Remote cancel mirrors the user gesture only as far as the ask call:
		// the safe delegation-signal abort cancels the dialog and the tool call
		// WITHOUT the whole-turn abort a terminal Esc performs.
		settle(entry, "cancelled", "remote");
		entry.controller.abort();
		return { accepted: true };
	}

	return {
		registered: tool !== undefined,
		listPending() {
			pruneStale();
			const generation = bridge.getGeneration();
			const entries = [...pending.values()]
				.filter(p => p.generation === generation)
				.sort((a, b) => a.seq - b.seq);
			return {
				pending: entries.map(p => ({
					requestId: p.requestId,
					generation: p.generation,
					kind: "question" as const,
					questions: p.questions.map(toInteractionQuestion),
				})),
			};
		},
		answer,
		cancel,
		expiredGeneration(generation?: number) {
			// Non-terminal lifecycle invalidation: expire the pending asks of
			// the given generation (default: current), leave the wrapper tool
			// armed for the new generation. Idempotent per entry.
			const gen = generation ?? bridge.getGeneration();
			for (const entry of [...pending.values()]) {
				if (entry.generation === gen) {
					settle(entry, "expired", "terminal");
					entry.controller.abort();
				}
			}
		},
		dispose() {
			disposed = true;
			for (const entry of [...pending.values()]) {
				settle(entry, "expired", "terminal");
				entry.controller.abort();
			}
		},
	};
}
