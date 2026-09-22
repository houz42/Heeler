# v3: Structured command invocation + typed image content blocks

Status: PROPOSAL — awaiting Main review. Not a v2 item; nothing here merges
to `integration/redesign-v2`.

## 1. Problem, with evidence

A leading-`/` composer input is delivered to the model as literal prompt
text. The full chain, verified against the v2 tip (89833b13) and omp 18.2.7:

1. `ChatScreen.sendDraft` → `router.submit(text)`
   (`Sources/Heeler/Chat/UI/ChatScreen.swift`).
2. `ComposerRouterStore.submit` classifies `.slash(name, args)`;
   `routeSlash` handles only the client-local table (`/level`, `/follow`)
   and returns `.passthrough` for everything else — comment: "the raw text
   IS the delivery; the agent interprets its own commands"
   (`Sources/Heeler/Chat/Composer/ComposerRouterStore.swift`).
3. `.passthrough` → `deliver(text)` → `AgentChatStore.send(text)`
   → `sendOnWire` → `prompt.send {text, requestKey}`
   (`Sources/Heeler/Chat/Broker/AgentChatStore.swift`).
4. The omp adapter's `prompt.send` handler calls
   `pi.sendUserMessage(params.text)`
   (`agent-chat/adapters/omp/extension.ts`).
5. omp's `AgentSession.sendUserMessage` ends in
   `this.prompt(s, { expandPromptTemplates: false, ... })` — expansion is
   HARDCODED OFF (verified in the omp 18.2.7 binary). The LLM sees
   literal `/exit`.

The agent's own TUI does the opposite: `AgentSession.prompt(text)` with
expansion ON runs, in order: extension commands
(`extensionRunner.getCommand(name).handler(args, ctx)` — `#Bn`), custom
commands (`command.execute(parsedArgs, ctx)` — `#jn`), skill expansion
(`ars`), prompt templates (`lZ`); a command that consumes the input returns
`false` and never reaches the model.

**The wire has no command channel.** `METHOD_CAPABILITIES`
(`agent-chat/src/protocol.mjs`) covers `prompt.send`, `interrupt`, and
`commands.list` (read-only catalog). Nothing executes a command. And the
omp extension API (`pi`) exposes ONLY `sendUserMessage` — no
`prompt`, no command-execution surface — so the adapter cannot implement
command execution today even if the wire had the method.

## 2. Layer split (approved architecture)

- **Transport** — framing, connections, request correlation, error
  taxonomy. Unchanged (`frame.mjs` / `AgentChatChannel` / NDJSON v1).
- **Protocol** — normalized content blocks, command invocation,
  interactions, delivery confirmation, capabilities. This document.
- **Adapters** — translate a structured invocation into the agent's
  native API and normalize replies. NEVER re-serialize intent as text for
  another layer to re-guess.
- **Broker** — agent-agnostic validating router (`broker.mjs` routes by
  `METHOD_CAPABILITIES`, passes params through opaque). No new
  broker-side command semantics.

## 3. The four command kinds — never collapsed

| Kind | Example | Channel | Owner |
|---|---|---|---|
| 1. Literal prompt text | prose, an intentionally-escaped `//text` | `prompt.send` | agent/model |
| 2. Explicitly-selected agent command | `/compact`, a discovered skill | NEW `command.invoke` | adapter |
| 3. Shell execution | `!make test` | client scratch pane (`ComposerBashIO`) | client |
| 4. Client-local UI action | `/level 2`, `/follow agent` | router-local handlers | client |

## 4. `command.invoke` — new client→adapter method

Conservative extension of the existing method table:

```js
// protocol.mjs
METHOD_CAPABILITIES = {
  ...existing,
  'command.invoke': 'commands',   // reuses the existing capability bit
}
```

Request (client → broker → adapter), same envelope as every other method:

```json
{
  "method": "command.invoke",
  "target": { "instanceId": "...", "generation": 1 },
  "params": {
    "commandId": "compact",
    "requestKey": "<uuid>",
    "arguments": ["--keep-recent"]
  }
}
```
Response — acceptance-only semantics (see §4a):

```json
{ "accepted": true, "requestKey": "<uuid>" }
```

Errors use the existing stable codes: `item_not_found` (unknown commandId),
`unsupported_capability`, `stale_generation`, `too_many_inflight`,
`internal_error`. No new codes.

**Rules.**
- `commandId` is an OPAQUE catalog id. The client learns it from
  `commands.list`; the adapter is the only party that maps it to the
  agent-native call. No layer converts an invocation back into `"/name"`
  text for another layer to re-parse.
- `arguments` is ALWAYS an array of strings on the wire (v3 ships exactly
  one element; the catalog's `arguments.kind` is a UI hint, not a wire
  shape).
- Dedup: the requestKey namespace is PER-SESSION GLOBAL across all
  methods — one key must never collide between `prompt.send` and
  `command.invoke`, and the adapter's dedup cache is shared, bounded,
  cleared on generation bump.
- If the agent is mid-turn and the command cannot run concurrently, the
  adapter answers an honest error (or queues per its native semantics) —
  never silently drops to a prompt.

### 4a. Delivery semantics — acceptance only, NEVER send.confirmed

`prompt.send`'s confirmed state is TEXT-MATCH based: the committed user
record must exactly match the sent text (that is the origin proof). A
`command.invoke` lands no user record at all (`/compact`, `/exit`), or
lands TRANSFORMED text (skill/template expansion) — text match can
structurally never confirm it. Therefore `command.invoke` gets
acceptance-only semantics:

- accepted / error is the terminal delivery state; the app's UI keys
  the delivery lifecycle off the method.
- Any content a command produces (a skill that injects a prompt, a
  command's output) arrives through the normal history stream as
  ordinary content — with NO binding to the invocation and no
  `send.confirmed` event for the requestKey.
- If a future need arises to bind a command's committed record to its
  invocation, the durable-marker + read-side-metadata mechanism
  generalizes (a different origin signal than text match) — explicitly
  out of v3 scope; do not promise it now.

### 4b. omp-side gap (blocking, must be reported upstream)

The omp extension API has NO command-execution surface:
`sendUserMessage` hardcodes `expandPromptTemplates: false`, and
`AgentSession.prompt` (the TUI's command path) is not exposed to
extensions. Required upstream addition — either:

- `pi.executeCommand(name, argsString)` on the extension API, or
- `sendUserMessage(text, { expandPromptTemplates: true })` (let the
  adapter drive the TUI-equivalent path).

Until it lands, the omp adapter advertises NO `invoke` commands (the
catalog stays `insert`-only) — capability honesty: the app then degrades
catalog commands to explicit prompt text and never claims a command
executed. Other adapters with a real execution API can light up
`command.invoke` immediately.

## 5. `commands.list` catalog extension

Current adapter response (omp):

```json
{ "complete": false,
  "commands": [ { "id": "review", "label": "review",
                  "description": "...",
                  "execution": { "kind": "insert", "text": "/review" } } ] }
```

`execution.kind` grows one value:

```json
"execution": { "kind": "invoke", "arguments": { "kind": "text" } }
```

- `"insert"` — display/insert only; the client may still offer it, and if
  the user submits it, the client sends it as EXPLICIT prompt text (kind 1)
  with a visible affordance. Honest degrade, not a guess.
- `"invoke"` — executable via `command.invoke` by id. `arguments.kind`
  declares the UI hint; v3 ships exactly `"text"` (one rest string,
  delivered on the wire as a 1-element `arguments` array). No speculative
  universal schema.

## 6. Image content blocks — ordered and typed

Current `prompt.send` params: `{text, requestKey, images?}` where one
image shape mixes three contracts as optional fields (`ref?`, `data?`,
`byteLength?`). v3 normalizes to ordered content blocks:

```json
{
  "method": "prompt.send",
  "params": {
    "requestKey": "<uuid>",
    "content": [
      { "type": "text", "text": "look at this" },
      { "type": "image", "source": { "kind": "blobRef", "ref": "img:entryId:scope:0" } },
      { "type": "image", "source": { "kind": "inline", "mimeType": "image/png", "data": "<base64>" } },
      { "type": "image", "source": { "kind": "path", "path": "/tmp/shot.png" } }
    ]
  }
}
```

- **blobRef** — an EXISTING history blob-store id (`img:<entryId>:<scope>:
  <index>`): an image already committed in session history, served by
  `blob.read`. Read-side ids only — there is NO broker-side staging
  store today, and prompt-time image staging is separate new v3 scope if
  ever needed. The adapter DERIVES the mime type from the stored block;
  a client-declared mimeType is neither required nor trusted here.
- **inline** — base64 bytes in-frame (bounded by the 1 MiB frame cap);
  `mimeType` is REQUIRED (the adapter cannot derive it).
- **path** — a filesystem path on the AGENT host (today's `@path` prose
  reference, made structural).

These are distinct types; the adapter rejects a kind it cannot honor
(`unsupported_capability`) rather than silently substituting another.

**Order semantics are adapter-degradable.** omp's `sendUserMessage`
joins all text blocks into one prompt string and passes images as a
separate array — interleaved text/image order CANNOT be preserved by the
omp adapter. The contract therefore guarantees only: text order is
preserved among text blocks; images are grouped. The app must not build
UI that promises interleaved ordering.

The `attachments` capability remains the gate; the existing `text`+
`images` params keep working (transition: adapters accept both; new
clients send `content`).

## 7. App-side composer change (post-review PoC)

`ComposerRouterStore.routeSlash` grows an explicit three-way decision
(the local-command cases stay untouched):

1. client-local command → handled (unchanged);
2. catalog command with `execution.kind == "invoke"` → the router asks
   the chat surface to send `command.invoke` by id — new minimal
   `AgentChatStore.sendCommand(commandId:arguments:)` next to `send`,
   additive, not touching the sibling-owned `sendOnWire` prompt path;
3. everything else (`insert`-only or unknown name) → EXPLICIT prompt
   text (kind 1) — never a silent structural guess. Unknown names keep
   omp's own fall-through-to-model semantics.

The suggestion menu already lists commands; picking one inserts `"/name "`
today. Post-v3 the menu tracks the command's `execution.kind` so a picked
`invoke` command submits structurally.

## 8. Proof-of-concept scope (after review)

- Swift: `AgentChatStore.sendCommand` + a scripted-broker test asserting
  a leading-`/` catalog command produces a `command.invoke` frame (method
  + commandId + requestKey) and NEVER a `prompt.send` frame; the echo's
  terminal state is the acceptance (no confirmed state, per §4a).
- `protocol.mjs`: the one-line `METHOD_CAPABILITIES` addition
  (broker-lane: V2StructuredSend lands it + broker routing test in the
  same change, lockstep).
- omp adapter: `command.invoke` handler answering `unsupported_capability`
  until the upstream omp API lands (honest, and it makes the broker-side
  routing testable end-to-end).
- No wire change ships without the broker lane landing the same
  `protocol.mjs` addition in lockstep.

