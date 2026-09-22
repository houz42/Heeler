/**
 * Behavioral tests for the omp history adapter's normalized mapping,
 * paging budgets, cursor semantics, and chunk reads (contract v1).
 * Run with `node --test` after a TS strip, or the repo test runner once
 * Main wires tsconfig — assertions are runtime-shape only.
 */
import * as assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
	HistoryError,
	HistoryService,
	projectEntry,
	type ChatItem,
	type SessionEntryLike,
	type SessionReader,
} from "../adapters/omp/history.ts";

// ---------------------------------------------------------------------------
// Fixtures: an in-memory SessionReader over a hand-built entry tree.
// ---------------------------------------------------------------------------

interface FixtureEntry extends SessionEntryLike {
	raw?: Record<string, unknown>;
}

function makeEntry(partial: Partial<FixtureEntry>): FixtureEntry {
	return {
		type: "message",
		id: randomId(),
		parentId: null,
		timestamp: "2026-09-20T00:00:00.000Z",
		...partial,
	};
}

let counter = 0;
function randomId(): string {
	counter += 1;
	return `e${counter}`;
}

class FixtureReader implements SessionReader {
	private readonly byId: Map<string, FixtureEntry>;
	constructor(entries: FixtureEntry[]) {
		this.byId = new Map(entries.map(e => [e.id, e]));
	}
	getSessionId(): string {
		return "sess-1";
	}
	getLeafId(): string | null {
		// last inserted entry whose parent exists (simple chain fixture)
		const entries = [...this.byId.values()];
		for (let i = entries.length - 1; i >= 0; i--) {
			if (entries[i].parentId === null || this.byId.has(entries[i].parentId!)) return entries[i].id;
		}
		return null;
	}
	getEntry(id: string): SessionEntryLike | undefined {
		return this.byId.get(id);
	}
}

function chain(...entries: FixtureEntry[]): FixtureReader {
	// link in given order: e[i].parentId = e[i-1].id
	for (let i = 1; i < entries.length; i++) entries[i].parentId = entries[i - 1].id;
	return new FixtureReader(entries);
}

const META = { sessionId: "sess-1", generation: 1, revision: "rev:a", throughSeq: 0 };

// ---------------------------------------------------------------------------
// Entry -> ChatItem mapping
// ---------------------------------------------------------------------------

describe("projectEntry", () => {
	const reader = new FixtureReader([]);

	it("maps a user text message to a committed message item with a text block", () => {
		const entry = makeEntry({
			message: { role: "user", content: "hello world", timestamp: 1758300000000 },
		});
		const items = projectEntry(reader, entry);
		assert.equal(items.length, 1);
		const item = items[0] as Extract<ChatItem, { kind: "message" }>;
		assert.equal(item.kind, "message");
		assert.equal(item.author.role, "user");
		assert.equal(item.status, "committed");
		assert.deepEqual(item.blocks, [{ type: "text", text: "hello world" }]);
		assert.equal(item.createdAt, new Date(1758300000000).toISOString());
	});

	it("maps assistant content with thinking, toolCall and image blocks", () => {
		const entry = makeEntry({
			id: "asst1",
			message: {
				role: "assistant",
				content: [
					{ type: "thinking", thinking: "pondering" },
					{ type: "text", text: "answer" },
					{ type: "toolCall", id: "tc1", name: "bash", arguments: { command: "ls" } },
					{ type: "image", data: Buffer.from("pngbytes").toString("base64"), mimeType: "image/png" },
				],
				timestamp: 1758300000000,
				model: "gpt-x",
			},
		});
		const items = projectEntry(reader, entry);
		const item = items[0] as Extract<ChatItem, { kind: "message" }>;
		assert.equal(item.author.role, "assistant");
		assert.equal(item.author.name, "gpt-x");
		assert.deepEqual(item.blocks[0], { type: "thinking", text: "pondering" });
		assert.deepEqual(item.blocks[1], { type: "text", text: "answer" });
		assert.deepEqual(item.blocks[2], { type: "tool_call", callId: "tc1", name: "bash", arguments: { command: "ls" } });
		const image = item.blocks[3] as Extract<ChatItem, never> as unknown as { type: string; ref: string; mimeType: string; byteLength: number };
		assert.equal(image.type, "image");
		assert.equal(image.mimeType, "image/png");
		assert.equal(image.ref, "img:asst1:c:3");
		assert.equal(image.byteLength, 8);
	});

	it("maps a toolResult message to a tool-author item with a tool_result block", () => {
		const entry = makeEntry({
			message: {
				role: "toolResult",
				toolCallId: "tc1",
				toolName: "bash",
				isError: true,
				content: [{ type: "text", text: "boom" }],
				timestamp: 1758300000000,
			},
		});
		const item = projectEntry(reader, entry)[0] as Extract<ChatItem, { kind: "message" }>;
		assert.equal(item.author.role, "tool");
		assert.equal(item.author.name, "bash");
		const block = item.blocks[0] as { type: string; callId: string; isError: boolean; content: unknown[] };
		assert.equal(block.type, "tool_result");
		assert.equal(block.callId, "tc1");
		assert.equal(block.isError, true);
		assert.deepEqual(block.content, [{ type: "text", text: "boom" }]);
	});

	it("omits display:false custom messages and hidden entry types; display:true becomes a system message", () => {
		const hidden = makeEntry({ type: "model_change", model: "x", raw: {} });
		assert.deepEqual(projectEntry(reader, hidden), []);
		const hiddenCustom = makeEntry({ type: "custom", customType: "state", data: { a: 1 } });
		assert.deepEqual(projectEntry(reader, hiddenCustom), []);
		const notDisplayed = makeEntry({ type: "custom_message", customType: "note", content: "secret", display: false });
		assert.deepEqual(projectEntry(reader, notDisplayed), []);
		const displayed = makeEntry({ type: "custom_message", customType: "note", content: "shown", display: true });
		const item = projectEntry(reader, displayed)[0] as Extract<ChatItem, { kind: "message" }>;
		assert.equal(item.author.role, "system");
		assert.equal(item.author.name, "note");
		assert.deepEqual(item.blocks, [{ type: "text", text: "shown" }]);
	});

	it("maps compaction/branch/reset entries to explicit boundaries, warnings to notices", () => {
		const compaction = makeEntry({ type: "compaction", summary: "sum", warning: "tight" });
		const items = projectEntry(reader, compaction);
		assert.equal(items[0].kind, "boundary");
		assert.equal((items[0] as { boundary: string }).boundary, "compaction");
		assert.equal(items[1].kind, "notice");
		assert.equal((items[1] as { level: string }).level, "warning");
		const branch = makeEntry({ type: "branch_summary", fromId: "x", summary: "b" });
		assert.equal((projectEntry(reader, branch)[0] as { boundary: string }).boundary, "branch");
		const reset = makeEntry({ type: "reset_boundary" });
		assert.equal((projectEntry(reader, reset)[0] as { boundary: string }).boundary, "reset");
	});

	it("maps unknown entry and message shapes to explicit unsupported items, never silently dropped", () => {
		const unknownEntry = makeEntry({ type: "future_kind", raw: {} });
		const unsupportedEntry = projectEntry(reader, unknownEntry)[0] as Extract<ChatItem, { kind: "unsupported" }>;
		assert.equal(unsupportedEntry.kind, "unsupported");
		assert.equal(unsupportedEntry.sourceType, "future_kind");
		const unknownRole = makeEntry({ message: { role: "martian", content: "hi" } });
		const unsupportedRole = projectEntry(reader, unknownRole)[0] as Extract<ChatItem, { kind: "unsupported" }>;
		assert.equal(unsupportedRole.sourceType, "message:martian");
	});
});

// ---------------------------------------------------------------------------
// Paging: budget, order, cursors
// ---------------------------------------------------------------------------

describe("HistoryService paging", () => {
	function bigTextMessage(id: string, size: number): FixtureEntry {
		return makeEntry({ id, message: { role: "user", content: "x".repeat(size) } });
	}

	it("returns the newest page in chronological order with an olderCursor to the remainder", () => {
		const entries = [
			bigTextMessage("m1", 10),
			bigTextMessage("m2", 10),
			bigTextMessage("m3", 10),
		];
		const service = new HistoryService(chain(...entries));
		const page = service.openPage(META, {});
		assert.deepEqual(page.items.map(i => i.id), ["m1", "m2", "m3"]);
		assert.equal(page.olderCursor, null);
		assert.equal(page.throughSeq, 0);
	});

	it("respects limit: newest N items only, cursor points at the next unreturned entry", () => {
		const entries = [bigTextMessage("m1", 10), bigTextMessage("m2", 10), bigTextMessage("m3", 10)];
		const service = new HistoryService(chain(...entries));
		const page = service.openPage(META, { limit: 2 });
		assert.deepEqual(page.items.map(i => i.id), ["m2", "m3"]);
		assert.notEqual(page.olderCursor, null);
		const next = service.beforePage(META, { cursor: page.olderCursor! });
		assert.deepEqual(next.items.map(i => i.id), ["m1"]);
		assert.equal(next.olderCursor, null);
	});

	it("replaces an entry group that cannot fit with reference items, lossless via item.read", () => {
		const entries = [
			bigTextMessage("small1", 100),
			bigTextMessage("huge", 300 * 1024),
			bigTextMessage("small2", 100),
		];
		const service = new HistoryService(chain(...entries));
		const page = service.openPage(META, { maxBytes: 1024 });
		// newest-first walk: small2 + reference(huge) fit; small1 is the cursor
		const kinds = page.items.map(i => i.kind);
		assert.equal(kinds[0], "message");
		assert.equal(kinds[1], "reference");
		const ref = page.items[1] as Extract<ChatItem, { kind: "reference" }>;
		assert.equal(ref.itemKind, "message");
		assert.ok(ref.byteLength > 300 * 1024);
		// the reference resolves losslessly through a full item.read chunk drain
		const parts: Buffer[] = [];
		let offset: number | null = 0;
		for (;;) {
			const chunk = service.readItemChunk({ itemId: "huge", offset: offset!, length: 1024 });
			assert.equal(chunk.encoding, "json-utf8-base64");
			parts.push(Buffer.from(chunk.data, "base64"));
			if (chunk.nextOffset === null) break;
			offset = chunk.nextOffset;
		}
		const decoded = JSON.parse(Buffer.concat(parts).toString("utf8")) as {
			id: string;
			blocks: Array<{ text: string }>;
		};
		assert.equal(decoded.id, "huge");
		assert.equal(decoded.blocks[0].text.length, 300 * 1024);
	});

	it("rejects a budget that cannot carry one item with budget_too_small", () => {
		const entries = [bigTextMessage("huge", 300 * 1024)];
		const service = new HistoryService(chain(...entries));
		assert.throws(() => service.openPage(META, { maxBytes: 128 }), (e: unknown) => e instanceof HistoryError && e.code === "budget_too_small");
	});

	it("invalidates cursors across sessions and off-path entries", () => {
		const trunk = [bigTextMessage("t1", 10), bigTextMessage("t2", 10), bigTextMessage("t3", 10)];
		const service = new HistoryService(chain(...trunk));
		const page = service.openPage(META, { limit: 1 });
		const cursor = page.olderCursor!;
		// same session, still on path: cursor entry + the remaining older entries
		const ok = service.beforePage(META, { cursor });
		assert.deepEqual(ok.items.map(i => i.id), ["t1", "t2"]);
		// foreign session cursor: stale_cursor (client must reopen)
		const foreign = Buffer.from(JSON.stringify({ v: 1, sessionId: "other", entryId: "t1" }), "utf8").toString("base64url");
		assert.throws(() => service.beforePage(META, { cursor: foreign }), (e: unknown) => e instanceof HistoryError && e.code === "stale_cursor");
		// undecodable: cursor_invalid
		assert.throws(() => service.beforePage(META, { cursor: "!!!" }), (e: unknown) => e instanceof HistoryError && e.code === "cursor_invalid");
		// branch away: t2/t3 off the leaf path
		const branchedService = new HistoryService(new BranchedReader(trunk, trunk[0].id, bigTextMessage("b1", 10)));
		assert.throws(
			() => branchedService.beforePage(META, { cursor }),
			(e: unknown) => e instanceof HistoryError && e.code === "stale_cursor",
		);
	});

	it("survives pure appends: a cursor issued before new entries stays valid", () => {
		const entries = [bigTextMessage("a1", 10), bigTextMessage("a2", 10)];
		const service = new HistoryService(chain(...entries));
		const page = service.openPage(META, { limit: 1 });
		const grown = chain(...entries, bigTextMessage("a3", 10));
		const grownService = new HistoryService(grown);
		const next = grownService.beforePage(META, { cursor: page.olderCursor! });
		assert.deepEqual(next.items.map(i => i.id), ["a1"]);
	});
});

/** Reader whose leaf diverges from a trunk at `branchParentId`. */
class BranchedReader extends FixtureReader {
	private readonly branchParentId: string;
	private readonly branchEntry: FixtureEntry;
	constructor(trunk: FixtureEntry[], branchParentId: string, branchEntry: FixtureEntry) {
		super(trunk);
		this.branchParentId = branchParentId;
		this.branchEntry = branchEntry;
		branchEntry.parentId = branchParentId;
	}
	override getLeafId(): string | null {
		return this.branchEntry.id;
	}
	override getEntry(id: string): SessionEntryLike | undefined {
		return id === this.branchEntry.id ? this.branchEntry : super.getEntry(id);
	}
}

// ---------------------------------------------------------------------------
// Chunk reads: item.read and blob.read
// ---------------------------------------------------------------------------

describe("HistoryService chunk reads", () => {
	function imageEntry(): FixtureEntry {
		return makeEntry({
			id: "img-entry",
			message: {
				role: "assistant",
				content: [
					{ type: "text", text: "see:" },
					{ type: "image", data: Buffer.from("raw-png-bytes").toString("base64"), mimeType: "image/png" },
				],
				timestamp: 1758300000000,
			},
		});
	}

	it("serves item.read chunks with nextOffset chaining to the full canonical item", () => {
		const service = new HistoryService(chain(imageEntry()));
		const parts: Buffer[] = [];
		let offset: number | null = 0;
		let sawNext = false;
		for (;;) {
			const chunk = service.readItemChunk({ itemId: "img-entry", offset: offset! });
			assert.equal(chunk.encoding, "json-utf8-base64");
			assert.ok(Buffer.from(chunk.data, "base64").length <= 64 * 1024);
			parts.push(Buffer.from(chunk.data, "base64"));
			if (chunk.nextOffset === null) break;
			sawNext = true;
			offset = chunk.nextOffset;
		}
		// a canonical ChatItem with a text block plus an image ref spans two chunks
		assert.ok(sawNext || parts.length === 1);
		const item = JSON.parse(Buffer.concat(parts).toString("utf8")) as Extract<ChatItem, { kind: "message" }>;
		assert.equal(item.kind, "message");
		assert.deepEqual(item.blocks[0], { type: "text", text: "see:" });
		// image block carries a ref, never inline payload bytes
		const image = item.blocks[1] as { type: string; ref: string };
		assert.equal(image.type, "image");
		assert.equal(image.ref, "img:img-entry:c:1");
	});

	it("serves blob.read raw image bytes and fails item_changed on mutation mid-sequence", () => {
		const entry = imageEntry();
		const service = new HistoryService(chain(entry));
		const blobId = "img:img-entry:c:1";
		const first = service.readBlobChunk({ blobId, length: 4 });
		assert.equal(first.encoding, "raw-base64");
		assert.equal(Buffer.from(first.data, "base64").toString("utf8"), "raw-");
		assert.equal(first.totalBytes, 13);
		const rest = service.readBlobChunk({ blobId, offset: first.nextOffset! });
		assert.equal(Buffer.from(rest.data, "base64").toString("utf8"), "png-bytes");
		assert.equal(rest.nextOffset, null);

		// mutate the underlying entry: the next chunk read must fail closed
		entry.message!.content = [
			{ type: "text", text: "see:" },
			{ type: "image", data: Buffer.from("DIFFERENT").toString("base64"), mimeType: "image/png" },
		];
		assert.throws(
			() => service.readBlobChunk({ blobId, offset: 0 }),
			(e: unknown) => e instanceof HistoryError && e.code === "item_changed",
		);
	});

	it("rejects unknown items and blobs with item_not_found, bad params with invalid_request", () => {
		const service = new HistoryService(chain(imageEntry()));
		assert.throws(() => service.readItemChunk({ itemId: "nope" }), (e: unknown) => e instanceof HistoryError && e.code === "item_not_found");
		assert.throws(() => service.readBlobChunk({ blobId: "img:img-entry:c:9" }), (e: unknown) => e instanceof HistoryError && e.code === "item_not_found");
		assert.throws(() => service.readBlobChunk({ blobId: "garbage" }), (e: unknown) => e instanceof HistoryError && e.code === "item_not_found");
		assert.throws(() => service.readItemChunk({ itemId: "img-entry", offset: -1 }), (e: unknown) => e instanceof HistoryError && e.code === "invalid_request");
		assert.throws(() => service.readItemChunk({ itemId: "img-entry", length: 0 }), (e: unknown) => e instanceof HistoryError && e.code === "invalid_request");
	});

	it("bounds requested chunk length to the 64KiB cap", () => {
		const big = makeEntry({
			id: "big",
			message: { role: "user", content: "y".repeat(200 * 1024) },
		});
		const service = new HistoryService(chain(big));
		const chunk = service.readItemChunk({ itemId: "big", length: 200 * 1024 });
		assert.ok(Buffer.from(chunk.data, "base64").length <= 64 * 1024);
		assert.ok(chunk.nextOffset! > 0);
	});
});
