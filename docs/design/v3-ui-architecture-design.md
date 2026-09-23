---
type: design-doc
tags: [meadow, herdr, ios, web, design]
date: 2026-09-22
status: designed-awaiting-implementation
---
# Meadow v3 — UI and architecture design

Source requirements: [[Heeler fork - iOS herdr client build plan#V3 planned features — Meadow]]. Distribution research: [[Meadow - phone-only build installation]].

## Scope and status

Design commissioned for every pending v3 requirement on 2026-09-22. This document defines the target behavior; it does not claim implementation, runtime validation, or automatic approval to ship. Current native v2 and host-package consolidation remain independent work. Existing defects reported on the phone remain real even where earlier simulator checks passed.

Evidence baseline: native integration reference `191a2c2a`; developing chat-domain `6ab7b267`, adapter `83103f31`, and host-consolidation `66dd15af` were inspected during design. These are moving feature lines, not a declaration that all are merged or accepted. Rebase implementation onto the actual integration tip and verify contracts again before coding.

## Shared architectural decisions

### One installation, bounded runtime ownership

- One Meadow host package bundles the herdr plugin, one broker and supported agent adapters. Agent-specific APIs stay in adapters; herdr owns workspace/tab/pane and terminal processes. Do not create one broker per agent type or per herdr session.
- Refine “one per host” to **one broker per OS user/security domain on a host**. Different Unix users must not gain access to each other's agent state through an accidentally global socket.
- The optional web gateway is another listener/module owned by the same installation and supervision, not another manual setup product. Process isolation is allowed when needed; installation count is not process count.
- Package setup is explicit and idempotent. A normal client connection must not reinstall extensions, restart running agents, or silently elevate privileges.

### Native cold start and Meadow Host helper — decision 2026-09-23

**One explicit host-side setup-and-pair operation, with pairing rendered directly to stdout.** On a fresh app install/new host, the user runs one published command on the target host, then scans the QR or copies the pairing code from that SAME terminal. No herdr plugin-action dispatch, popup, new tab or client-side graphical renderer is required. Product name: **Meadow Host**; fork plugin ID: **`meadow`**. The public pairing entrypoint is a foreground CLI, not `meadow.pair` through herdr's action API. The unified installer and public command name remain implementation work; do not advertise an invented installer URL.

**User-verified working route (2026-09-23):** direct execution of the stdout helper is the only working route reported so far:

```bash
cd ~/nv/wt/heeler-consolidation/plugin && /usr/bin/node pair-qr-stdout.mjs
```

This is the current host-specific development invocation, not a portable installation command: neither the checkout path nor `/usr/bin/node` should be required by the released helper. Package the working stdout implementation behind a stable installed foreground entrypoint, resolving its own resources/runtime without requiring a checkout or a particular cwd. Reuse the existing pairing credential/enrollment implementation rather than create a second protocol.

The earlier `herdr plugin action invoke heeler.pair` route is superseded as the onboarding trigger. Its JSON response acknowledges dispatch, not QR display. The user's exact failed invocation (`plugin-log-2796`) tried to spawn a deleted herdr 0.9.0 executable through stale `HERDR_BIN_PATH` and exited ENOENT; fixing that lookup alone would still leave popup presentation as an unnecessary dependency. Newer consolidation code contains setup/broker ownership, but that is separate from a verified portable setup-and-stdout-pair command.

#### Unified setup sequence

1. **Inspect prerequisites without mutation:** supported OS, compatible herdr, Node >=22 for the broker, SSH server/host keys, and agent adapter prerequisites. Show actionable missing-prerequisite instructions. Never silently enable SSH, open firewall ports, replace system runtimes, or elevate privileges.
2. **Install the verified fork release:** one versioned, integrity-checked host package containing the Meadow plugin, broker and supported adapters. Reuse the existing provisioning layout/operations rather than maintain independent app and CLI installers. Installation is idempotent and preserves existing user configuration/history; ordinary app connections only inspect readiness.
3. **Supervise one broker per OS user/security domain:** standard socket `${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock`, restrictive permissions, user-level service appropriate to Linux/macOS. No broker per herdr session and no competing supervisors for the same socket. Detect existing ownership before starting anything.
4. **Configure supported adapters:** write only Meadow-owned shim/config files (omp shim: `~/.omp/agent/extensions/meadow-chat.ts`); preserve other extensions. Broker-service environment is not the environment of already-running agents. Remote-answer/ask-wrapper support remains explicit opt-in, not silently enabled by pairing.
5. **Verify before pairing:** successful broker protocol handshake, compatible version, socket access and adapter configuration. Process creation or service-active status alone is not readiness. Report configured-but-not-yet-loaded adapters honestly.
6. **Generate the QR last, in the invoking terminal:** installation must not consume the bootstrap expiry window. After verified setup completion, invoke the foreground stdout pairing helper directly. Preserve address selection, host-key pinning, single-use enrollment and expiry/revocation. Do not chain a detached plugin action and assume its acknowledgement means setup completed.
7. **Complete app onboarding:** enroll the app's device key, verify SSH/herdr, discover and handshake the standard broker socket, then save its host configuration. Distinguish SSH connected, broker ready, and agent chat available. Missing broker/adapter state offers explicit setup/repair; connecting does not implicitly install or restart anything.
8. **Handle existing agents separately:** new agents can load the installed adapter normally. Existing agents require an explicit user decision before any verified restart/resume operation, naming affected agents and preserving their exact durable sessions. No blanket restart and no inferred latest-conversation resume.

A repeat run repairs only Meadow-owned installation state and can generate a fresh pairing code without duplicating services or losing enrollment. Additional phones invoke the foreground pairing CLI without reinstalling. The eventual one-liner installs from the **fork's published release** and invokes the same stdout flow; it must not install upstream Heeler and imply that our broker is included.

#### Helper rename and existing-host migration

- Cut over plugin identity/action references, package metadata, app plugin lookup, setup callers and user-facing instructions together. New installations use `meadow`; distinguish legacy-host migration from the fresh-install path rather than silently maintaining two competing helpers.
- Preserve enrolled SSH device keys and agent history. Keep the existing `HERDR-PAIR` / enrollment protocol and SSH-key markers; plugin branding is not authorization to change wire formats or unrelated broker environment contracts.
- Plugin ID changes move its config/state namespace. Explicitly migrate or re-register the fork's notification/config state; do not assume changing the manifest transfers it. Do not remove a checkout while an in-flight pairing ceremony's restricted SSH command still references it.
- **Do not automatically uninstall upstream Heeler:** its TestFlight notification role may still be required. Distinguish an old fork installation from an intentionally retained upstream installation. Any coexistence must route device registrations/hooks deliberately so the same device is not notified twice. Preserve upstream registrations and relay configuration; renaming the fork does not rename upstream infrastructure.

Acceptance: fresh Linux and macOS hosts; already-configured host rerun; second phone enrollment; expired/interrupted pairing; unreachable selected address; SSH-ready/broker-missing; configured adapter with an already-running agent; and migration with upstream Heeler retained. Prove no duplicate broker/service/hooks, no unwanted agent restart, no credential/history loss, and QR issuance only after verified setup completion.


#### Pairing display reliability — user-reported failure

**Stdout is the primary interface, not a popup fallback.** The user reports the direct stdout helper as the only working route. Retire popup/action dispatch from the documented cold-start path; do not spend the redesign on making remote popups mandatory again.

- Print a terminal-text QR and the SAME selectable/copyable `HERDR-PAIR:…` payload directly to stdout. Show the target host/user, phone-reachable addresses, SSH port and expiry. No terminal image protocol, display server, browser rendering service or terminal-clearing animation is required. Do not truncate the QR to terminal height; narrow terminals must retain a usable exact text-code path.
- The app offers **Scan QR** and **Paste pairing code** as equivalent enrollment paths. Copying the text must not depend on a host-local clipboard utility reaching the phone or controlling workstation.
- Generate credentials only on explicit pairing invocation. The requested stdout output contains a temporary credential: warn against sharing/recording it; never mirror it into routine logs, telemetry, shell arguments/history or diagnostic reports. Diagnostics go to stderr. Stdout being visible is intentional, not authorization to persist the secret elsewhere.
- Keep the foreground ceremony alive while the user scans/copies; display expiry and enrollment success/failure. Normal exit, Ctrl-C, SSH disconnect and expiry revoke an unused bootstrap credential; successful enrollment consumes it. Retain server-side expiry enforcement and stale-key cleanup for crashes/SIGKILL. Do not print a code and immediately revoke it on process exit. Regeneration explicitly revokes the previous code; rerendering does not mint a second credential.
- Verify local terminal and SSH/multiplexer execution without any popup-capable client, including narrow dimensions, absent clipboard utility, copy/paste enrollment, expiry, interruption and disconnect. User-reported success establishes the direct route; portable packaging and all cleanup cases still need implementation verification.

#### Pairing through herdr remote-machine access

The user may be on machine A, viewing/controlling machine B through herdr's remote-machine feature. Do not equate the terminal displaying the command or QR with the host being enrolled. Distinguish **display/client machine**, **target host and OS user**, and **target herdr session** throughout setup and pairing.

- Setup/pairing explicitly targets B and executes host inspection, package installation, broker verification and credential creation AS THE INTENDED USER ON B. Derive SSH addresses, port, host-key fingerprint, username and broker location from B, never from A's environment. Do not assume a plain command in A's shell follows the remote machine selected in herdr's UI.
- Before mutation, show the resolved target host/user/session and how it was selected. Execute the foreground helper in a shell ON B, either an existing remote pane or an explicit authenticated SSH connection. Selecting B in a herdr sidebar must not implicitly retarget a command actually executed on A. No remote plugin-action routing is needed for QR generation; never silently fall back to pairing A.
- B owns the short-lived credential and cleanup; its stdout travels through the existing SSH/herdr terminal stream to A. No separate presentation RPC or remote popup is involved. B needs no GUI, and A needs no host-side pairing installation merely to display the output. Keep credentials out of persistent logs and do not cache them after expiry.
- **A can reach B does not imply the phone can reach B.** Address selection must identify a route usable from the phone (for example LAN, tailnet, or explicitly configured supported SSH jump host). A loopback address on A, a temporary local forward, or B's address reachable only from A is not a phone-ready route. If a jump host is required, expose that prerequisite/configuration explicitly; the current pairing payload does not by itself describe an SSH jump chain.
- Bind presentation, expiry, regeneration and enrollment feedback to B's ceremony identity. Changing the selected remote machine must never retarget an existing ceremony. Loss of A's presentation/control connection must leave bounded credential expiry and cleanup on B; retrying display must not silently mint duplicate credentials.

Acceptance adds: A → herdr remote B → phone enrolls B; local A versus remote B selection; same-named sessions on both; B reachable only through a jump host; phone cannot reach advertised B address; no remote popup renderer; remote disconnect during pairing; and selected-machine changes mid-ceremony. Verify B's pinned SSH identity and installed artifacts, and that A's authorized_keys/services remain untouched.

### Identity is a contract, not a label

| Identity                     | Meaning / lifetime                                                                         |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| hostId                       | Stable configured/trusted host identity; addresses/routes may change                       |
| sessionId                    | Herdr session identity, scoped to host; display name is not the key                        |
| workspaceId / tabId / paneId | Herdr locators, scoped through host/session; order comes from producer metadata            |
| conversationId               | Durable agent conversation identity supplied/resolved by adapter; survives process restart |
| instanceId + generation      | Current adapter/runtime incarnation; stale mutations must be rejected                      |
| clientId                     | Authenticated client identity; never inferred from source='remote'                         |
| requestKey / operationId     | Idempotent user intent / durable operation identity, not UI text                           |
| recordId                     | Actual committed transcript item identity supplied by producer                             |

Use structured tuples or unambiguous encoding when persisting identities. A bare pane ID or session-file path is not globally unique. Preserve the distinction between reconnecting the same conversation and switching to a different one. Never carry drafts, terminal ownership or mutation tokens across identities accidentally.

### Structured protocol and capability boundary

Reuse current framing and supported methods. New method names in the feature designs are **proposed contracts**, not assertions of existing APIs.

- Content is ordered typed blocks: text, image/blob reference, explicit attachment reference, notice. Commands are explicit catalog IDs with arguments; shell execution and client UI actions are not agent prompts.
- Filesystem paths, inline bytes and blob IDs are separate types. Capability refusal must be explicit; do not downgrade structured image content to a path in prose.
- One operation envelope carries target identity, expected generation, requestKey and typed payload. Validate before side effects. A repeated requestKey returns the same operation/result for its supported retention lifetime; if knowledge has expired, return `outcome_unknown`, not an invented success or unconditional replay.
- Acceptance means queued/accepted, not committed. `send.confirmed` must bind a particular requestKey to the actual user record through a producer-owned origin token or equivalent causal integration. Text matching, timestamps and FIFO alone cannot establish origin.
- Confirmation must be queryable/replayable after reconnect; an event-only confirmation cannot settle an event lost during suspension. Durable status and snapshot watermarks are part of the contract.
- Reconnect uses subscribe + buffered events + authoritative snapshot + replay newer than watermark. Dedupe by stable IDs. Never infer completeness from an empty recent window.
- Lifecycle operations use the same principle: accepted start/stop is not proof the process has started/stopped. Read the resulting operation status and actual herdr/adapter state.

### Security defaults

Authenticated clients may reach only explicitly authorized hosts, sessions and capabilities. Local Unix sockets use restrictive permissions; SSH host-key verification stays enforced. Browser access uses HTTPS, authenticated sessions, origin checks and request authorization. Do not expose raw broker/terminal sockets publicly. No credentials or transcript contents in push payloads, analytics or diagnostic defaults.

Host control, forwarded web applications and third-party websites are separate trust zones. An agent-produced URL or HTML page cannot acquire Meadow's host-control authority. Stop/kill, client switching, outbound navigation and port exposure are explicit user actions, not executable markup from chat.

## Delivery and acceptance policy

Implementation can be parallel across native UX and host-control slices after shared identity/protocol contracts are frozen. Web/PWA, WSS gateway and Web Push are long-term backlog, not v3 or near-term work. Native transport remains Unix sockets over SSH. Each active slice must exercise its actual producer and consumer; scripted frames prove codec behavior only.

V3 device matrix: physical iPhone and iPad, narrow/wide/floating keyboard, VoiceOver/hardware keyboard, Dynamic Type, dark/light and Reduce Motion. Browser/PWA/Android acceptance applies only if the long-term web plan is separately authorized. Native changes follow the user's physical-device acceptance-before-main rule.

## Native build distribution recommendation

Use TestFlight when the publisher elects paid Apple Developer Program enrollment. Friends install via invitation on their phones; no developer account or desktop is required for them. The builder still requires a trusted Mac/macOS CI signer. Preserve identifier/entitlement compatibility and verify keychain migration before replacing the daily-driver app. No enrollment, upload or distribution is authorized by this design. See the linked distribution note for official sources, expiry and alternatives.

## Implementation sequence and acceptance ledger

1. Freeze identity, mutation idempotency and causal delivery-status contracts against real producers. Reuse the accepted native SSH/socket transport and host consolidation; do not add speculative WSS/gateway dependencies.
2. Implement native UX and lifecycle in independent slices: header/search/composer, delivery outbox and viewport ownership, agent lifecycle/order/companion terminals. Share domain records rather than inventing separate stores per view.
3. Integrate native surfaces and run their acceptance scenarios below. TestFlight distribution remains an optional separately authorized release choice.
4. Long-term backlog only: browser gateway/client, Web Push, port forwarding and loopback callback support. No implementation schedule or near-term transport migration.

| Requirement | Mandatory acceptance observation |
|---|---|
| Web/PWA — long-term only | Not a v3 gate; retained research for a separately authorized future client |
| Web Push — long-term only | Not a v3 gate; requires the future browser client/enrollment |
| Agent lifecycle | Start one agent exactly once under duplicate request delivery; stop verified process only; resume explicitly selected saved conversation; stale-generation request refused |
| Header menu | Tap identity opens correct agent menu without intercepting Back/surface controls; statistics display source/freshness; destructive action names its target |
| Herdr ordering | Two hosts with colliding pane IDs, reordered workspaces/tabs, multiple panes and offline snapshots; producer order maintained independently from names/status |
| Header/search gap | No unexplained spacer on compact phone or wide layout, large text remains usable, every action keeps a reachable touch target |
| Compact composer | + menu contains all four prefix functions and attachments; typed prefixes still work; selecting/cancelling preserves draft, caret and keyboard as designed |
| Pending stack | Several submits before confirmations; out-of-order confirmations; lost ack/event; rejection and unknown outcome; no wrong sent styling, duplicate or cross-conversation draft |
| Blank viewport bug | Real phone initial load/refresh, keyboard show/hide, lock/unlock repeated for empty/short/long history; retain readable anchor/draft with no manual recovery |
| Companion shell | Exact cwd, same herdr tab, separate pane; disconnect/reconnect retains running shell; stopped shell is not falsely advertised resumable; stopping shell leaves agent running |
| URL handoff | Actual CLI opener, multi-client targeting, blocked popup/background case, deny/expire, callback flow; never execute a URL as shell code or leak credentials into notifications |
| Port forwarding | Private local service reachable only through authorized forward; actual WebSocket preview works; explicit stop and target exit visible; forwarded app cannot call control APIs |

Design review uses state-case walkthroughs and source grounding; it is not runtime acceptance. Implementation acceptance must capture the transition itself, not a screenshot taken after a race has recovered. Each protocol mutation needs an idempotent success case and a real refusal/unknown-result case. No broad claim that one happy-path capture proves all keyboard, browser or network behavior.

## Native chat and layout design

### Header/search spacing and content-sized user bubbles

- Keep the root-page toolbar and search as separate semantic regions. Search is the first content row with a target 4pt visual gap below the safe-area/navigation boundary, 12pt side margins, and an explicit minimum 44pt interaction height. Do not rely on `contentShape` to enlarge a smaller frame. Remove redundant List/ScrollView insets only after measuring which layer contributes the observed blank space; system safe areas remain intact.
- Compact count/filter chrome uses 3–4pt vertical spacing, but controls still have 44pt hit regions. Dynamic Type can grow the toolbar/search rather than clipping or using negative padding. Wide layout retains the reserved sidebar rather than stretching phone chrome.
- **Outgoing bubbles hug content.** Place intrinsic-width content in a trailing-aligned full-width row; apply the bubble background to the intrinsic content, not the outer row. Initial design tokens: 12pt horizontal/8pt vertical internal padding, maximum bubble width `min(0.85 × available transcript width, 560pt)`, no minimum bubble width beyond content/padding. The maximum is a cap, never a forced width. Long prose wraps; code/tables use their dedicated overflow treatment. Emoji/one-word/multiline/image examples must all be inspected. Accessibility actions remain available without padding the visible bubble to full width.

### Compact composer: one row, one + menu

Use the built-in iOS Messages composer as the v3 visual reference: separate circular **+** on the left, slim rounded text capsule, small circular up-arrow Send inside the capsule's right edge. The capsule EXTENDS upward around attachment/quote tiles, with the text row beneath them INSIDE the SAME border; tiles are not a separate strip above the frame. Empty input remains one compact row, multiline text grows to a bounded height. Keep Meadow green, no extra toolbar/recipient caption, `/ # @ !` in +, and the default OS keyboard with its standard language/dismissal controls. The preview does not emulate native keyboard keys.

Latest placement experiment: when attachments/quotes exist, move the single + control to the END of their preview row, inside the extended capsule. When the rail is empty, keep + outside on the left so an empty composer does not gain an extra row. Never show both add controls simultaneously; overflow counts only actual attachments, not the add button.

The + menu reuses one action policy and exposes **Agent command (/)**, **Filter/tag (#)**, **Mention (@)**, **Shell command (!)**, then image/file actions. Capability-unavailable actions are disabled with a reason. Native typed-prefix entry remains, but selection resolves to typed intent: a chosen agent command is a catalog ID/arguments, not a text string subsequently guessed as a command. Client filters are not transmitted to an agent; shell intent goes to the separate companion terminal.

For empty input, selecting a prefix opens its appropriate chooser/editor with keyboard focus. For nonempty input, do not silently reinterpret existing prose or insert a useless command prefix mid-sentence: preserve the draft and selection, then open a command/shell editor as a separate operation. Mention insertion is allowed at a valid text-token position; otherwise its chooser explains the target action. Cancel returns to exactly the original draft/caret. A selected destructive command names the agent and requires its normal confirmation. No menu action submits merely by inserting a prefix.

Plain Return follows the chosen chat setting (newline by default on mobile); Send is explicit. A hardware shortcut sends, Escape closes the active chooser before dismissing the keyboard. Native IME marked text must finish composition before snapshotting a send; no premature transliteration or replacement.

### Writing assistance and placeholder restoration — v3 requirements

- **Default ordinary Chat to system spelling correction/prediction enabled**, following the OS language and keyboard. Settings → Chat → Writing assistance provides System/Off. Do not implement a second predictive engine, send drafts to a new service, or promise control over third-party keyboard behavior.
- Dedicated command-argument, path, code and shell editors disable autocorrection, smart quotes/dashes and automatic capitalization. Raw terminal and agent-TUI input ALWAYS remain literal. A freeform chat field cannot reliably disable corrections for arbitrary inline code spans using global UITextInputTraits: offer a visible per-draft “Literal input” override, and use structured fields for command/path selections. Never rewrite restored text after the fact or change keyboard traits on every keystroke.
- **Placeholder invariant:** visible iff the actual installed editor text is empty and there is no active marked-text composition. Focus/reconnect/network state must not independently show it. Use one placeholder implementation; remove overlapping SwiftUI and UIKit placeholder layers if both exist.
- Apply draft restoration as one editor update: stable conversation identity → versioned draft text/items/UTF-16 selection → clamp selection to text bounds → update placeholder and intrinsic size. Programmatic restore, suggestion acceptance, clear, reconnect and identity switch all call the same synchronization path, not only typing delegates. Do not persist old text under a new conversation while applying restoration. A missing draft installs empty text/items/selection, not the previous conversation's content.
- Acceptance: enter a sentence, move caret without typing, switch surface, lock/unlock and reconnect repeatedly; exactly one copy of the draft, zero visible placeholder when nonempty, caret restored, no loss of marked CJK text. Verify correction/prediction in ordinary prose and literal behavior in command/path/terminal fields. This is the user's reported bug, not an assertion of its root cause.

### Submitted-draft stack and delivery state

Separate **editor draft**, **durable client outbox**, and **committed transcript**. The outbox is keyed by host/security identity + conversationId + clientId, not bare pane ID. Each immutable submitted entry has requestKey, ordered typed content, local submission ordinal and delivery status. Persist content/attachment ownership before clearing the editor. Clearing on durable LOCAL enqueue allows A, B and C to stack without waiting for network acceptance; a local enqueue failure leaves the editor untouched. Avoid naming local enqueue “accepted” in protocol/UI documentation.

| State | Appearance and allowed action |
|---|---|
| Locally queued / transmitting | Neutral gray bubble and readable gray text, with queued state distinct from sent. Cancel removes an unsent queued item; Edit cancels/withdraws it then moves its text, attachments and quotes back into the composer. An in-flight item requires authoritative cancellation before claiming withdrawal. |
| Broker accepted, commit pending | Same pending styling, “Awaiting agent”; no sent checkmark. |
| Rejected | Pending styling plus error and Edit/Retry/Copy; retry only for definitive nonacceptance. |
| Outcome unknown | Pending styling plus “Delivery unknown”; Check status and explicit “Send again — may duplicate.” Never auto-resubmit after reconnect. |
| Producer committed | Sent appearance only on requestKey→recordId proof; replace the matching outbox representation atomically when its record materializes. |

Remove the heuristic `.unconfirmed` transition and text/baseline/FIFO matching as delivery authority. A prior successful acknowledgement cannot be undone by a late timeout. Query persisted operation status after reconnect; bind confirmation to host/conversation/requestKey and expected generation. If the protocol cannot replay/query commitment, that is a blocking contract gap, not a UI heuristic opportunity.

The pending stack is a separate, labeled **Pending messages** region after loaded history and before the composer; it is not falsely timestamp-interleaved with committed history. Pending entries stay in local submission order. Producer sequence controls committed transcript order; confirmations may arrive out of order, so the client must not infer ordering from receipt time. One canonical display record per requestKey/recordId prevents a double bubble during handoff. A currently active ask remains an independently labeled action card rather than being swallowed by the stack.

Pending drafts use a gray fill and gray text with sufficient contrast in light/dark, never the sent-message tint. Provide Cancel and Edit (move back to composer). Preserve any existing composer draft: refuse destructive overwrite or explicitly save/swap it. For host-accepted/in-flight items, cancellation must be an idempotent protocol operation; only confirmed withdrawal permits moving/removing as unsent. If already committed or outcome unknown, explain the state and do not pretend local removal retracts delivery. At the latest edge follow growth; readers above keep their anchor. Reduce Motion disables relocation animation.

### Send queued drafts together

User preference: queued drafts should not be forced to consume one agent round each. Offer **Send all together** for drafts not yet dispatched, preserving local submission order and per-draft edit/cancel until dispatch. Do not include the still-edited composer text unless explicitly submitted.

Preferred capability: one atomic batch containing several user messages, all supplied before the next model turn. The inspected omp adapter currently invokes sendUserMessage once per prompt.send; it does not establish such an atomic multi-message capability. Repeated calls are not proof of one-turn batching. Verify native agent support before advertising separate-message batching.

Accepted fallback: combine the queued drafts into ONE user message, preserving each draft's text boundaries/order, quotes and ordered typed attachments. Show “Send N drafts together as one message” before dispatch; the committed transcript honestly contains one message, not N fabricated records. Use one batch requestKey plus exact member IDs; its authoritative commitment settles those members atomically to that single record.

For a busy agent, hold eligible drafts in a Meadow-owned queue and drain them together at the next supported input boundary; do not first submit them separately to the agent's follow-up queue. Do not interrupt a turn or answer an unrelated pending ask implicitly. Already dispatched/accepted/unknown-outcome items cannot be rebatched without authoritative withdrawal, or they may duplicate. New drafts arriving during dispatch form the next batch. Oversized batches are refused with size guidance or explicit user-selected splitting, never silently split into extra rounds.

### Blank viewport prevention: invariants first, diagnosis before fix

Treat the physical-device blank-page report as unresolved. Inspect four independent axes during a reproduction: loaded record IDs, mounted ChatScreen identity/phase, scroll viewport/content geometry, and anchor/keyboard state. Record transitions in a bounded debug ring buffer without message text; avoid permanent high-frequency telemetry and arbitrary timers/forced reloads as remedies.

Once content exists for the SAME conversation, keep its reading surface mounted through transient reconnect/loading and show a small status overlay. Initial empty content gets an explicit loading/empty/error state. A different conversation changes identity deliberately and loads its own draft/anchor. Do not replace a readable transcript with a blank branch because transport changed phase.

Anchor policy: long initial history opens at latest; short content top-aligns; loading older records preserves the top visible record plus intra-row offset. Keyboard/rotation/type-size changes preserve that reading anchor unless the user was following latest, in which case preserve the bottom edge. An ID-only `scrollTo(.top)` cannot preserve intra-row pixel offset; use a single scroll-position/geometry coordinator and validate the platform mechanism. No competing scroll commands from keyboard handlers, data refresh and sentinels.

Keyboard layout has one owner. Measure bottom-edge obstruction in the chat's own scene/window, clear on zero coverage, ignore unrelated windows and undocked floating geometry, and remove observers on teardown. Prefer the keyboard layout guide where it satisfies the actual SwiftUI surface; do not bolt another inset on top of stock avoidance. Coalescing is implementation-specific and must be measured, not assumed correct for every keyboard.

Do not preselect a cause (LazyVStack, phase churn or geometry). Capture the failing transition, isolate it, fix its source, then retain regression coverage for initial open, refresh, ten lock/unlock and keyboard cycles, older paging, short/long history, large type and iPad floating/hardware keyboards. A nonzero viewport alone is insufficient: a real message must intersect it when content exists.

## Agent navigation, ordering and lifecycle

### Header menu and statistics

Make the **existing top chat header's agent identity/name area** the menu trigger (not an additional status strip). Keep Back and the existing surface selector separate. Minimum 44pt target; chevron and accessible “Agent menu, <name>” hint make it discoverable. Phone: medium/large sheet; wide layout: anchored popover that can expand to details. Close returns focus to the header.

Menu sections, in order: identity/context (host → session → workspace → tab), Statistics, Actions, Companion terminal. Statistics reuse the current details store: reported model/context/working directory plus freshness. Missing fields say Not reported; expired data says Last known. Do not turn state sequence numbers into user statistics. Lifecycle actions are Interrupt turn, Stop agent, Resume saved conversation, New conversation; only relevant actions are visible, unsupported relevant ones explain why disabled. Existing model/compaction details remain accessible here rather than duplicated in a competing menu. Additional tools are not a license to fill the menu with unrelated features.

### Default herdr ordering

Default **Herdr order** uses producer workspace/tab order, not names, status, activity, tab number or lexicographic pane IDs. The inspected native projection already derives tab positions from snapshot array order and pane positions from layout geometry; reuse the documented/verified order surface, with producer revisions. Within a tab use producer pane-layout traversal (top-to-bottom/left-to-right where that is the explicit API contract). A rename must not reorder a row; a desktop move must.

Herdr sessions are independent servers; do not pretend they publish a global cross-host/session ordinal. Show hosts and sessions in explicit user-configured catalog order until herdr provides a cross-session ordering source. Explain this in the sort picker: “Hosts/sessions in your order; workspaces and tabs in herdr order.” Missing ordinals preserve the last known position/arrival order with an Order unavailable indication; no invented alphabetical fallback advertised as herdr order.

Fresh installs and untouched old defaults migrate to Herdr order; preserve a deliberately chosen alternate sort. Pins are bookmarks, not a silent reorder of this default: a separate optional Pinned section may duplicate links, while the canonical list stays herdr-ordered. Filter/search retain canonical order unless the user explicitly selects relevance. Cache identity/order per host+session, with offline freshness.

### Verified primitives and proposed lifecycle operations

The design agent inspected herdr 0.9.1/protocol 22 read-only: `agent.list`, `session.snapshot`, `agent.start`, `pane.split`, `pane.get`, `pane.close`, process inspection and terminal attach exist. It found no first-class `agent.stop` or `agent.resume`. A supported executable is not proof that graceful stop or conversation resume is available.

Put the **proposed** lifecycle operation coordinator in the host package, not independent multi-step races in every client. It exposes start/stop/resume/status via the shared operation envelope; adapters/manifests declare verified per-kind semantics. Preserve existing APIs underneath. Do not assume Ctrl+C means graceful exit: in TUIs it may interrupt a turn or require another action. Prefer a native agent exit API or a verified idle-only exit command. If none exists, say graceful stop unsupported and provide explicitly destructive pane close separately.

Agent process state: running → stopping → stopped, or unknown/disconnected; stopped conversation metadata remains listable. “Stopped” requires process/agent inspection, not shell-prompt text or absence of one status event. Interrupt stops only the current turn and is not guaranteed reversible; Stop may lose unfinished work and requires a confirmation naming the target. Force-close always confirms and targets only the agent pane, not its whole tab or companion. Process exit does not imply history deletion.

Create: select host/session/workspace, kind and cwd; show destination before submit. Generate one requestKey; repeated delivery must not create extra tabs/panes. Resume: choose the exact durable conversation from the adapter's saved-conversation catalog; reuse its stopped pane or explicitly choose a new destination if gone. Never choose “latest file” heuristically. A native resume flag is adapter implementation detail, not a client shell command string.

Single-writer guard must cover the **whole host security domain across herdr sessions**, not only the currently selected session. The host coordinator acquires a per-conversation start/resume lock, inspects existing registered processes, and rejects an already-running conversation. Unknown occupancy is a refusal, not permission. Completion requires the resumed runtime reporting the requested conversation identity; a fresh registration may have a new instance ID and generation, not necessarily a numerically incremented generation. Keep the same-conversation editor draft; invalidate old in-flight mutation targets and reload asks/status rather than discarding user prose on every generation change.

For destructive actions, re-resolve pane from stable terminal/conversation identity and expected host/session immediately before dispatch. A plain query-then-close still has a race if locators are reused: require a host-side atomic expected-identity guard or an immutable terminal-targeted close primitive before advertising safe remote force stop. Do not simulate safety by comparing IDs only in the client.

### Companion shell in the same tab

Entry points: Agent menu → Companion terminal; surface selector distinguishes **Chat / Agent TUI / Shell** rather than replacing the agent TUI with a shell. Start shell creates a separate herdr pane in the agent's SAME tab (`pane.split`, initially right, focus=false so the desktop agent is not stolen). Reuse a verified living companion rather than create another on each tap. Default one companion per agent; additional terminals can remain an explicit later extension.

Resolve cwd at operation time: agent-reported working directory, then inspected foreground cwd, then launch cwd. Label fallback provenance and ask the user to confirm a fallback directory rather than claim it is current. An agent can execute commands with per-command cwd without changing its session cwd; display “agent working directory” accurately. Missing/inaccessible cwd gives a directory chooser/refusal, not an arbitrary worktree root.

Host registry owns companionId → host/session/tab + stable terminal identity + owning conversation + started cwd. Creation has an operation ID and server-side idempotency lock. Do not infer the new pane from a list diff when other clients may split concurrently; require a correlated create response/event, or add a host helper that returns an unambiguous immutable identity. Validate same-tab membership before attaching.

Back/Disconnect detaches the client, never stops the shell. Reopen verifies and attaches the same terminal; output recovery uses herdr's actual attach/replay contract. A dead shell says Shell ended; Start new shell creates a new process. Never claim arbitrary process restoration. Stop shell confirms foreground jobs may end, closes only the verified companion pane, and leaves the agent alive. Closing an agent pane also leaves its companion alive; closing the WHOLE tab is a separate destructive action naming every affected pane.

If the desktop moves either pane to another tab, mark the relationship moved and show its new location; do not silently move panes back. User can explicitly rehome/create a companion after verification. Respect the current one-interactive-terminal-channel-per-host constraint by detaching one view before attaching the other; chat broker traffic stays live and host processes stay running.

Lifecycle acceptance additionally covers two simultaneous resume/start requests, stale pane identity, same conversation in two sessions, agent stopped while shell runs, shell stopped while agent runs, desktop pane move, client disconnect during shell command, and exact conversation identity after resume. Missing server primitives are implementation prerequisites, not fabricated existing support.

## Browser/PWA, notifications and remote handoff

### Gateway and responsive client

One optional gateway module in the Meadow host package, supervised alongside the per-user broker. Default loopback bind behind authenticated tailnet HTTPS; no raw Unix socket is exposed publicly. Setup/status show the gateway origin, TLS/auth health, connected clients and revoke controls. Adding web access never installs or restarts an agent implicitly.

Browser UI follows the same three destinations and agent menu as native: compact phone navigation, reserved wide sidebar, responsive transcript/terminal. Native retains direct SSH; browser uses same-origin HTTPS + WSS. Choose a small TypeScript frontend with one normalized protocol client, semantic HTML and a maintained markdown/terminal renderer; reuse protocol schemas, not SwiftUI code or another JSONL parser. Escape untrusted markup, disable arbitrary script/remote-image execution, preserve code/text as data. Exact frontend library is an implementation choice, not a protocol dependency.

Each authenticated browser WebSocket gets one dedicated upstream broker client connection. No multiplexed cross-client authority initially. One complete JSON protocol frame per WS text message maps to existing newline-framed socket transport with limits in both directions. Large blobs use authenticated bounded upload/download, not unbounded base64 frames. Chat and terminal streams use separate backpressure queues; terminal WS sends binary PTY bytes with distinct JSON resize/control frames, not newline conversion.

Enrollment: an explicit host setup action creates a short-lived single-use web pairing token. Redeem by HTTPS POST; do not put reusable credentials in URL query logs. Server issues a Secure/HttpOnly host-only session cookie and records a scoped clientId. Enforce exact allowed Origin on WS and state-changing HTTP requests, CSRF protection, per-operation authorization, expiry/revocation and bounded connections. Network membership is not the only authentication check. A revoked client loses WS, push subscription and forward grants. Settings lists paired clients and last use.

Reconnect order: enumerate/match permitted sessions, subscribe and buffer, install history/interactions snapshot, replay events newer than its watermark. Query pending operation status by requestKey; do not resubmit automatically after a browser reload. Local draft/outbox state is namespaced by server/host/security identity + conversation + client and cleared on explicit sign-out/forget. Static offline shell may be cached by the service worker; transcripts and credentials are not blanket-cached as HTTP responses. Browser-local drafts are not secure from same-origin XSS, so strict CSP and untrusted-content isolation are mandatory.

PWA background execution is not assumed. Resume from hidden/locked state revalidates the connection and reloads missing state. Web terminal reconnect must use a supported terminal-state/replay mechanism (or explicit redraw) rather than pretending `pane.read` plain text restores cursor modes, colors and alternate-screen state. A browser cannot keep the host shell alive itself; herdr does.

### Web Push

Use standard Web Push encryption (RFC 8291) and VAPID with a maintained implementation. No second custom encryption scheme. Store subscription endpoint/key material against authenticated clientId; validate permitted HTTPS push endpoints to prevent turning registration into an arbitrary server-side fetch. Revoke on sign-out/unenroll and prune expired subscriptions.

Ask notification permission from an explicit user action; on supported iOS/iPadOS (16.4+) explain Home Screen installation. Default lock-screen content is generic (“Meadow: agent needs attention”) with only the minimal authenticated routing identity inside the encrypted payload; no transcript text, URL tokens or credentials. Optional detailed previews require a user privacy choice. Group repeated events by conversation and expire obsolete asks; push is a nudge, not acknowledgement or history synchronization. Tapping resolves the correct host/conversation and fetches current state. Force-stop, permission denial and OS throttling remain outside guarantees.

### URL-open requests

Install an opt-in Meadow opener helper in the host package and expose it only in managed agent/shell environments; do not replace the system-wide `xdg-open` or macOS `open`. Preserve local opener behavior when not managed, and avoid recursive fallback through the shim. Support common CLI browser hooks only where their invocation format is verified; never execute URL text as a shell command.

Proposed record: `url.open.requested {requestId, hostId, sessionId, sourcePaneIdentity, url, createdAt, expiresAt}`. Derive trusted source/authorization from the host channel, not arbitrary client-provided attribution. Accept only http/https by default; validate schemes, reject credential-bearing URLs, redact query secrets from logs and push. Relative host-local URLs require an explicit forward mapping.

Client affinity chooses where to OFFER the request, not permission to open it. An explicitly bound initiating client wins; otherwise offer to authorized clients with visible host/agent attribution and atomic first-claim settlement. If ambiguous, show a chooser/request inbox rather than opening every browser. With no client, bounded expiry returns a visible terminal error or the user's configured local-opener fallback; it must not hang the CLI indefinitely.

Foreground UX: a compact “Open <domain> from <agent>?” banner with Open/Deny and copyable safe URL detail. A tap is required on mobile/PWA; domain preferences can skip repeated explanations but cannot manufacture browser user activation. Claim asynchronously, then show a final real link/Open tap if the activation was lost; do not promise an async `window.open` is allowed. Background requests use a notification/inbox entry. An app-open request is not a license to run a command or expose a port.

### V3 link UX; forwarding deferred beyond v3

**Latest user decision: no port discovery, forwarding or localhost proxying in v3.** Normal external HTTP/HTTPS message links follow tap-to-open browser policy. A localhost/loopback link opens a small “Local address unavailable” sheet explaining that the address refers to the originating agent host, not the phone. Show the selectable URL and host identity, offer Copy address / Close, and suggest asking for a reachable URL or opening it on the host. Do not offer Forward, Install gateway, Retry connection or misleading Open on phone. Dismissal preserves the reading position and editor draft. The preview demonstrates this state.

**Deferred research only:** web/PWA, WSS gateway and Web Push are long-term ideas, explicitly not v3 or near-term. Port discovery/forwarding and loopback OAuth support are also deferred. Earlier architectural examples are retained research, not active implementation requirements. Native Meadow keeps Unix sockets over SSH.

**Listening-port discovery versus forwarding:** enumerate observable TCP listeners with optional session/pane/process attribution, but do not automatically expose every port. Loopback ports belong to the host network namespace, not inherently to a herdr session; detached processes, containers and permission-limited process inspection can make attribution unknown. Never claim an unknown listener belongs to the current agent. The default is authorized on-demand forwarding of the tapped port, with a user-approved optional per-host port allowlist; refuse control/database/admin listeners unless explicitly authorized. Discovery itself grants no network access.

**Device feasibility:** desktop/native clients can provide loopback SSH listeners while their process runs. iPhone/iPad can support a foreground native tunnel, but switching to Safari may suspend Meadow and break it; no universal background guarantee. Android is also lifecycle/power-policy dependent, not automatically always-on. Browser/PWA clients cannot create arbitrary TCP listeners. For reliable browser use across phone/desktop, prefer a private host-side HTTPS proxy on an isolated authenticated origin, reachable through the user's network/Tailscale; resolve the tapped host-local URL to that endpoint. Do not rewrite an OAuth provider's registered callback arbitrarily. Non-HTTP services require an appropriate native protocol client/tunnel and cannot simply open as browser pages. Verify device-specific flows before advertising support.

One Forwarded ports panel per host/agent: destination loopback port, label, owner client, local/browser endpoint, status, Start/Open/Stop. State: requested → connecting → active, or target-unreachable/stopped/expired. “Active” means the tunnel/proxy route and actual target were verified; accepted setup is not enough. Request IDs make repeated Start idempotent. Forward grants expire (initial default 30 minutes idle, user-visible extension) and can be revoked; target exit is shown, not silently relabeled success.

Native path: a loopback listener on the client with SSH direct-tcpip channels to the authenticated host's loopback port. Do not bind client listeners to all interfaces. Local-port conflict is explicit; use another port for ordinary previews, but OAuth callbacks may require the exact original port. Browser path: an authenticated HTTP/WebSocket reverse proxy in the gateway, with explicit root-path handling and per-forward upstream configuration; it is not arbitrary TCP access from JavaScript.

**Forwarded apps are separate origins from the control PWA from day one, preferably one origin per forward.** Path prefixes and cookie Path are NOT security boundaries. Use host-only control cookies and strict Origin/CSRF checks; cross-origin scripts can still SEND requests, so CORS alone is not authorization. A forward has only its own revocable grant and cannot open new forwards or invoke agent control. Do not share untrusted previews' storage/cookies/service-worker scope with control or other previews.

Deployment options: provision real controlled DNS/TLS for distinct preview hostnames, or use separate HTTPS ports as distinct origins with non-cookie per-request forward credentials (cookies ignore ports). Do not assume Tailscale automatically issues arbitrary `meadow.<machine>`/wildcard subdomain certificates. If secure isolated origins are not configured, disable browser preview forwarding with an explicit setup reason rather than serve previews under the control origin. A URL's random ID is not access control by itself. Per-forward enrollment tokens are short-lived and removed from browser history/referrer exposure after exchange.

Proxy supports HTTP paths and WebSocket upgrades, strips hop-by-hop headers and applies explicit Host/origin policy. Prefer per-forward origin-root routing: generic `/prefix/` injection breaks absolute assets, HMR websocket URLs, cookies, CSP and redirects. Do not promise universal rewriting of arbitrary development apps; expose per-forward base-URL configuration and fail clearly when unsupported. Separate origins plus authorization are mandatory even for a localhost service created by an agent. Deny access to Meadow control listeners and non-loopback destinations by default; a port number must be user-approved, not inferred from arbitrary chat text.

### OAuth and mobile suspension

Never rewrite a registered OAuth `redirect_uri` generically. Preferred strategy: provider-supported device authorization flow; next, a deliberately registered HTTPS callback endpoint; otherwise a native loopback forward preserving the required callback origin or completion on desktop. Provider state/PKCE remain end-to-end; do not log or relay login tokens through a generic notification.

Opening Safari backgrounds native Meadow; iOS may suspend its SSH forward before the callback returns. A grace-period success on one device is not a guarantee. Show this limitation before choosing a loopback flow, test a real login through app switching, and offer a restart/fallback when the forward dies. A PWA cannot bind a listener on the phone's localhost. A gateway callback works only with provider/client cooperation, not a cosmetic URL rewrite. Forward establishment must precede opening the login URL.

Security acceptance: hostile forwarded HTML attempts credentialed fetch/WebSocket/control framing and service-worker registration against Meadow, another preview origin and revoked grants; all control access denied. Verify authenticated normal navigation and HMR still work. Test URL expiry/multiple clients, popup denial, iOS app suspension during OAuth, target listener exit and explicit Stop from another authorized client.

## Design review decisions and remaining implementation prerequisites

Three parallel design slices were reviewed and integrated here; this note is authoritative where their working artifacts differed. Review corrections adopted: foreground/background suspension is not bypassable; forwarded content requires actual origin isolation (not cookie paths); Web Push uses its standard encryption; menu actions preserve structured intent rather than inserting a misleading literal prefix; normal chat supports OS writing assistance per the latest user request; pending outbox clears the editor on durable local enqueue, not network acceptance; no text/FIFO delivery proof; stop/resume and pane creation require host-side identity/idempotency guards; stopping an agent pane does not implicitly destroy its companion.

Before implementation freeze: verify herdr's immutable target/create-return contracts; add missing atomic lifecycle operations in the Meadow coordinator if herdr cannot provide them; verify saved-conversation enumeration and graceful exit per agent type; establish producer-causal delivery binding and replayable operation status; configure real isolated preview origins/TLS before enabling browser forwards. These are explicit engineering prerequisites with defined failure behavior, not unanswered UI choices or claims of shipped capability.

All currently recorded v3 requirements have a target design, including the later additions: content-sized own bubbles, placeholder/draft overlap after reconnect/unlock, and spelling correction/prediction. The blank-page and placeholder issues still need physical-device diagnosis before a root-cause fix is chosen. No application code, live agent process, paid enrollment or distribution was changed by this design work.

## Answered questions — one paired Q/A card

**Decision: one card per ask interaction, with a Q/A pair per question.** Do not split each question and answer into separate chat bubbles by default: that doubles chrome and can detach an answer from its question during paging. Answered and unanswered states share the SAME card family: paper background, subtle green border, 12pt radius, matching width/insets, accent eyebrow and footer separator. Only contents/actions change after acceptance: option controls become static selected-answer chips, with Q/A text and notes retained. No whole-card green wash or unrelated user-message bubble styling. Keep it visible at every detail level. The preview has one **Questions** tab with Unanswered/Answered state controls for direct comparison.

```text
Answered · 2 of 2
[ Question 1 ] [ Question 2 • ]
Q: What should the export include?
A: Video · Validation report
   Note: Include the first ten seconds only.
[ Show full question & answer ]
```

**Latest visual decision: retain the original compact card family and thin segmented step indicators.** No larger pill tabs and no Previous/Next buttons. Swipe left/right within the card to navigate questions; preserve selection and per-question text/notes. Use n-of-N to show position. Vertical gestures scroll the conversation, horizontal gestures must not trigger Back or a choice tap, and long-press selection/text editing must not navigate. Keyboard arrows and native accessibility next/previous-question actions provide non-gesture equivalents without adding visible chrome. Single-question cards omit indicators. Both states remain in one Questions preview tab.

Question summary uses the producer's supplied heading or original question, never an AI paraphrase. Answered cards show Q then A on separate lines. Long answer text is ONE ellipsized line in the summary; tap the card to expand the full answer and notes, tap again to collapse. No Show details/Full answer button. Preserve exact source and whitespace in expanded text, with selection/copy intact; selecting text or swiping must not accidentally toggle expansion. Accessibility exposes expanded state and a toggle action. Do not flatten answers across questions.

Selected options render their LABELS in producer order. Multiple selections use short wrap-safe chips or a list when labels are long; do not serialize them with ambiguous punctuation as the stored answer. A free-text-only response shows the actual user text as `A:`. If selection plus custom text is valid for that question, show labels then a separate “Additional answer” paragraph; an optional explanatory note remains separately labeled “Note”, not silently promoted to a chosen option. Empty optional notes are omitted. Explicit skipped questions say “Skipped” only if the protocol says so; missing answer is not a skip.

Typed record contract: interactionId, durable conversation identity, questionId, original question/summary, published options, selected option IDs plus captured labels, customAnswerText?, note?, per-question outcome, overall resolution, known provenance and authoritative record ordering key. Preserve snapshots of labels/questions at answer time so later catalog changes cannot rewrite history. No raw `idx:n` in UI. Store this record durably; the same record survives reopen and is not reconstructed from human-readable “You answered” copy.

After submit, pending card remains “Submitting answers” until authoritative acceptance/resolution. On success replace it with the same logical Q/A card. All accepted answers use identical styling and neutral “Answered” text regardless of local/remote/terminal origin; provenance may remain internal for correctness but is not a user-visible distinction. If actual answer data is missing, show `A: Answer details unavailable.` Never promote a local attempted choice based on an anonymous broadcast. Cancelled/expired retain the question and honest outcome without displaying unconfirmed choices as accepted.

Historical placement requires a producer event/record anchor; do not timestamp-interleave using device receipt time. If unavailable, retain the record in a clearly labeled recent-interactions region until authoritative history resolves it, rather than claiming a true timeline position. One pending/answered representation per interaction; new history pages merge by identity.

Acceptance: single choice, multi-select, multi-question with different outcomes, free text only, selection plus note, multiline/code/Unicode answer, long collapsed/expanded card, remote answer with missing details, event-before-ack losing submission, refresh/reopen and history paging. Verify full text is not lost behind summaries, no duplicated pending/answered card, and no other question's answer appears under the wrong Q label.

### Unanswered question cases

| Case | Compact interaction |
|---|---|
| Single choice | Radio options, one selection; selecting can advance to the next question but never submits the whole interaction automatically. |
| Multi-select | Checkbox options, preserve every chosen label; Send answers requires the producer's minimum selection rule. |
| Multiple questions | One active panel, thin progress segments, horizontal swipe; retain all answers and notes per question ID. Send validates every required question and identifies missing questions. |
| Required text answer | Labeled text field, empty/whitespace-only answer blocks Send; multiline input stays editable and is retained. |
| Other/custom answer | Explicit Other option reveals text input; valid only if the producer permits custom input. Selecting it does not reuse a stale option selection. |
| Optional answer | Clearly label Optional; an empty value is an explicit skip only where permitted by the protocol. Optional explanatory notes never substitute for a required answer. |
| Long options | Wrap labels in full-width option rows; no truncation that changes the meaning of a choice. Keep 44pt touch targets. |
| Submitting | Disable duplicate submissions; keep proposed answers readable; only simulated/real acceptance changes to Answered. |
| Rejected | Inline reason, answers retained for correction/retry. No false Answered state. |
| Offline | Last-known question and editable-draft policy explicit; no send until revalidated. Restore draft without blindly resubmitting. |
| Expired/cancelled | Noninteractive question with exact outcome, no accepted-answer styling. |
| Unsupported | Explain answering unavailable; offer agent TUI only if an actual route exists. No fake active options. |

The preview includes all input shapes plus explicit submitting/acceptance/rejection/offline/expired/unsupported controls. They simulate protocol outcomes and do not prove agent support. Validate native swipe arbitration and IME/keyboard behavior on device before implementation acceptance.

Streaming rendering has its own design and research: [[Meadow v3 - Streaming rendering design]]. Q/A cards consume structured interaction records, not partial Markdown guessed to be questions.

## Tasks and subagents — UI first, protocol second

### UI decision and preview

Tap the existing chat header to open the Agent menu, then choose **Tasks** or **Subagents** as separate rows with counts/status summaries. Both open the appropriate tab of the work inspector. This preserves the header's established agent-menu meaning and avoids another permanent summary toolbar. Relevant unsupported capabilities show a reason; queried-empty differs from not loaded. Offline data remains with Last known freshness, never zeroed or promoted to completed.

Tasks preserve omp's multi-level hierarchy with collapsible parent rows and compact indentation in producer order. State is shown by the LEFT icon only (pending square, in-progress dash, completed check, blocked exclamation); no redundant visible text-state column. Accessible labels and task details still name the state. Progress summaries count leaf tasks explicitly to avoid counting both parent and children; parent state remains producer-reported, never inferred from child completion. Subagents use a distinct compact two-line identity row with name and assigned-work subtitle; their LEFT rounded icon also identifies runtime state, with no right-side text-state badge. Expand rows for full details and freshness; no fake conversation action when unavailable.

**Compact, distinct visual language:** task rows target 44pt minimum height with 12pt indentation per nesting level (bounded indentation, deeper ancestry available in details); subagent rows target 52pt with a 26pt rounded state icon and two text lines. Subagent icons: clock/running, check/completed, exclamation/needs input, cross/failed, dash/cancelled, question mark/unknown; state stays in accessible labels and details. Large text grows rows rather than clipping. Task state marks are read-only, not editable checkboxes. Parent disclosure and task detail are separate actions. Tasks remain hierarchical checklist rows, subagents remain identity/assignment rows even though both use left-only state indicators.

The first version is **read-only observation**, not a client task editor or implicit child stop control. A subagent exiting is not proof its task is accepted/completed, and a parent reporting done does not overwrite child state. Use producer-reported hierarchy with cycle/depth guards; direct children first and explicit expansion for descendants. Do not confuse model tool calls with real subagents.

Preview now exposes Tasks & subagents plus simulated update/disconnect controls. It demonstrates rows, counts, independent states and stale presentation only; no live agents are queried or changed. This UI contract precedes the proposed protocol below.

### Proposed normalized contract

Separate capabilities: task-list observation and subagent observation. Supported adapters project authoritative agent-native task/child state; the broker validates/routes without parsing terminal prose or guessing from tool names. A caller's child is not necessarily a herdr pane: distinguish agent child-run IDs, durable conversation IDs and optional pane/terminal locators.

Proposed snapshot operation `work.snapshot(target)` returns `revision`, event watermark, completeness (`complete|partial`), and ordered task/subagent collections. Tasks: stable taskId scoped to conversation, title, phaseId/order, state (`pending|in_progress|blocked|completed|cancelled|unknown`), optional detail and explicit updatedAt. Child runs: stable childRunId, parentRunId, task references, displayName/kind, runtime state (`starting|running|needs_input|completed|failed|cancelled|unknown`), optional result verdict, durable conversation reference and authorized open capability. Runtime completion and result acceptance are different fields.

Use ordered `work.task.upsert/remove` and `work.subagent.upsert/remove` events, each with stream seq + collection revision and explicit target identity/generation. Subscribe-buffer-snapshot-replay; duplicate events are idempotent, gaps trigger fresh snapshot, and removal uses tombstones/revision so old snapshots cannot resurrect deleted rows. Status transitions come from producer facts, not client timers. Unknown enum values render Unknown with safe detail; unsupported and not-yet-loaded differ from empty.

Parent/child IDs and task IDs survive content edits; never key by title or array position. Persist last-known snapshots by host/security identity + conversation; freshness is independent of task state. On generation changes, fetch a new snapshot and preserve only records explicitly belonging to the same durable conversation. A complete authoritative snapshot may remove absent records; a partial one cannot. Bound payload size and support ordered pagination if needed, retaining coverage information.

Task hierarchy additionally carries optional parentTaskId plus sibling order and node kind (group/task); preserve hierarchy rather than flattening nested plans. Validate missing parents/cycles, retain expansion by stable task ID, and declare partial child coverage. Group totals must not silently double-count descendants or infer parent completion.

Implementation prerequisite: identify real task-list and child-run observation APIs for each supported agent; if unavailable, do not scrape guessed terminal status or advertise live support. Control operations (cancel child/edit task) are separately negotiated future capabilities requiring expected identity/revision, idempotency and explicit user intent; they are not implied by observation.

Acceptance: empty/unsupported/loading, mixed completed/blocked tasks, child needs-input and failed verdict, out-of-order/duplicate/gapped updates, reconnect stale snapshot, task title changes, child name collisions, nested child runs, unrelated host with same IDs, and an exited child whose parent task remains in progress. No false completion, silent disappearance or focus jump while reading a row.

Streaming preview feedback: user considers the current controlled streaming presentation good enough. Preserve this interaction direction; it is UX acceptance of a simulated fixture, not evidence that a native incremental Markdown engine meets performance or reconnect guarantees.

Activity animation preview: fast six-frame SVG spark inspired by terminal-style expanding/contracting marks (dot → small cross → starburst → contraction), approximately 0.9s per cycle. Original graphic mock, not an exact copied Claude Code/omp animation. Alternate phase graphics remain available for comparison. No visible plain status text; tap for details and retain accessible labels. Reduced Motion shows a static frame; unknown/blocked/completed states do not animate.

Disconnected chat: remove the redundant full-width Connection lost banner when cached content is already readable. The static no-signal graphic at the bottom is the retry affordance, with accessible “Connection lost. Retry connection. Draft saved.” Tap starts one reconnect attempt and temporarily changes the graphic; success restores normal activity without resending drafts. Keep it reachable beside the composer rather than buried in scrollback. Detailed actionable failures (host-key/auth/permission) still require an explicit explanation/repair surface; an icon must not hide the reason a retry cannot work. Initial no-content errors still need a meaningful empty/error view.

Disconnected/retry graphic accepted by user: the no-signal symbol changes to the same Wi-Fi arcs filling from empty to full in a loop while connecting, NOT the thinking spark. Preserve draft and disable duplicate retry taps. Animation is indeterminate connection activity, not measured signal strength; Reduce Motion uses a static glyph and accessible Connecting status.

Idle agent: no thinking/work animation and no reserved activity-marker row. Connection success alone does not imply thinking; show a work animation only after a fresh producer activity report. Preview defaults to Idle and reconnect returns to its simulated Idle state. Connecting uses the Wi-Fi fill animation, independent of agent workload.
