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

/** One content block of a structured user message (omp extension API). */
type ContentBlock =
	| { type: "text"; text: string }
	| { type: "image"; data: string; mimeType: string };

/** The pi (ExtensionAPI) surface this adapter uses. */
interface LocalPi {
	on(event: string, handler: (event: unknown, ctx: LocalCtx) => void | Promise<void>): void;
	/** Content array form verified against the installed omp build (18.2.6):
	 *  session.sendUserMessage splits text blocks into the prompt string and
	 *  passes non-text blocks ({type:'image',data:<base64>,mimeType}) as
	 *  images. Options: attribution is echoed verbatim into the committed
	 *  user record (verified live) — the send-correlation origin token
	 *  rides it. */
	sendUserMessage(content: string | ContentBlock[], options?: { attribution?: string }): void;
	getCommands(): Array<{ name: string; description?: string; source?: string; location?: string; path?: string }>;
	logger?: { warn: (...args: unknown[]) => void };
	/** Present in current omp builds; optional so older hosts still load. */
	registerTool?(tool: unknown): void;
	getAllTools?(): ReadonlyArray<AskNativeToolInfo>;
	/** Durable hidden custom entry (omp: sessionManager.appendCustomEntry).
	 *  Used for send-correlation markers; optional so older hosts still load. */
	appendEntry?(customType: string, data: unknown): string | undefined;
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
/** Bound on pending send-correlation markers (a stuck FIFO cannot grow unbounded). */
const PENDING_SENDS_MAX = 64;
/** Bound on the session-branch walk when resolving a committed record id. */
const RECORD_SCAN_MAX = 200;

export default function ompChatAdapterExtension(pi: LocalPi): void {
	const log = (...args: unknown[]) => pi.logger?.warn("[omp-chat-adapter]", ...args);
	const instanceId = randomUUID();

	// -- registration state ---------------------------------------------------
	let generation = 1;
	let sessionId = "";
	let sessionName: string | undefined;
	let sessionFile: string | undefined;
	/** True when this session is an omp task-subagent (nested session file). */
	let isSubagent = false;
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

	/**
	 * Broker-originated sends awaiting their committed user record, in send
	 * order. At each user message_end the committed record's ORIGIN TOKEN
	 * (a structured attribution echoed verbatim by omp into the committed
	 * record) identifies which send landed — never text matching.
	 */
	const pendingSends: Array<{ requestKey: string; token: string }> = [];

	/**
	 * Origin token prefix: the adapter marks every broker-originated send's
	 * attribution with this prefix + the requestKey; omp echoes the
	 * attribution verbatim into the committed user record (verified live
	 * against omp 18.2.6). A committed record carrying this token provably
	 * came from THIS send — terminal-typed messages and same-text twins can
	 * never steal a key.
	 */
	const SEND_TOKEN_PREFIX = "heeler-chat:send:";

	/** requestKey carried in the send's origin token, if this is ours. */
	function tokenRequestKey(entry: { type: string; message?: { attribution?: unknown; role?: string } } | undefined): string | undefined {
		const attribution = entry?.message?.attribution;
		if (typeof attribution !== "string" || !attribution.startsWith(SEND_TOKEN_PREFIX)) return undefined;
		const requestKey = attribution.slice(SEND_TOKEN_PREFIX.length);
		return requestKey.length > 0 ? requestKey : undefined;
	}
	/** The most recent user-role message_end EVENT payload (this generation). */
	let lastUserMessageEnd: { message?: { role?: string; attribution?: unknown; content?: unknown; timestamp?: unknown } } | null = null;

	/**
	 * Token-proven sends whose record id could not be resolved at message_end
	 * time (omp persists the session tree ASYNCHRONOUSLY after dispatching
	 * message_end to extensions — the leaf can be stale mid-persistence).
	 * Bounded by PENDING_SENDS_MAX; retried once at turn_end, when persistence
	 * has settled; dropped honestly (with a log) if still unresolvable.
	 */
	const deferredConfirmations: Array<{ requestKey: string; message: unknown }> = [];

	/**
	 * Resolve the REAL committed record id for a token-proven send.
	 *
	 * Ladder: (1) session-tree lookup — the newest user entry whose attribution
	 * equals the event message's token IS the committed record (the token is
	 * unguessable per send; same-text twins carry different tokens); (2) a
	 * bounded scan over the session branch from the leaf (getEntry/parentId
	 * walk) when the newest-token entry is not the leaf (marker/other entries
	 * can sit newer); (3) give up for now and defer to turn_end — never bind a
	 * provisional id.
	 */
	function resolveRecordId(
		ctx: LocalCtx | null,
		requestKey: string,
		eventMessage: { attribution?: unknown },
		diagnoseSend: (where: string, detail: Record<string, unknown>) => void,
	): string | undefined {
		const sm = ctx?.sessionManager ?? currentCtx?.sessionManager;
		if (sm === undefined) {
			diagnoseSend("no-sessionManager", {});
			return undefined; // deferring is useless without a session manager
		}
		const token = eventMessage.attribution;
		if (typeof token !== "string") return undefined;
		// Walk the branch newest->oldest from the leaf; the first message entry
		// whose attribution equals the token is the committed record. Bounded by
		// RECORD_SCAN_MAX; a token entry deeper than that defers to turn_end.
		let entryId: string | null | undefined = sm.getLeafId();
		for (let i = 0; i < RECORD_SCAN_MAX && typeof entryId === "string"; i++) {
			const entry = sm.getEntry(entryId);
			if (entry === undefined) break;
			if (entry.type === "message" && entry.message?.role === "user" && entry.message.attribution === token) {
				return entryId;
			}
			entryId = (entry as { parentId?: string | null }).parentId;
		}
		diagnoseSend("record-not-in-tree-yet", { scanned: RECORD_SCAN_MAX });
		return undefined;
	}

	/**
	 * Bind a token-proven send to its REAL committed record id: durable hidden
	 * marker (pi.appendEntry, consumed by the read-side history attach) plus
	 * the live send.confirmed event. Absent appendEntry (older host) the live
	 * event still fires; only the durable read-side attach degrades.
	 */
	function confirmSend(
		recordKey: string,
		recordId: string,
		diagnoseSend: (where: string, detail: Record<string, unknown>) => void,
	): void {
		if (pi.appendEntry !== undefined) {
			try {
				pi.appendEntry("heeler-chat.send.confirmed", { requestKey: recordKey, recordId, timestamp: new Date().toISOString() });
			} catch (error) {
				diagnoseSend("marker-write-failed", { error: String(error) });
				log("send-correlation marker write failed:", String(error));
			}
		}
		diagnoseSend("confirmed", { requestKey: recordKey, recordId });
		emitEvent("send.confirmed", { requestKey: recordKey, recordId });
	}

	/**
	 * Correlate the just-committed user record to its broker-originated send.
	 *
	 * Origin is PROVEN structurally: broker sends carry an attribution token
	 * omp echoes into the committed record. A record without the token (a
	 * terminal-typed message) confirms nothing and consumes no key. The
	 * token names ITS requestKey, so same-text sends correlate to their OWN
	 * records — two identical prompts get distinct, correct confirmations.
	 * On a match the REAL committed record id is bound durably (hidden
	 * marker entry via pi.appendEntry, consumed by the read-side history
	 * attach) and announced live via the send.confirmed event.
	 */
	function correlateCommittedSend(ctx: LocalCtx | null): void {
		if (pendingSends.length === 0) return; // terminal-origin: nothing to confirm
		// Live diagnostics for the silent failure observed against omp 18.2.6
		// (committed record carried the token, yet no marker/confirmed fired):
		// pi.logger is absent in embedded hosts, so log() was a no-op and every
		// early return invisible. Each guard now mirrors its inputs to stderr.
		// Gated by HEELER_CHAT_DEBUG=1; production pays one env check.
		const debug = process.env.HEELER_CHAT_DEBUG === "1";
		const diagnoseSend = (where: string, detail: Record<string, unknown>) => {
			if (!debug) return;
			try {
				process.stderr.write(
					`[omp-chat-adapter] correlateCommittedSend/${where} pending=${pendingSends.length} ${JSON.stringify(detail)}\n`,
				);
			} catch {
				// stderr is best-effort; never break the correlation path.
			}
		};
		const eventMessage = lastUserMessageEnd?.message; // the event's OWN user message
		if (eventMessage === undefined) {
			// No user message_end seen this generation (should not happen: the
			// handler is only invoked from the user message_end path).
			diagnoseSend("no-user-message_end", {});
			return;
		}
		const eventKey = tokenRequestKey({ type: "message", message: eventMessage as { attribution?: unknown } });
		if (eventKey === undefined) {
			// The event message carries no token — either a terminal-typed message
			// (expected; confirms nothing) or a host that strips attribution from
			// event messages. Fall back to the committed LEAF entry: the newest
			// session record, whose attribution (omp persists it verbatim) is the
			// same origin proof. A stale leaf simply fails the token check and
			// confirms nothing — the send stays pending for its own record.
			const sm = ctx?.sessionManager ?? currentCtx?.sessionManager;
			if (sm === undefined) {
				diagnoseSend("tokenless-event-no-sessionManager", {});
				return;
			}
			const leafId = sm.getLeafId();
			const leafEntry = leafId === null ? undefined : sm.getEntry(leafId);
			if (leafEntry === undefined || leafEntry.type !== "message" || leafEntry.message?.role !== "user") {
				diagnoseSend("tokenless-event-bad-leaf", { leafId: leafId ?? null });
				return;
			}
			const leafKey = tokenRequestKey(leafEntry as { type: string; message?: { attribution?: unknown } });
			if (leafKey === undefined) {
				diagnoseSend("tokenless-user-record", { attribution: String(leafEntry.message?.attribution ?? "?") });
				return; // terminal message (no token): confirms nothing
			}
			const leafMatch = pendingSends.findIndex(s => s.requestKey === leafKey);
			if (leafMatch === -1) {
				diagnoseSend("unknown-requestKey", { recordKey: leafKey });
				log("send-correlation token for unknown requestKey:", leafKey);
				return;
			}
			pendingSends.splice(leafMatch, 1);
			confirmSend(leafKey, leafId as string, diagnoseSend);
			return;
		}
		const recordKey = eventKey;
		const match = pendingSends.findIndex(s => s.requestKey === recordKey);
		if (match === -1) {
			diagnoseSend("unknown-requestKey", { recordKey });
			log("send-correlation token for unknown requestKey:", recordKey);
			return; // honest absence: never bind a key we did not queue
		}
		pendingSends.splice(match, 1);
		// Record id resolution: prefer the persisted session entry (authoritative);
		// fall back to a bounded wait for the asynchronous persistence (omp
		// dispatches message_end to extensions BEFORE the session-tree append
		// it schedules on its #He chain has landed), and finally defer to
		// turn_end (persistence has settled by then) — the fallback ladder
		// guarantees the REAL record id, never a provisional one.
		const recordId = resolveRecordId(ctx, recordKey, eventMessage, diagnoseSend);
		if (recordId === undefined) {
			// Persistence has not landed the record in the session tree yet; the
			// turn_end retry resolves it after the turn settles.
			if (deferredConfirmations.length < PENDING_SENDS_MAX) {
				deferredConfirmations.push({ requestKey: recordKey, message: eventMessage });
			} else {
				log("send-correlation deferral overflow; dropping", recordKey);
			}
			return;
		}
		confirmSend(recordKey, recordId, diagnoseSend);
	}

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
			attachments: true,
			branches: false,
			// v2 slice 1 (agent details): live context/model telemetry +
			// explicit model changes. Requires a model-bearing ctx (older
			// omp builds without ctx.model/modelRegistry register without it).
			telemetry: telemetryReady,
		};
	}

	function registrationFrame(): unknown {
		const locator: Record<string, unknown> = { pid: process.pid };
		// Pane ownership: ONLY the pane's primary agent claims its paneId. A
		// task-subagent inherits HERDR_PANE_ID from the parent process but its
		// session is a nested child — claiming the parent pane would stack
		// duplicate live pane registrations and the app's matcher correctly
		// refuses (ambiguous). Subagents register without a pane claim.
		if (!isSubagent && process.env.HERDR_PANE_ID !== undefined && process.env.HERDR_PANE_ID.length > 0) {
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


	// -- structured prompt content (attachments) ------------------------------

	/** Wire shape of one entry of prompt.send params.images. */
	interface PromptImage {
		ref?: unknown;
		mimeType?: unknown;
		byteLength?: unknown;
		data?: unknown;
	}

	/** Image mime types the installed omp build accepts (image validator `ic`). */
	const IMAGE_MIME_TYPES: Record<string, true> = {
		"image/png": true,
		"image/jpeg": true,
		"image/gif": true,
		"image/webp": true,
	};

	/**
	 * Validate params.images and resolve each entry to a base64 payload:
	 * inline `data` (base64 string) or a `ref` into this session's blob store
	 * (the same `img:` refs blob.read serves). Throws HistoryError on any bad
	 * entry; an absent images array yields undefined (text-only send).
	 */
	function resolvePromptImages(raw: unknown): Array<{ data: string; mimeType: string }> | undefined {
		if (raw === undefined) return undefined;
		if (!Array.isArray(raw) || raw.length === 0) {
			throw new HistoryError("invalid_request", "images must be a non-empty array when present");
		}
		if (history === null) {
			throw new HistoryError("session_unavailable", "session context not yet available");
		}
		const out: Array<{ data: string; mimeType: string }> = [];
		for (const entryRaw of raw as PromptImage[]) {
			if (typeof entryRaw !== "object" || entryRaw === null) {
				throw new HistoryError("invalid_request", "each images entry must be an object");
			}
			const entry = entryRaw;
			if (typeof entry.mimeType !== "string" || IMAGE_MIME_TYPES[entry.mimeType] !== true) {
				throw new HistoryError(
					"invalid_request",
					`mimeType must be one of png/jpeg/gif/webp (got ${String(entry.mimeType)})`,
				);
			}
			if (entry.data !== undefined && entry.ref !== undefined) {
				throw new HistoryError("invalid_request", "each images entry must set exactly one of data or ref");
			}
			let data: string;
			if (entry.data !== undefined) {
				if (typeof entry.data !== "string" || entry.data.length === 0) {
					throw new HistoryError("invalid_request", "data must be a non-empty base64 string");
				}
				data = entry.data;
			} else if (entry.ref !== undefined) {
				if (typeof entry.ref !== "string" || entry.ref.length === 0) {
					throw new HistoryError("invalid_request", "ref must be a non-empty blob id");
				}
				// Resolve through the same blob store blob.read serves; a bad ref
				// must reject the whole prompt (never a silent text-only send).
				data = history.readBlobAll(entry.ref);
			} else {
				throw new HistoryError("invalid_request", "each images entry must set data or ref");
			}
			if (entry.byteLength !== undefined && typeof entry.byteLength !== "number") {
				throw new HistoryError("invalid_request", "byteLength must be a number when present");
			}
			out.push({ data, mimeType: entry.mimeType });
		}
		return out;
	}

	/**
	 * prompt.send content: the text-only path is the exact string (identical
	 * call as before); with images, a content array — text block first, then
	 * image blocks — matching omp's sendUserMessage content-array contract.
	 * Image-only drafts carry an EMPTY text block (live-verified: omp commits
	 * the record with an empty text block + the image and runs the turn; no
	 * filler text is fabricated).
	 */
	function buildPromptContent(text: string, rawImages: unknown): string | ContentBlock[] {
		const images = resolvePromptImages(rawImages);
		if (images === undefined) return text;
		const content: ContentBlock[] = [{ type: "text", text }];
		for (const img of images) content.push({ type: "image", data: img.data, mimeType: img.mimeType });
		return content;
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
					// text may be EMPTY when images carry the content (image-only
					// draft); a genuinely empty submission — no text AND no
					// images — is invalid_request. No filler text is fabricated.
					if (typeof params.text !== "string") {
						throw new HistoryError("invalid_request", "text (string) is required");
					}
					const hasImages = Array.isArray(params.images) && params.images.length > 0;
					if (params.text.length === 0 && !hasImages) {
						throw new HistoryError("invalid_request", "text and images are both empty; nothing to send");
					}
					if (typeof params.requestKey !== "string" || params.requestKey.length === 0) {
						throw new HistoryError("invalid_request", "requestKey (non-empty string) is required");
					}
					if (dedupSeen.has(params.requestKey)) {
						respond(frame.id, { accepted: true, requestKey: params.requestKey }); // idempotent replay
						return;
					}
					const content = buildPromptContent(params.text, params.images);
					dedupSeen.add(params.requestKey);
					if (dedupSeen.size > DEDUP_MAX) {
						const oldest = dedupSeen.keys().next().value;
						if (typeof oldest === "string") dedupSeen.delete(oldest);
					}
					// Queue for send-correlation: the ORIGIN TOKEN rides this
					// send's attribution (omp echoes it verbatim into the
					// committed record), so the committed record provably
					// corresponds to THIS invocation — never a same-text twin
					// or a terminal-typed message.
					const token = SEND_TOKEN_PREFIX + params.requestKey;
					if (pendingSends.length < PENDING_SENDS_MAX) pendingSends.push({ requestKey: params.requestKey, token });
					// Text-only send: identical string call as before (byte for
					// byte); structured send: content ARRAY so images reach the
					// provider as real image content, not inline text. The second
					// arg is omp's documented options object (attribution
					// passthrough verified live against 18.2.6).
					pi.sendUserMessage(content, { attribution: token });
					// NOTE: no session.changed here — per-turn activity must not trigger a
					// client resync; turn lifecycle is covered by message.* + history.changed.
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
					const available = ctx.modelRegistry?.getAvailable?.() ?? [];
					const match = available.find(m => typeof m === "object" && m !== null && m.provider + "/" + m.id === id);
					if (match === undefined) {
						respondError(frame.id, "invalid_request", "unknown model " + id);
						return;
					}
					// The fit gate needs the TARGET's window — compare AFTER
					// the lookup (the earlier pre-lookup reference was wrong:
					// the window compared against nothing, so the gate
					// silently never refused; proven by the live probe).
					const matchWindow = typeof (match as Record<string, unknown>).contextWindow === "number"
						? ((match as Record<string, unknown>).contextWindow as number)
						: undefined;
					if (matchWindow !== undefined && usedTokens > matchWindow) {
						respondError(frame.id, "invalid_request", `the reported context (${Math.round(usedTokens)} tokens) exceeds this model's window (${matchWindow}); nothing will be trimmed automatically`);
						return;
					}
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

				case "command.invoke": {
					// v3 (structured commands): explicit invocation by opaque
					// catalog id; acceptance-only delivery semantics — NEVER
					// send.confirmed (the text-match origin proof structurally
					// cannot confirm a command; design §4a).
					if (typeof params.commandId !== "string" || params.commandId.length === 0) {
						throw new HistoryError("invalid_request", "commandId (non-empty string) is required");
					}
					if (typeof params.requestKey !== "string" || params.requestKey.length === 0) {
						throw new HistoryError("invalid_request", "requestKey (non-empty string) is required");
					}
					if (Array.isArray(params.arguments)) {
						for (const a of params.arguments) {
							if (typeof a !== "string") {
								throw new HistoryError("invalid_request", "arguments must be an array of strings");
							}
						}
					} else if (params.arguments !== undefined) {
						throw new HistoryError("invalid_request", "arguments must be an array of strings when present");
					}
					// Shared per-session requestKey namespace: the same bounded
					// dedup cache prompt.send uses, cleared on generation bump.
					if (dedupSeen.has(params.requestKey)) {
						respond(frame.id, { accepted: true, requestKey: params.requestKey }); // idempotent replay
						return;
					}
					// Closed gate, honestly: omp's extension API exposes no
					// command-execution surface (sendUserMessage hardcodes
					// expandPromptTemplates:false; AgentSession.prompt is not
					// exposed) — the catalog is insert-only, so invocation is
					// refused rather than degraded to a prompt (never a silent
					// text fallback). Revisit when upstream omp ships an
					// execution API; the key is NOT consumed by the refusal.
					respondError(frame.id, "unsupported_capability", "this session's commands are insert-only; no command execution surface is available");
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
		// Subagent detection (omp): a task-subagent's session file lives
		// INSIDE a directory named after the parent session's .jsonl file
		// (verified live: .../<parent>.jsonl/<subagent>.jsonl with a
		// parentSession header). Subagents inherit HERDR_PANE_ID from the
		// parent process, so without this check each subagent would claim
		// the PARENT'S pane and the app's pane matcher correctly refuses
		// (ambiguous). Subagents still register (chat works) — they just
		// never claim a pane.
		isSubagent = sessionFile !== undefined && sessionFile.includes(".jsonl/");
	}

	/** Bump generation: clear per-generation state, reset seq, fresh socket. */
	function bumpGeneration(ctx: LocalCtx, reason: string): void {
		ask?.expiredGeneration(generation);
		generation += 1;
		seq = 0;
		throughSeq = 0;
		dedupSeen.clear();
		pendingSends.length = 0; // old-session sends never confirm in the new one
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

	pi.on("message_end", (event, ctx) => {
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
		if (role === "user") {
			// Remember the EVENT's own message: correlateCommittedSend matches
			// on it (omp dispatches message_end with the exact message it
			// commits; the session tree can lag because omp persists it
			// asynchronously AFTER the extension dispatch).
			lastUserMessageEnd = event as { message?: { role?: string; attribution?: unknown; content?: unknown; timestamp?: unknown } };
			correlateCommittedSend(ctx ?? null);
			lastUserMessageEnd = null; // never reused across message_end dispatches
		}
		if (role === "assistant" || role === "user" || role === "toolResult") {
			emitEvent("history.changed", { revision });
		}
	});

	pi.on("session_compact", () => {
		revision = `rev:${randomUUID()}`;
		emitEvent("history.changed", { revision });
	});

	pi.on("turn_end", () => {
		// Deferred send-correlation retry: omp persists the session tree
		// asynchronously after message_end dispatch, so a token-proven send
		// whose record id was not resolvable at message_end time retries here,
		// once, after the turn (persistence has settled). Still unresolvable
		// sends are dropped honestly — a later snapshot would rebind them only
		// by guesswork, which the contract forbids.
		for (const deferred of deferredConfirmations.splice(0)) {
			const message = deferred.message as { attribution?: unknown };
			const recordKey = tokenRequestKey({ type: "message", message });
			if (recordKey === undefined) continue;
			const sm = currentCtx?.sessionManager;
			if (sm === undefined) continue;
			const token = message.attribution;
			if (typeof token !== "string") continue;
			let entryId: string | null | undefined = sm.getLeafId();
			let resolved: string | undefined;
			for (let i = 0; i < RECORD_SCAN_MAX && typeof entryId === "string"; i++) {
				const entry = sm.getEntry(entryId);
				if (entry === undefined) break;
				if (entry.type === "message" && entry.message?.role === "user" && entry.message.attribution === token) {
					resolved = entryId;
					break;
				}
				entryId = (entry as { parentId?: string | null }).parentId;
			}
			if (resolved === undefined) {
				log("send-correlation could not resolve record id at turn_end for", recordKey);
				continue;
			}
			confirmSend(recordKey, resolved, () => {});
		}
		revision = `rev:${randomUUID()}`;
		emitEvent("history.changed", { revision });
	});
}
