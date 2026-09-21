/**
 * omp -> agent-chat broker adapter extension (contract v1).
 *
 * Loads in any installed omp via `omp -e <path>/extension.ts` — node stdlib +
 * relative ./history (and optional ./ask) imports only, no SDK npm install.
 * Connects OUTBOUND to the broker's Unix socket (env HEELER_CHAT_SOCKET),
 * performs the hello/welcome handshake, registers, then serves routed client
 * methods over PUBLIC omp extension APIs only: ctx.sessionManager consumed
 * read-only, pi.sendUserMessage, pi.abort (via ctx), pi.getCommands. No
 * onEntryAppended, no private fields, no omp source patching.
 *
 * Generation semantics: a session identity / branch / tree / switch change
 * bumps the generation, resets seq, clears prompt dedup + provisional streams
 * + pending interactions, and re-dials a FRESH socket so `register` is its
 * first frame. Events carry strictly increasing seq per registration; the
 * broker preserves it and the snapshot `throughSeq` watermark equals the
 * latest emitted seq at page-build time (computed synchronously).
 *
 * Interactions are OFF unless HEELER_CHAT_ASK_WRAPPER=1 opts this session
 * into the ask wrapper (adapters/omp/ask, owned separately); the registration
 * capability bit and methods only exist when it is installed.
 */
import * as net from "node:net";
import { randomUUID } from "node:crypto";
import {
	HistoryError,
	HistoryService,
	type SessionReader,
} from "./history.ts";
import { FrameReader } from "../../src/frame.mjs";
import { installAskAdapter, type AskAdapter, type AskNativeToolInfo } from "./ask.ts";

// ---------------------------------------------------------------------------
// Structural types for the public extension API (no package imports)
// ---------------------------------------------------------------------------

/** The ctx passed to event handlers — the fields this adapter uses. */
interface LocalCtx {
	mode: string;
	sessionManager: SessionReader & {
		getSessionFile?: () => string | undefined;
		getSessionName?: () => string | undefined;
	};
	isIdle(): boolean;
	abort(): void;
}

/** The pi (ExtensionAPI) surface this adapter uses. */
interface LocalPi {
	on(event: string, handler: (event: unknown, ctx: LocalCtx) => void | Promise<void>): void;
	sendUserMessage(content: string): void;
	getCommands(): Array<{ name: string; description?: string; source?: string; location?: string; path?: string }>;
	logger?: { warn: (...args: unknown[]) => void };
	/** Present in current omp builds; optional so older hosts still load. */
	registerTool?(tool: unknown): void;
	getAllTools?(): ReadonlyArray<AskNativeToolInfo>;
	/** Public @oh-my-pi/pi-utils VERSION re-export; optional for older hosts. */
	readonly VERSION?: string;
}

/** The broker->adapter routed request frame (validated upstream by protocol.mjs). */
interface RoutedRequest {
	type: "request";
	id: string;
	method: string;
	target?: { instanceId: string; generation: number };
	params?: Record<string, unknown>;
}


// ---------------------------------------------------------------------------
// Wire constants (must match sibling src/protocol.mjs)
// ---------------------------------------------------------------------------

const PROTOCOL_VERSION = 1;
const MAX_FRAME_BYTES = 1024 * 1024;
/** Broker's own welcome cap; our inbound frames obey the same bound. */
const ERROR_CODES: ReadonlyArray<string> = [
	"invalid_request",
	"unsupported_protocol",
	"unsupported_capability",
	"session_unavailable",
	"ambiguous_session",
	"stale_generation",
	"stale_cursor",
	"cursor_invalid",
	"item_not_found",
	"item_changed",
	"budget_too_small",
	"too_many_inflight",
	"overloaded",
	"timeout",
	"internal_error",
];

/** Bounded outgoing queue: events are droppable (with resync), control is not. */
const QUEUE_MAX_FRAMES = 512;
const QUEUE_MAX_BYTES = 4 * 1024 * 1024;
const RECONNECT_MIN_MS = 250;
const RECONNECT_MAX_MS = 5_000;
/** Prompt requestKey dedup cache bound, per generation. */
const DEDUP_MAX = 512;

export default function ompChatAdapterExtension(pi: LocalPi): void {
	const log = (...args: unknown[]) => pi.logger?.warn("[omp-chat-adapter]", ...args);
	const instanceId = randomUUID();

	// -- registration state ---------------------------------------------------
	let generation = 1;
	let sessionId = "";
	let sessionName: string | undefined;
	let sessionFile: string | undefined;
	let seq = 0; // zero is the empty snapshot watermark; first event is one
	/** Latest emitted event seq — the snapshot `throughSeq` watermark. */
	let throughSeq = 0;
	/** Monotonic revision string, bumped on durable history mutation (event paths only, never lazily). */
	let revision = `rev:${randomUUID()}`;
	let history: HistoryService | null = null;
	let ask: AskAdapter | null = null;

	/** Prompt requestKey dedup, bounded per generation. */
	const dedupSeen = new Set<string>();
	/** Provisional stream IDs in flight; cleared on generation change. */
	const activeStreams = new Set<string>();

	// -- socket + bounded outgoing queue ---------------------------------------
	let socket: net.Socket | null = null;
	let connected = false;
	let registeredAck = false;
	let reconnectTimer: NodeJS.Timeout | null = null;
	let reconnectDelay = RECONNECT_MIN_MS;
	const queue: Array<{ frame: unknown; bytes: number; isEvent: boolean }> = [];
	let queuedBytes = 0;
	let droppedEvents = 0;
	/** Sticky resync marker: queued as the NEXT event frame once there is room. */
	let resyncPending: { reason: string; dropped: number } | null = null;
	let writeBlocked = false;
	let reader: FrameReader | null = null;
	let shuttingDown = false;

	const frameBytes = (frame: unknown): number => Buffer.byteLength(JSON.stringify(frame), "utf8");

	function nextSeq(): number {
		seq += 1;
		throughSeq = seq;
		return seq;
	}

	// -- telemetry (v2 slice 1: agent details / model / compaction) ---------

	/** True once a session_start ctx exposed model/usage surfaces. */
	let telemetryReady = false;

	/** Structurally-typed ctx for the telemetry surfaces (all optional-checked at use). */
	interface TelemetryCtx {
		model?: unknown;
		models?: unknown;
		modelRegistry?: unknown;
		getContextUsage?: unknown;
		sessionManager?: { getCwd?: unknown };
	}

	/** The catalog entry the wire carries: ONLY documented fields, never whole host objects. */
	function projectModel(m: unknown): Record<string, unknown> | null {
		if (typeof m !== "object" || m === null) return null;
		const e = m as Record<string, unknown>;
		if (typeof e.id !== "string" || typeof e.provider !== "string") return null;
		const out: Record<string, unknown> = {
			id: e.id,
			provider: e.provider,
			...(typeof e.name === "string" ? { name: e.name } : {}),
			...(typeof e.contextWindow === "number" ? { contextWindow: e.contextWindow } : {}),
			...(typeof e.maxTokens === "number" ? { maxTokens: e.maxTokens } : {}),
			...(Array.isArray(e.input) ? { input: e.input.filter((x): x is string => typeof x === "string") } : {}),
			...(typeof e.reasoning === "boolean" ? { reasoning: e.reasoning } : {}),
			// Tool-calling support: the omp catalog carries no explicit
			// per-model tools boolean — the field stays ABSENT unless a
			// future catalog reports one, so clients render "Not reported"
			// rather than a guessed value.
			...(typeof e.supportsTools === "boolean" ? { supportsTools: e.supportsTools } : {}),
		};
		if (typeof e.cost === "object" && e.cost !== null) {
			const c = e.cost as Record<string, unknown>;
			const cost: Record<string, number> = {};
			for (const k of ["input", "output", "cacheRead", "cacheWrite"] as const) {
				if (typeof c[k] === "number") cost[k] = c[k];
			}
			if (Object.keys(cost).length > 0) out.cost = cost;
		}
		return out;
	}

	/** session.telemetry snapshot: honest fields only; absent surfaces stay absent. */
	function telemetrySnapshot(ctx: TelemetryCtx): Record<string, unknown> {
		const out: Record<string, unknown> = {};
		// Host ctx getters can throw while session state is mid-restore; each
		// surface is read defensively so one bad getter degrades to honest
		// absence instead of killing the request.
		let model: unknown;
		try {
			model = ctx.model;
		} catch {
			model = undefined;
		}
		const projected = projectModel(model);
		if (projected !== null) out.model = projected;

		if (typeof ctx.getContextUsage === "function") {
			// The host method can throw mid-restore (internal state not yet
			// seeded); an honest absent field beats a dead request.
			try {
				const usage = (ctx.getContextUsage as () => unknown)();
				if (typeof usage === "object" && usage !== null) {
					const u = usage as Record<string, unknown>;
					const reported: Record<string, unknown> = {};
					if (typeof u.tokens === "number") reported.tokens = u.tokens;
					if (typeof u.contextWindow === "number") reported.contextWindow = u.contextWindow;
					if (Object.keys(reported).length > 0) out.context = reported;
				}
			} catch {
				/* honest absence */
			}
		}
		try {
			const cwd = ctx.sessionManager?.getCwd;
			if (typeof cwd === "function") {
				const value = (cwd as () => unknown)();
				if (typeof value === "string" && value.length > 0) out.cwd = value;
			}
		} catch {
			/* honest absence */
		}
		return out;
	}

	function capabilities(): Record<string, boolean> {
		return {
			history: true,
			streaming: true,
			prompt: true,
			interrupt: true,
			interactions: ask?.registered === true,
			commands: true,
			attachments: false,
			branches: false,
			// v2 slice 1 (agent details): live context/model telemetry +
			// explicit model changes. Requires a model-bearing ctx (older
			// omp builds without ctx.model/modelRegistry register without it).
			telemetry: telemetryReady,
		};
	}

	function registrationFrame(): unknown {
		const locator: Record<string, unknown> = { pid: process.pid };
		if (process.env.HERDR_PANE_ID !== undefined && process.env.HERDR_PANE_ID.length > 0) {
			locator.paneId = process.env.HERDR_PANE_ID;
		}
		if (sessionFile !== undefined) locator.sessionFile = sessionFile;
		return {
			type: "register",
			registration: {
				instanceId,
				sessionId,
				generation,
				agent: { kind: "omp", version: pi.VERSION ?? "unknown" },
				...(sessionName !== undefined && sessionName.length > 0 ? { title: sessionName } : {}),
				locator,
				capabilities: capabilities(),
			},
		};
	}

	/** Handshake + register on a fresh socket; no requests served before `registered`. */
	function connect(): void {
		const sockPath = process.env.HEELER_CHAT_SOCKET;
		if (!sockPath || shuttingDown) return; // no broker configured: adapter stays dormant
		const sock = net.connect(sockPath);
		socket = sock;
		sock.setNoDelay(true);
		sock.on("connect", () => {
			connected = true;
			writeBlocked = false;
			reconnectDelay = RECONNECT_MIN_MS;
			registeredAck = false;
			reader = new FrameReader({
				maxBytes: MAX_FRAME_BYTES,
				onFrame: obj => {
					handleFrame(obj as Record<string, unknown>);
					return true;
				},
			});
			sock.write(JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, peer: "adapter" }) + "\n");
			flush();
		});
		sock.on("drain", () => {
			writeBlocked = false;
			flush();
		});
		sock.on("data", (chunk: Buffer) => {
			if (reader === null || !reader.push(chunk)) sock.destroy(); // fail closed
		});
		const onDown = () => {
			if (socket !== sock) return;
			connected = false;
			registeredAck = false;
			socket = null;
			reader = null;
			isolateQueueForReconnect();
			scheduleReconnect();
		};
		sock.on("close", onDown);
		sock.on("error", () => {
			/* close handler performs the reconnect */
		});
	}

	/** Broker->adapter frames: welcome, registered, routed requests, error. */
	function handleFrame(frame: Record<string, unknown>): void {
		switch (frame.type) {
			case "welcome": {
				if (frame.protocol !== PROTOCOL_VERSION || frame.maxFrameBytes !== MAX_FRAME_BYTES) {
					log("incompatible broker welcome");
					socket?.destroy();
					return;
				}
				// Protocol 1 / 1MiB cap; the broker's own validators enforce it.
				// Runs only from the 'data' path of a connected socket.
				socket?.write(JSON.stringify(registrationFrame()) + "\n");
				return;
			}
			case "registered": {
				registeredAck = true;
				maybeQueueResync(); // a marker pending from before disconnect goes out
				flush();
				return;
			}
			case "request": {
				handleRequest(frame as unknown as RoutedRequest);
				return;
			}
			case "error": {
				log("broker error:", JSON.stringify(frame.error));
				return;
			}
			default:
				return; // lenient: unknown frames ignored
		}
	}
	// -- bounded outgoing queue ------------------------------------------------

	function send(frame: unknown, isEvent = false): void {
		const bytes = frameBytes(frame);
		if (queue.length >= QUEUE_MAX_FRAMES || queuedBytes + bytes > QUEUE_MAX_BYTES) {
			if (isEvent) {
				droppedEvents++;
				if (resyncPending === null) resyncPending = { reason: "event_queue_overflow", dropped: droppedEvents };
				maybeQueueResync();
				return; // never block host handlers on a full queue
			}
			// Control frames may evict oldest events…
			while (
				queue.length > 0 &&
				queue[0].isEvent &&
				(queue.length >= QUEUE_MAX_FRAMES || queuedBytes + bytes > QUEUE_MAX_BYTES)
			) {
				const evicted = queue.shift()!;
				queuedBytes -= evicted.bytes;
				droppedEvents++;
				if (resyncPending === null) resyncPending = { reason: "event_queue_overflow", dropped: droppedEvents };
			}
			if (queuedBytes + bytes > QUEUE_MAX_BYTES || queue.length >= QUEUE_MAX_FRAMES) {
				// NEVER silently drop a control response: answer explicitly so the
				// broker correlation does not hang; if even the reject cannot be
				// queued, close the socket (broker marks the route unavailable).
				const id = (frame as { id?: unknown }).id;
				const reject = {
					type: "response",
					...(typeof id === "string" ? { id } : {}),
					error: { code: "overloaded", message: "adapter outgoing queue full; re-open a fresh snapshot", retryable: false },
				};
				const rejectBytes = frameBytes(reject);
				if (queue.length < QUEUE_MAX_FRAMES && queuedBytes + rejectBytes <= QUEUE_MAX_BYTES) {
					queue.push({ frame: reject, bytes: rejectBytes, isEvent: false });
					queuedBytes += rejectBytes;
					flush();
				} else {
					socket?.destroy();
				}
				return;
			}
		}
		queue.push({ frame, bytes, isEvent });
		queuedBytes += bytes;
		maybeQueueResync();
		flush();
	}

	/** Queue the pending resync marker as the NEXT event frame once room exists. */
	function maybeQueueResync(): void {
		if (resyncPending === null || !registeredAck) return;
		const gapFrame = {
			type: "event",
			instanceId,
			generation, // bound now; a generation change while pending re-marks it
			seq: nextSeq(),
			event: { type: "resync_required", reason: resyncPending.reason, dropped: resyncPending.dropped },
		};
		const gapBytes = frameBytes(gapFrame);
		if (queue.length >= QUEUE_MAX_FRAMES || queuedBytes + gapBytes > QUEUE_MAX_BYTES) return; // stays pending
		queue.push({ frame: gapFrame, bytes: gapBytes, isEvent: true });
		queuedBytes += gapBytes;
		resyncPending = null; // cleared only when actually queued
		flush();
	}

	/**
	 * Queue isolation on channel loss: a reconnect starts a NEW generation of
	 * the wire, so nothing queued for the OLD channel may go out on the new
	 * one. Events are dropped (counted; a resync marker is owed); request
	 * responses are replaced by an explicit channel-lost reject.
	 */
	function isolateQueueForReconnect(): void {
		for (const { frame, bytes } of queue.splice(0)) {
			queuedBytes -= bytes;
			if ((frame as { type?: string }).type === "event") {
				droppedEvents++;
				if (resyncPending === null) resyncPending = { reason: "event_queue_overflow", dropped: droppedEvents };
			}
		}
	}

	function flush(): void {
		if (writeBlocked || !connected || !registeredAck || socket === null) return;
		while (queue.length > 0) {
			const item = queue[0];
			const ok = socket.write(JSON.stringify(item.frame) + "\n");
			queue.shift();
			queuedBytes -= item.bytes;
			if (!ok) {
				writeBlocked = true;
				return; // resume on 'drain'
			}
		}
		maybeQueueResync();
	}

	/** A generation change must destroy the old connection and dial a fresh one. */
	function reregister(): void {
		clearTimeout(reconnectTimer!);
		reconnectTimer = null;
		isolateQueueForReconnect();
		if (socket !== null) {
			const old = socket;
			socket = null;
			connected = false;
			registeredAck = false;
			old.removeAllListeners("close");
			old.destroy();
		}
		connect();
	}

	function scheduleReconnect(): void {
		if (reconnectTimer !== null || shuttingDown) return;
		reconnectTimer = setTimeout(() => {
			reconnectTimer = null;
			connect();
		}, reconnectDelay);
		reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
	}

	// -- responses --------------------------------------------------------------

	function respond(id: string, result?: unknown, error?: { code: string; message: string; retryable: boolean }): void {
		send(error === undefined ? { type: "response", id, result } : { type: "response", id, error });
	}

	function respondError(id: string, code: string, message: string): void {
		if (!ERROR_CODES.includes(code)) code = "internal_error";
		respond(id, undefined, { code, message, retryable: false });
	}

	// -- routed request handling -------------------------------------------------

	async function handleRequest(frame: RoutedRequest): Promise<void> {
		if (typeof frame.id !== "string" || typeof frame.method !== "string") return;
		if (!registeredAck) {
			respondError(frame.id, "session_unavailable", "adapter not registered on this connection");
			return;
		}
		const target = frame.target;
		if (
			target !== undefined &&
			(target.instanceId !== instanceId || target.generation !== generation)
		) {
			respondError(
				frame.id,
				"stale_generation",
				`request targets instance ${target.instanceId} generation ${target.generation}; this adapter is instance ...${instanceId.slice(-6)} generation ${generation}`,
			);
			return;
		}
		const params = frame.params ?? {};
		try {
			switch (frame.method) {
				case "history.open":
				case "history.before": {
					if (history === null) throw new HistoryError("session_unavailable", "session context not yet available");
					const meta = { sessionId, generation, revision, throughSeq };
					const page = frame.method === "history.open" ? history.openPage(meta, params) : history.beforePage(meta, params);
					respond(frame.id, page);
					return;
				}
				case "item.read": {
					if (history === null) throw new HistoryError("session_unavailable", "session context not yet available");
					respond(frame.id, history.readItemChunk(params));
					return;
				}
				case "blob.read": {
					if (history === null) throw new HistoryError("session_unavailable", "session context not yet available");
					respond(frame.id, history.readBlobChunk(params));
					return;
				}
				case "prompt.send": {
					if (typeof params.text !== "string" || params.text.length === 0) {
						throw new HistoryError("invalid_request", "text (non-empty string) is required");
					}
					if (typeof params.requestKey !== "string" || params.requestKey.length === 0) {
						throw new HistoryError("invalid_request", "requestKey (non-empty string) is required");
					}
					if (dedupSeen.has(params.requestKey)) {
						respond(frame.id, { accepted: true, requestKey: params.requestKey }); // idempotent replay
						return;
					}
					dedupSeen.add(params.requestKey);
					if (dedupSeen.size > DEDUP_MAX) {
						const oldest = dedupSeen.keys().next().value;
						if (typeof oldest === "string") dedupSeen.delete(oldest);
					}
					pi.sendUserMessage(params.text);
					emitEvent("session.changed", {});
					respond(frame.id, { accepted: true, requestKey: params.requestKey });
					return;
				}
				case "interrupt": {
					currentCtx?.abort();
					respond(frame.id, { interrupted: true });
					return;
				}
				case "session.telemetry": {
					// The routed request carries the broker-validated target; the
					// live snapshot comes from the current ctx (it IS the session).
					const snapshot = currentCtx === null ? {} : telemetrySnapshot(currentCtx as unknown as TelemetryCtx);
					respond(frame.id, snapshot);
					return;
				}
				case "models.list": {
					if (!telemetryReady || currentCtx === null) {
						respondError(frame.id, "unsupported_capability", "this session does not expose model telemetry");
						return;
					}
					const registry = (currentCtx as unknown as TelemetryCtx).modelRegistry as
						| { getAvailable?: () => unknown[] }
						| undefined;
					if (typeof registry?.getAvailable !== "function") {
						respondError(frame.id, "unsupported_capability", "model registry is not readable on this session");
						return;
					}
					const models = registry
						.getAvailable()
						.map(projectModel)
						.filter((m): m is Record<string, unknown> => m !== null);
					respond(frame.id, { models });
					return;
				}
				case "model.set": {
					if (!telemetryReady) {
						respondError(frame.id, "unsupported_capability", "this session does not support model changes");
						return;
					}
					if (currentCtx === null) {
						respondError(frame.id, "session_unavailable", "session context not yet available");
						return;
					}
					const id = params.id;
					if (typeof id !== "string" || id.length === 0) {
						throw new HistoryError("invalid_request", "id (non-empty string) is required");
					}
					const ctx = currentCtx as unknown as TelemetryCtx & {
						isIdle?: () => boolean;
						modelRegistry?: { getAvailable?: () => Array<Record<string, unknown>> };
					};
					// Never auto-interrupt: a busy turn is an honest refusal.
					if (typeof ctx.isIdle === "function" && !ctx.isIdle()) {
						respondError(frame.id, "invalid_request", "the agent is working; finish or stop the current turn before changing models");
						return;
					}
					// Authoritative context-fit gate: the UI promises "Nothing
					// will be trimmed, compacted or discarded automatically" —
					// so the switch itself must REFUSE when the live reported
					// usage exceeds the target window. A usage reading that
					// cannot be verified is also an honest refusal (never a
					// blind switch).
					let usage: unknown;
					try {
						usage = (ctx as unknown as TelemetryCtx).getContextUsage?.();
					} catch {
						usage = undefined;
					}
					let usedTokens: number | undefined;
					if (typeof usage === "object" && usage !== null) {
						const t = (usage as Record<string, unknown>).tokens;
						if (typeof t === "number" && Number.isFinite(t)) usedTokens = t;
					}
					if (usedTokens === undefined) {
						respondError(frame.id, "invalid_request", "context usage could not be verified; refusing the switch (nothing will be trimmed automatically)");
						return;
					}
					const targetWindow = typeof target.contextWindow === "number" ? target.contextWindow : undefined;
					if (targetWindow !== undefined && usedTokens > targetWindow) {
						respondError(frame.id, "invalid_request", `the reported context (${Math.round(usedTokens)} tokens) exceeds this model's window (${targetWindow}); nothing will be trimmed automatically`);
						return;
					}
					const available = ctx.modelRegistry?.getAvailable?.() ?? [];
					const match = available.find(m => typeof m === "object" && m !== null && m.provider + "/" + m.id === id);
					// Method call MUST stay bound to pi: the host implementation
					// reads `this.ctx`/`this.runtime` — a detached call loses
					// `this` and dies as an internal TypeError (proven live).
					const setModelFn = (pi as unknown as { setModel?: (m: unknown) => Promise<boolean> }).setModel?.bind(pi);
										if (match === undefined || typeof setModelFn !== "function") {
						respondError(frame.id, "invalid_request", "unknown model " + id);
						return;
					}
					// setModel touches host internals (API-key lookup, session
					// switch); any throw is a rejection, never a crash.
					let switched: boolean;
					try {
						switched = (await setModelFn(match)) === true;
					} catch (error) {
												switched = false;
					}
					const currentModel = () => {
						try {
							return projectModel((currentCtx as unknown as TelemetryCtx).model);
						} catch {
							return null;
						}
					};
					if (switched !== true) {
						// Provider/adapter rejected (no auth or unavailable): the
						// agent keeps its current model — the client's pending
						// state resolves as rejected with the old model retained.
						respond(frame.id, { switched: false, reason: "rejected", model: currentModel() });
						return;
					}
					revision = `rev:${randomUUID()}`;
					emitEvent("history.changed", { revision });
					respond(frame.id, { switched: true, model: currentModel() });
					return;
				}
				case "commands.list": {
					// pi.getCommands returns DYNAMIC commands only (SlashCommandInfo:
					// name/description/source/location/path) — never invent builtins.
					respond(frame.id, {
						complete: false,
						commands: pi.getCommands().map(c => ({
							id: c.name,
							label: c.name,
							...(typeof c.description === "string" && c.description.length > 0 ? { description: c.description } : {}),
							execution: { kind: "insert", text: `/${c.name}` },
						})),
					});
					return;
				}
				case "interactions.list": {
					if (ask === null) {
						respondError(frame.id, "unsupported_capability", "interactions not installed on this session");
						return;
					}
					respond(frame.id, ask.listPending());
					return;
				}
				case "interactions.answer": {
					if (ask === null) {
						respondError(frame.id, "unsupported_capability", "interactions not installed on this session");
						return;
					}
					const verdict = ask.answer(params);
					if (!verdict.accepted) respondError(frame.id, verdict.code, verdict.message);
					else respond(frame.id, verdict);
					return;
				}
				case "interactions.cancel": {
					if (ask === null) {
						respondError(frame.id, "unsupported_capability", "interactions not installed on this session");
						return;
					}
					const verdict = ask.cancel(params);
					if (!verdict.accepted) respondError(frame.id, verdict.code, verdict.message);
					else respond(frame.id, verdict);
					return;
				}
				default:
					respondError(frame.id, "invalid_request", `unknown method ${frame.method}`);
			}
		} catch (error) {
			if (error instanceof HistoryError) respondError(frame.id, error.code, error.message);
			else respondError(frame.id, "internal_error", String(error));
		}
	}

	// -- ordered live events -------------------------------------------------------

	function emitEvent(type: string, payload: Record<string, unknown>): void {
		// Provisional live events; durable truth is always the history page.
		send({ type: "event", instanceId, generation, seq: nextSeq(), event: { type, ...payload } }, true);
	}

	function messageRole(message: unknown): string | undefined {
		if (typeof message === "object" && message !== null) return (message as { role?: string }).role;
		return undefined;
	}

	/** Assistant streaming delta: {text, contentIndex, blockType}. */
	interface DeltaShape {
		delta?: string;
		contentIndex?: number;
	}

	function blockTypeOf(ev: unknown): "text" | "thinking" | undefined {
		const t = (ev as { type?: string }).type;
		return t === "text_delta" ? "text" : t === "thinking_delta" ? "thinking" : undefined;
	}

	// -- lifecycle -----------------------------------------------------------------

	let currentCtx: LocalCtx | null = null;

	function refreshSession(ctx: LocalCtx): void {
		currentCtx = ctx;
		// v2 telemetry: gate on the ctx surfaces actually existing (older
		// hosts lack model/getContextUsage; they honestly register
		// telemetry:false and clients render the unsupported state).
		const tc = ctx as unknown as TelemetryCtx;
		telemetryReady =
			tc.model !== undefined &&
			typeof tc.getContextUsage === "function" &&
			tc.modelRegistry !== undefined;
		sessionId = ctx.sessionManager.getSessionId();
		history = new HistoryService(ctx.sessionManager);
		sessionName = ctx.sessionManager.getSessionName?.();
		const file = ctx.sessionManager.getSessionFile?.();
		sessionFile = typeof file === "string" && file.length > 0 ? file : undefined;
	}

	/** Bump generation: clear per-generation state, reset seq, fresh socket. */
	function bumpGeneration(ctx: LocalCtx, reason: string): void {
		ask?.expiredGeneration(generation);
		generation += 1;
		seq = 0;
		throughSeq = 0;
		dedupSeen.clear();
		activeStreams.clear();
		history?.dispose();
		// A pending resync marker belongs to the OLD wire generation; the new
		// generation's first history.open is the fresh snapshot, so re-mark it.
		if (resyncPending === null) resyncPending = { reason: "generation_change", dropped: 0 };
		refreshSession(ctx);
		revision = `rev:${randomUUID()}`; // identity change invalidates every cursor
		reregister(); // fresh socket so register is its first frame
		emitEvent("session.changed", { reason, sessionId, generation });
		log(`generation -> ${generation} (${reason})`);
	}

	function installAsk(): void {
		if (!pi.registerTool || ask !== null) return;
		ask = installAskAdapter({
			registerTool: pi.registerTool.bind(pi),
			...(typeof pi.getAllTools === "function" ? { getAllTools: pi.getAllTools.bind(pi) } : {}),
		}, { emit: emitEvent, getGeneration: () => generation });
	}

	pi.on("session_start", (event, ctx) => {
		refreshSession(ctx);
		installAskIfNeeded();
		if (!connected) connect();
	});

	function installAskIfNeeded(): void {
		if (ask === null && process.env.HEELER_CHAT_ASK_WRAPPER === "1") installAsk();
	}

	pi.on("session_switch", (_e, ctx) => bumpGeneration(ctx, "session_switch"));
	pi.on("session_branch", (_e, ctx) => bumpGeneration(ctx, "session_branch"));
	pi.on("session_tree", (_e, ctx) => bumpGeneration(ctx, "session_tree"));

	pi.on("session_shutdown", () => {
		shuttingDown = true; // terminal: no reconnect leak after the host process is done
		clearTimeout(reconnectTimer!);
		reconnectTimer = null;
		connected = false;
		registeredAck = false;
		reader = null;
		ask?.dispose();
		socket?.end();
		socket = null;
	});

	// -- streaming + durable-change events ------------------------------------------

	pi.on("agent_start", (_e, ctx) => {
		currentCtx = ctx;
		emitEvent("session.changed", {});
	});

	pi.on("message_start", (event, ctx) => {
		currentCtx = ctx;
		const role = messageRole((event as { message?: unknown }).message);
		if (role !== "assistant") return;
		const streamId = `stream:${randomUUID()}`;
		activeStreams.add(streamId);
		emitEvent("message.started", { streamId, author: { role: "assistant" } });
	});

	pi.on("message_update", event => {
		const ev = (event as { assistantMessageEvent?: DeltaShape }).assistantMessageEvent;
		if (ev === undefined) return;
		const blockType = blockTypeOf(ev);
		if (blockType === undefined) return;
		if (typeof ev.delta !== "string" || ev.delta.length === 0) return;
		// Provisional delta: streamId is adapter-generated per in-flight message.
		// There is exactly one active assistant stream per session instance.
		const streamId = lastStreamId();
		if (streamId === null) return;
		emitEvent("message.delta", {
			streamId,
			blockIndex: typeof ev.contentIndex === "number" ? ev.contentIndex : 0,
			blockType,
			text: ev.delta,
		});
	});

	function lastStreamId(): string | null {
		let last: string | null = null;
		for (const id of activeStreams) last = id;
		return last;
	}

	pi.on("message_end", event => {
		const role = messageRole((event as { message?: unknown }).message);
		// Durable history mutation: bump revision so clients reconcile.
		revision = `rev:${randomUUID()}`;
		if (role === "assistant") {
			const streamId = lastStreamId();
			if (streamId !== null) {
				activeStreams.delete(streamId);
				emitEvent("message.finished", { streamId });
			}
		}
		if (role === "assistant" || role === "user" || role === "toolResult") {
			emitEvent("history.changed", { revision });
		}
	});

	pi.on("session_compact", () => {
		revision = `rev:${randomUUID()}`;
		emitEvent("history.changed", { revision });
	});

	pi.on("turn_start", () => emitEvent("session.changed", {}));
	pi.on("turn_end", () => {
		revision = `rev:${randomUUID()}`;
		emitEvent("history.changed", { revision });
	});
}
