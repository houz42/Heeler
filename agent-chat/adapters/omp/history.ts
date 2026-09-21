/**
 * Normalized omp session history (agent-chat contract v1).
 *
 * THE canonical omp SessionEntry -> ChatItem/Block mapping lives here and only
 * here (never in broker or UI). Walks the public ReadonlySessionManager entry
 * tree newest->oldest via getLeafId/getEntry parent links — no whole-history
 * snapshots, no filesystem reads, no omp parentId knowledge leaked to clients.
 *
 * Pages are budget-capped on the FULL serialized result (maxBytes); an item
 * that cannot fit is replaced losslessly by a `reference` item the client
 * resolves through item.read (chunked canonical JSON). Image payloads are
 * never inlined: blocks carry a `ref` blobId resolved through blob.read
 * (raw bytes). Chunk sequences verify per-item consistency and fail with an
 * explicit `item_changed` instead of serving mixed-provenance bytes.
 */
import { createHash } from "node:crypto";

// ---------------------------------------------------------------------------
// Structural reader types (public ReadonlySessionManager subset; no package
// imports so the installed omp/Bun loads this file without an SDK install).
// ---------------------------------------------------------------------------

export interface SessionReader {
	getSessionId(): string;
	getLeafId(): string | null;
	getEntry(id: string): SessionEntryLike | undefined;
}

/** Structural subset of the public SessionEntry wire shapes this module maps. */
export interface SessionEntryLike {
	type: string;
	id: string;
	parentId: string | null;
	timestamp: string;
	message?: MessageLike;
	// custom_message entries (content is a string OR a block array)
	content?: unknown;
	customType?: string;
	display?: boolean;
	details?: unknown;
	data?: unknown;
	// compaction
	summary?: string;
	shortSummary?: string;
	firstKeptEntryId?: string;
	tokensBefore?: number;
	tokensAfter?: number;
	method?: string;
	warning?: string;
	// branch_summary
	fromId?: string;
}

export interface MessageLike {
	role: string;
	content?: unknown;
	timestamp?: number;
	model?: string;
	toolCallId?: string;
	toolName?: string;
	isError?: boolean;
	customType?: string;
	display?: boolean;
}

// ---------------------------------------------------------------------------
// Normalized domain (contract ChatItem / Block unions)
// ---------------------------------------------------------------------------

export type Block =
	| { type: "text"; text: string }
	| { type: "thinking"; text: string }
	| { type: "tool_call"; callId: string; name: string; arguments: unknown }
	| { type: "tool_result"; callId: string; name?: string; isError: boolean; content: Block[] }
	| { type: "image"; mimeType: string; ref: string; byteLength?: number }
	| { type: "unsupported"; label: string };

export interface Author {
	role: "user" | "assistant" | "system" | "tool";
	name?: string;
}

export type ChatItem =
	| {
			id: string;
			kind: "message";
			author: Author;
			createdAt?: string;
			blocks: Block[];
			status: "committed";
	  }
	| {
			id: string;
			kind: "boundary";
			boundary: "compaction" | "branch" | "reset";
			summary?: string;
			olderAvailable: boolean;
			// v2 slice 1 (agent details): compaction measurements, present only
			// on compaction boundaries whose session entry reported them. The
			// base v1 fields stay the contract; clients decode leniently.
			occurredAt?: string;
			trigger?: string;
			tokensBefore?: number;
			tokensAfter?: number;
	  }
	| { id: string; kind: "notice"; text: string; level: "info" | "warning" | "error" }
	| { id: string; kind: "unsupported"; sourceType: string; label: string }
	| { id: string; kind: "reference"; itemKind: "message" | "boundary" | "notice" | "unsupported"; byteLength: number };

// ---------------------------------------------------------------------------
// Errors (stable contract codes)
// ---------------------------------------------------------------------------

export type HistoryErrorCode =
	| "invalid_request"
	| "stale_cursor"
	| "cursor_invalid"
	| "item_not_found"
	| "item_changed"
	| "budget_too_small"
	| "internal_error";

export class HistoryError extends Error {
	readonly code: HistoryErrorCode;
	constructor(code: HistoryErrorCode, message: string) {
		super(message);
		this.name = "HistoryError";
		this.code = code;
	}
}

// ---------------------------------------------------------------------------
// Limits (contract): limit <= 100, page result <= 512 KiB, chunk <= 64 KiB raw.
// ---------------------------------------------------------------------------

export const LIMIT_DEFAULT = 50;
export const LIMIT_MAX = 100;
export const MAXBYTES_DEFAULT = 256 * 1024;
export const MAXBYTES_MAX = 512 * 1024;
export const CHUNK_MAX = 64 * 1024;
/** Reserved for the page envelope (ids, generation, revision, cursor, digits). */
const ENVELOPE_RESERVE = 512;
/** Bounded per-generation item/blob consistency tracking. */
const CONSISTENCY_MAX = 1024;

export interface PageMeta {
	sessionId: string;
	generation: number;
	revision: string;
	throughSeq: number;
}

export interface PageResult {
	sessionId: string;
	generation: number;
	revision: string;
	throughSeq: number;
	items: ChatItem[];
	olderCursor: string | null;
}

interface HistoryCursor {
	v: 1;
	sessionId: string;
	entryId: string;
}

// ---------------------------------------------------------------------------
// Entry -> item mapping (full fidelity; budget decisions live in the pager)
// ---------------------------------------------------------------------------

/** Entry types that are deliberately omitted (hidden internal/state records). */
const HIDDEN_ENTRY_TYPES: Record<string, true> = {
	label: true,
	title_change: true,
	model_change: true,
	thinking_level_change: true,
	service_tier_change: true,
	credential_pin: true,
	ttsr_injection: true,
	mode_change: true,
	session_init: true,
	custom: true,
	model_usage: true,
};

/** Blob ref scope: 'c' = message-entry content, 'x' = custom_message entry content. */
function imageRef(entryId: string, scope: "c" | "x", index: number): string {
	return `img:${entryId}:${scope}:${index}`;
}

/** One raw content block -> typed Block; unknown shapes become explicit `unsupported`. */
function projectBlock(block: unknown, ref: (index: number) => string): Block | null {
	if (typeof block !== "object" || block === null) return null;
	const b = block as Record<string, unknown>;
	switch (b.type) {
		case "text":
			return typeof b.text === "string" && b.text.length > 0 ? { type: "text", text: b.text } : null;
		case "thinking":
			return typeof b.thinking === "string" && b.thinking.length > 0
				? { type: "thinking", text: b.thinking }
				: null;
		case "toolCall":
			return {
				type: "tool_call",
				callId: typeof b.id === "string" ? b.id : "",
				name: typeof b.name === "string" ? b.name : "",
				arguments: b.arguments ?? {},
			};
		case "image": {
			if (typeof b.data !== "string" || typeof b.mimeType !== "string") return null;
			return {
				type: "image",
				mimeType: b.mimeType,
				ref: ref(0), // index filled in by projectContent
				byteLength: Buffer.from(b.data, "base64").length,
			};
		}
		case "redactedThinking":
			return { type: "unsupported", label: "redactedThinking" };
		case "anthropicServerTool":
			return { type: "unsupported", label: "anthropicServerTool" };
		case "fallback":
			return { type: "unsupported", label: "anthropicFallback" };
		default:
			return typeof b.type === "string" ? { type: "unsupported", label: b.type } : null;
	}
}

/** Message content (string or block array) -> typed blocks; image refs address raw array indices. */
function projectContent(content: unknown, refFor: (index: number) => string): Block[] {
	if (typeof content === "string") {
		return content.length === 0 ? [] : [{ type: "text", text: content }];
	}
	if (!Array.isArray(content)) return [];
	const out: Block[] = [];
	for (let i = 0; i < content.length; i++) {
		const block = projectBlock(content[i], refFor);
		if (block !== null) {
			if (block.type === "image") block.ref = refFor(i);
			out.push(block);
		}
	}
	return out;
}

function isoFromMs(ms: unknown): string | undefined {
	return typeof ms === "number" && Number.isFinite(ms) && ms > 0 ? new Date(ms).toISOString() : undefined;
}

/** display=true custom content -> message item; display=false is omitted deliberately. */
function customMessageItem(
	id: string,
	customType: unknown,
	content: unknown,
	scope: "c" | "x",
	createdAt?: string,
): ChatItem[] {
	if (typeof customType !== "string" || customType === "") return [];
	const blocks = projectContent(content, i => imageRef(id, scope, i));
	return [
		{
			id,
			kind: "message",
			author: { role: "system", name: customType },
			...(createdAt !== undefined ? { createdAt } : {}),
			blocks,
			status: "committed",
		},
	];
}

/**
 * Map one session entry to 0..n normalized items (contract mapping).
 * 0 items = deliberately omitted (hidden internal records, display=false).
 * A compaction with a `warning` yields a boundary plus a `warning` notice.
 */
export function projectEntry(reader: SessionReader, entry: SessionEntryLike): ChatItem[] {
	switch (entry.type) {
		case "message": {
			const m = entry.message;
			if (m === undefined) return [];
			if (m.role === "custom" || m.role === "hookMessage") {
				if (m.display !== true) return [];
				return customMessageItem(entry.id, m.customType, m.content, "c", isoFromMs(m.timestamp));
			}
			if (m.role === "toolResult") {
				return [
					{
						id: entry.id,
						kind: "message",
						author: {
							role: "tool",
							...(typeof m.toolName === "string" ? { name: m.toolName } : {}),
						},
						...(isoFromMs(m.timestamp) !== undefined ? { createdAt: isoFromMs(m.timestamp) } : {}),
						blocks: [
							{
								type: "tool_result",
								callId: typeof m.toolCallId === "string" ? m.toolCallId : "",
								...(typeof m.toolName === "string" ? { name: m.toolName } : {}),
								isError: m.isError === true,
								content: projectContent(m.content, i => imageRef(entry.id, "c", i)),
							},
						],
						status: "committed",
					},
				];
			}
			const role: Author["role"] | undefined =
				m.role === "user" ? "user" : m.role === "assistant" ? "assistant" : m.role === "developer" ? "system" : undefined;
			if (role === undefined) {
				return [
					{ id: entry.id, kind: "unsupported", sourceType: `message:${m.role}`, label: `omp message role '${m.role}'` },
				];
			}
			return [
				{
					id: entry.id,
					kind: "message",
					author: {
						role,
						...(role === "assistant" && typeof m.model === "string" && m.model.length > 0 ? { name: m.model } : {}),
					},
					...(isoFromMs(m.timestamp) !== undefined ? { createdAt: isoFromMs(m.timestamp) } : {}),
					blocks: projectContent(m.content, i => imageRef(entry.id, "c", i)),
					status: "committed",
				},
			];
		}
		case "custom_message": {
			if (entry.display !== true) return [];
			return customMessageItem(entry.id, entry.customType, entry.content, "x", entry.timestamp);
		}
		case "compaction": {
			const compactionBoundary = {
				id: entry.id,
				kind: "boundary" as const,
				boundary: "compaction" as const,
				...(typeof entry.summary === "string" && entry.summary.length > 0 ? { summary: entry.summary } : {}),
				olderAvailable: olderAvailable(reader, entry),
				...(typeof entry.timestamp === "string" ? { occurredAt: entry.timestamp } : {}),
				...(typeof entry.method === "string" && entry.method.length > 0 ? { trigger: entry.method } : {}),
				...(typeof entry.tokensBefore === "number" ? { tokensBefore: entry.tokensBefore } : {}),
				...(typeof entry.tokensAfter === "number" ? { tokensAfter: entry.tokensAfter } : {}),
			};
			const items: ChatItem[] = [compactionBoundary];
			if (typeof entry.warning === "string" && entry.warning.length > 0) {
				items.push({ id: `${entry.id}#1`, kind: "notice", text: entry.warning, level: "warning" });
			}
			return items;
		}
		case "branch_summary": {
			return [
				{
					id: entry.id,
					kind: "boundary",
					boundary: "branch",
					...(typeof entry.summary === "string" && entry.summary.length > 0 ? { summary: entry.summary } : {}),
					olderAvailable: olderAvailable(reader, entry),
				},
			];
		}
		case "reset_boundary": {
			return [{ id: entry.id, kind: "boundary", boundary: "reset", olderAvailable: olderAvailable(reader, entry) }];
		}
		default:
			if (HIDDEN_ENTRY_TYPES[entry.type] === true) return [];
			return [
				{
					id: entry.id,
					kind: "unsupported",
					sourceType: entry.type,
					label: `omp session entry type '${entry.type}'`,
				},
			];
	}
}

function olderAvailable(reader: SessionReader, entry: SessionEntryLike): boolean {
	return entry.parentId !== null && reader.getEntry(entry.parentId) !== undefined;
}

// ---------------------------------------------------------------------------
// Sizing helpers
// ---------------------------------------------------------------------------

function sizeOf(value: unknown): number {
	const bytes = Buffer.byteLength(JSON.stringify(value), "utf8");
	return bytes;
}

function clampLimit(raw: unknown): number {
	if (raw === undefined || raw === null) return LIMIT_DEFAULT;
	const n = typeof raw === "number" ? raw : Number(raw);
	if (!Number.isFinite(n) || n <= 0) throw new HistoryError("invalid_request", "limit must be a positive number");
	return Math.min(Math.floor(n), LIMIT_MAX);
}

function clampMaxBytes(raw: unknown): number {
	if (raw === undefined || raw === null) return MAXBYTES_DEFAULT;
	const n = typeof raw === "number" ? raw : Number(raw);
	if (!Number.isFinite(n) || n <= 0) throw new HistoryError("invalid_request", "maxBytes must be a positive number");
	return Math.min(Math.floor(n), MAXBYTES_MAX);
}

// ---------------------------------------------------------------------------
// Cursor codec (opaque on the wire)
// ---------------------------------------------------------------------------

function encodeCursor(cursor: HistoryCursor): string {
	return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

function decodeCursor(encoded: string): HistoryCursor {
	let parsed: unknown;
	try {
		parsed = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
	} catch {
		throw new HistoryError("cursor_invalid", "cursor is not a decodable v1 cursor");
	}
	const c = parsed as Partial<HistoryCursor>;
	if (c?.v !== 1 || typeof c.sessionId !== "string" || typeof c.entryId !== "string" || c.entryId.length === 0) {
		throw new HistoryError("cursor_invalid", "cursor payload does not match the v1 shape");
	}
	return { v: 1, sessionId: c.sessionId, entryId: c.entryId };
}

// ---------------------------------------------------------------------------
// HistoryService: instance-scoped paging + chunk reads with consistency checks
// ---------------------------------------------------------------------------

interface BlobAddress {
	entryId: string;
	scope: "c" | "x";
	index: number;
}

export interface ItemChunk {
	itemId: string;
	encoding: "json-utf8-base64";
	offset: number;
	totalBytes: number;
	data: string;
	nextOffset: number | null;
}

export interface BlobChunk {
	blobId: string;
	encoding: "raw-base64";
	offset: number;
	totalBytes: number;
	data: string;
	nextOffset: number | null;
}

export class HistoryService {
	private readonly reader: SessionReader;
	/** itemId -> canonical-bytes hash for chunk-sequence consistency. */
	private itemHashes: Map<string, string> = new Map();
	/** blobId -> raw-bytes hash for chunk-sequence consistency. */
	private blobHashes: Map<string, string> = new Map();

	constructor(reader: SessionReader) {
		this.reader = reader;
	}

	dispose(): void {
		this.itemHashes.clear();
		this.blobHashes.clear();
	}

	// -- paging --------------------------------------------------------------

	/** history.open: newest page, no cursor. */
	openPage(meta: PageMeta, params: Record<string, unknown>): PageResult {
		const limit = clampLimit(params.limit);
		const maxBytes = clampMaxBytes(params.maxBytes);
		const leafId = this.reader.getLeafId();
		if (leafId === null) {
			return { ...meta, items: [], olderCursor: null };
		}
		return this.pageFrom(meta, leafId, limit, maxBytes);
	}

	/** history.before: continuation from an opaque cursor naming the next unreturned entry. */
	beforePage(meta: PageMeta, params: Record<string, unknown>): PageResult {
		if (typeof params.cursor !== "string" || params.cursor.length === 0) {
			throw new HistoryError("invalid_request", "cursor (non-empty string) is required");
		}
		const limit = clampLimit(params.limit);
		const maxBytes = clampMaxBytes(params.maxBytes);
		const cursor = decodeCursor(params.cursor);
		if (cursor.sessionId !== this.reader.getSessionId()) {
			throw new HistoryError("stale_cursor", "cursor belongs to a different session; reopen a fresh snapshot");
		}
		if (!this.onLeafPath(cursor.entryId)) {
			throw new HistoryError(
				"stale_cursor",
				"cursor entry is no longer on the active leaf path (branched or reset); reopen a fresh snapshot",
			);
		}
		if (this.reader.getEntry(cursor.entryId) === undefined) {
			throw new HistoryError("stale_cursor", "cursor entry no longer exists; reopen a fresh snapshot");
		}
		return this.pageFrom(meta, cursor.entryId, limit, maxBytes);
	}

	private pageFrom(meta: PageMeta, startId: string, limit: number, maxBytes: number): PageResult {
		// Walk newest -> oldest; each ENTRY is embedded atomically (full items, or
		// references when the full group cannot fit, or nothing at all when even
		// references do not fit — that entry becomes the resume cursor).
		const groups: ChatItem[][] = [];
		let used = ENVELOPE_RESERVE;
		let cursorId: string | null = startId;
		let stoppedOn: string | null = null;

		while (cursorId !== null && groups.length < limit) {
			const entry = this.reader.getEntry(cursorId);
			if (entry === undefined) break; // broken chain: stop at the gap
			const items = projectEntry(this.reader, entry);
			if (items.length > 0) {
				const groupBytes = sizeOf(items);
				if (used + groupBytes <= maxBytes) {
					groups.push(items);
					used += groupBytes;
				} else {
					const refs = items.map(item => this.referenceOf(item));
					const refBytes = sizeOf(refs);
					if (used + refBytes <= maxBytes) {
						groups.push(refs);
						used += refBytes;
					} else {
						stoppedOn = entry.id; // nothing of this entry returned
						break;
					}
				}
			}
			cursorId = entry.parentId;
		}

		if (groups.length === 0 && stoppedOn !== null) {
			throw new HistoryError(
				"budget_too_small",
				`maxBytes ${maxBytes} cannot carry one page item plus the page envelope; raise maxBytes`,
			);
		}

		// Chronological order within the page; newest page first is the cursor flow.
		const items = groups.reverse().flat();
		let next: string | null = null;
		if (stoppedOn !== null) {
			next = stoppedOn;
		} else if (cursorId !== null && this.reader.getEntry(cursorId) !== undefined) {
			next = cursorId;
		}
		return { ...meta, items, olderCursor: next === null ? null : encodeCursor({ v: 1, sessionId: meta.sessionId, entryId: next }) };
	}

	private referenceOf(item: ChatItem): ChatItem {
		if (item.kind === "reference") return item;
		return {
			id: item.id,
			kind: "reference",
			itemKind: item.kind as "message" | "boundary" | "notice" | "unsupported",
			byteLength: sizeOf(item),
		};
	}

	private onLeafPath(entryId: string): boolean {
		let cur = this.reader.getLeafId();
		for (let hops = 0; cur !== null && hops < 1_000_000; hops++) {
			if (cur === entryId) return true;
			const entry = this.reader.getEntry(cur);
			if (entry === undefined) return false;
			cur = entry.parentId;
		}
		return false;
	}

	// -- chunked reads ---------------------------------------------------------

	/** item.read: bounded slice of the canonical full ChatItem JSON. */
	readItemChunk(params: Record<string, unknown>): ItemChunk {
		if (typeof params.itemId !== "string" || params.itemId.length === 0) {
			throw new HistoryError("invalid_request", "itemId (non-empty string) is required");
		}
		const item = this.projectItemById(params.itemId);
		const json = Buffer.from(JSON.stringify(item), "utf8");
		this.trackConsistency(this.itemHashes, params.itemId, json);
		const { offset, length } = this.chunkBounds(params, json.length);
		const data = json.subarray(offset, offset + length).toString("base64");
		const nextOffset = offset + length < json.length ? offset + length : null;
		return { itemId: params.itemId, encoding: "json-utf8-base64", offset, totalBytes: json.length, data, nextOffset };
	}

	/** blob.read: bounded slice of raw image bytes referenced by an image Block ref. */
	readBlobChunk(params: Record<string, unknown>): BlobChunk {
		if (typeof params.blobId !== "string" || params.blobId.length === 0) {
			throw new HistoryError("invalid_request", "blobId (non-empty string) is required");
		}
		const address = this.parseBlobId(params.blobId);
		if (address === null) {
			throw new HistoryError("item_not_found", `unknown blob ${params.blobId}`);
		}
		const raw = this.blobBytes(address, params.blobId);
		this.trackConsistency(this.blobHashes, params.blobId, raw);
		const { offset, length } = this.chunkBounds(params, raw.length);
		const data = raw.subarray(offset, offset + length).toString("base64");
		const nextOffset = offset + length < raw.length ? offset + length : null;
		return { blobId: params.blobId, encoding: "raw-base64", offset, totalBytes: raw.length, data, nextOffset };
	}

	/** Re-project the entry and pick the item with this id (supports `#n` extras). */
	private projectItemById(itemId: string): ChatItem {
		const hashIndex = itemId.indexOf("#");
		const entryId = hashIndex === -1 ? itemId : itemId.slice(0, hashIndex);
		const entry = this.reader.getEntry(entryId);
		if (entry === undefined) throw new HistoryError("item_not_found", `item ${itemId} not found`);
		const item = projectEntry(this.reader, entry).find(i => i.id === itemId);
		if (item === undefined) throw new HistoryError("item_not_found", `item ${itemId} not found`);
		return item;
	}

	/** `img:<entryId>:<scope>:<index>` — entryId may itself contain ':'. */
	private parseBlobId(blobId: string): BlobAddress | null {
		if (!blobId.startsWith("img:")) return null;
		const parts = blobId.split(":");
		if (parts.length < 4) return null;
		const index = Number(parts.pop());
		const scope = parts.pop();
		const entryId = parts.slice(1).join(":");
		if ((scope !== "c" && scope !== "x") || !Number.isInteger(index) || index < 0 || entryId.length === 0) return null;
		return { entryId, scope, index };
	}

	private blobBytes(address: BlobAddress, blobId: string): Buffer {
		const entry = this.reader.getEntry(address.entryId);
		if (entry === undefined) throw new HistoryError("item_not_found", `unknown blob ${blobId}`);
		const content =
			address.scope === "c"
				? (entry.message as { content?: unknown } | undefined)?.content
				: entry.content;
		if (!Array.isArray(content)) throw new HistoryError("item_not_found", `unknown blob ${blobId}`);
		const block = content[address.index] as Record<string, unknown> | undefined;
		if (block?.type !== "image" || typeof block.data !== "string") {
			throw new HistoryError("item_not_found", `unknown blob ${blobId}`);
		}
		return Buffer.from(block.data, "base64");
	}


	/**
	 * Full raw base64 payload of a blob (attachments: prompt.send image refs
	 * resolve through the same blob store blob.read serves, in one call).
	 * No consistency tracking: a prompt send is a point-in-time snapshot, not
	 * a chunk sequence.
	 */
	readBlobAll(blobId: string): string {
		const address = this.parseBlobId(blobId);
		if (address === null) {
			throw new HistoryError("item_not_found", `unknown blob ${blobId}`);
		}
		return this.blobBytes(address, blobId).toString("base64");
	}

	private trackConsistency(store: Map<string, string>, id: string, bytes: Buffer): void {
		const hash = createHash("sha256").update(bytes).digest("hex");
		const prior = store.get(id);
		if (prior !== undefined && prior !== hash) {
			throw new HistoryError("item_changed", `${id} changed while its chunk sequence was in flight; restart the read`);
		}
		if (prior === undefined) {
			store.set(id, hash);
			if (store.size > CONSISTENCY_MAX) {
				const oldest = store.keys().next().value;
				if (typeof oldest === "string") store.delete(oldest);
			}
		}
	}

	private chunkBounds(params: Record<string, unknown>, totalBytes: number): { offset: number; length: number } {
		const offset = params.offset === undefined ? 0 : params.offset;
		if (typeof offset !== "number" || !Number.isInteger(offset) || offset < 0 || offset > totalBytes) {
			throw new HistoryError("invalid_request", `offset must be an integer in [0, ${totalBytes}]`);
		}
		const requested = params.length === undefined ? CHUNK_MAX : params.length;
		if (typeof requested !== "number" || !Number.isInteger(requested) || requested <= 0) {
			throw new HistoryError("invalid_request", "length must be a positive integer");
		}
		return { offset, length: Math.min(requested, CHUNK_MAX, totalBytes - offset) };
	}
}
