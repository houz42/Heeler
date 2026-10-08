---
type: qa-report
tags: [meadow, herdr, ios, v3, qa, device-matrix]
date: 2026-09-23
status: sim-matrix-verified
---
# v3 device-matrix acceptance QA — findings report

Verification slice `feat/v3-device-matrix-qa` (report-only). Scope: the **merged v3 features on origin/main** — content-sized bubbles, phone-width wrapped tables, the paired Q/A card, herdr default ordering (+ Pinned section), the console/agents list, the chat + terminal surfaces, the existing composer row, and the existing header. The in-flight redesigns (Messages-style composer, header agent-menu, search-gap refinements) are unmerged sibling slices and were **not** evaluated and are **not** counted as defects.

Per the design doc's delivery policy (§Delivery and acceptance policy, docs/design/v3-ui-architecture-design.md:122): "V3 device matrix: physical iPhone and iPad, narrow/wide/floating keyboard, VoiceOver/hardware keyboard, Dynamic Type, dark/light and Reduce Motion." Physical-device, hardware-keyboard, floating-keyboard, VoiceOver and Reduce-Motion acceptance remain **open** — this report covers the **simulator** slice of the matrix (narrow phone + wide iPad, light + dark, default + accessibility-extra-large Dynamic Type). Native changes still follow the physical-device acceptance-before-main rule; this is supporting evidence, not final acceptance.

## Matrix actually exercised

| Surface | Phone light | Phone dark | Phone AX-XL type | Wide light | Wide dark |
|---|---|---|---|---|---|
| Content-sized bubbles (`--demo-chat-bubbles`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Phone-width tables (`--demo-chat-tables`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Q/A cards (`--demo-chat-qa-cards`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Console / agents list + herdr order + Pinned (`--demo-screenshots`) | ✅ | ✅ | ✅ | ✅ (sidebar + empty detail) | ✅ (sidebar) |
| Chat surface (production, via UI test) | ✅ | — | — | — | — |
| Terminal surface (production, via UI test) | ✅ | — | — | — | — |

Captures: `evidence/v3-device-matrix/*.png` (22 files). Each was vision-verified against the checklist: GREEN accent only, no clipped/overlapping/unreadable text, bubbles hug content, tables fit width, Q/A card renders.

Sims: `heeler-v3-dmxqa-phone` (iPhone 17 clone, FC818E6B) and `heeler-v3-dmxqa-wide` (iPad Pro 13-inch M5 clone, 7AB3047B). App at origin/main (captured at 48580086, re-verified against the 85840b31/9ef85e2d tips — the later blank-viewport/drawer/QA-note commits do not change the surfaces this report grades; see Revision notes).

## Verified PASS (the merged v3 UX renders correctly)

1. **Content-sized bubbles** — PASS at every condition. One-word ("Ship it."), emoji (🚀), multiline, and fenced-code bubbles all hug content with consistent padding; long prose wraps at the cap (measured ≈535pt on the 1024pt iPad, consistent with the 560pt absolute cap; phone wraps at ~0.85×). No clipping mid-line, no overlap between bubbles, light and dark contrast both good (near-white on dark sage ≫ AA).
2. **Phone-width wrapped tables** — PASS. Long cells wrap to multiple lines at phone width and AX-XL type (code spans and links wrap too, nothing past the right edge, no horizontal pan); at wide width cells fit on single lines and tables size to content, left-aligned, not stretched. Header fill + zebra + separators render in both modes.
3. **Q/A card** — PASS (rendering). The unanswered card renders question, chips (44pt min-height), and honest "N questions left to answer" footer; answered cards render the Q line, A line (collapsed one-line / tap-expanded), selected-label chips in producer order; cancelled / answered-remotely cards show honest neutral outcomes, never accepted styling. Green is the only accent on card chrome.
4. **herdr default ordering + Pinned** — PASS. The demo console renders the producer order (Polish → Audit → Refresh across workspace/tab geometry), visibly different from A–Z and status order; the Pinned section duplicates the pinned row above the canonical herdr-ordered list (by design — pins are bookmarks, not reorders); rows that herdr could not place carry the honest "Order unavailable" mark.
5. **Console / agents list** — PASS (phone width). Single-column full-width rows, pill header, search, count row, green "grouping · order" sort control; phone-appropriate, no stretched chrome. Wide layout uses the reserved 184pt sidebar + split detail (correct, not stretched phone chrome).
6. **Chat ↔ terminal toggle** (production path, UI test `NavigationRedesignProofTests/testChatTerminalToggleKeepsPlacement` green) — PASS. The header capsule pill (blur capsule on the terminal surface) is by-design chrome; the terminal renders ANSI content with its own (dark) theme in both system modes — theme luminance, not a dark-mode leak.
7. **GREEN accent discipline** — PASS overall. Across every capture the only accent hues are Meadow green (bubbles, "Meadow · omp" author label, sort control, card status labels, selected chip wash, links) plus the amber/red/gray **status badges** on the agents list, which are semantic status colors, not accents (same family as v2's accepted accent proofs).

## Defects found (rendering / contrast / overflow / clipping)

### D1 — Header quick-state chips truncate at DEFAULT type size (phone) — REAL DEFECT, recommend fix slice
- **Surface:** Console header (`ConsoleView.toolbarContent` → `AgentQuickStateChips` in one `ToolbarItem(placement: .primaryAction)`, sharing the row with the "New Agent" + button).
- **Condition:** iPhone-class width, **default** Dynamic Type (reproduced at `large`), light and dark. Capture: `console-phone-light.png` / `console-phone-dark.png`.
- **Observed:** chips render as `All | Needs… | Worki… | +` — the labels "Needs you"/"Working" are unreadable at the resting state. Worsens at AX-XL (`console-phone-a11xl.png`: `Nee…`, `W…`).
- **Why:** the toolbar packs three chips + the + button into one trailing item; `Text` has no `fixedSize`/`layoutPriority` and the HStack compresses them. The chips are the primary state-filter affordance.
- **Ownership note:** `ConsoleView.swift` is in the search-gap sibling slice's orbit (`feat/v3-agentlist-search-gap`, unmerged, has uncommitted edits to this file). Do NOT hot-fix here — route to the search-gap slice or a dedicated chips fix so the edits don't collide.

### D2 — Agents-list subtitle head-truncation makes duplicate pinned rows indistinguishable at AX type — REAL DEFECT (large type)
- **Surface:** `AgentCardView` row, line 2 (agent title). `.lineLimit(1)` + `.truncationMode(.head)`.
- **Condition:** accessibility-extra-large Dynamic Type (`console-phone-a11xl.png`); not triggered at default size.
- **Observed:** both pinned rows render `...Attach experience` — the differentiating leading text is head-truncated away, so two different agents (the pinned duplicate + canonical copy, or two same-titled agents) are visually identical at a11x sizes. The full title is only a long-press/contextMenu away, which VoiceOver users get but low-vision sighted users may not discover.
- **Recommend:** allow the title line to wrap (2 lines) at accessibility sizes, or tail-truncate with the identity (tab label) preserved — a dedicated fix slice; trivial-but-sibling-owned (`AgentCardView.swift`).

### D3 — Q/A cards and assistant text render full-bleed on WIDE layouts — READABILITY FINDING (design gap, not a rendering bug)
- **Surface:** `ChatInteractionCard` container + `ChatAssistantArticleView` (`.frame(maxWidth: .infinity, alignment: .leading)`); only outgoing user bubbles carry the `min(0.85×, 560pt)` cap (`ChatRows.swift`).
- **Condition:** iPad wide, light + dark (`qa-wide-light.png` measure: card background ≈97–98% of screen width; the longest collapsed answer line runs ≈94% of the width).
- **Observed:** at 1376pt the collapsed A line truncates at "…widen to 50…" with line measure far past comfortable reading; the pending card stretches edge-to-edge.
- **Note:** the design doc's 560pt cap is specified for **outgoing bubbles** only; it does not currently state a measure cap for cards/assistant text. So this is a design-decision finding for the next design pass (or a one-line design-doc amendment), not a code regression. The phone captures are unaffected.

### D4 — Collapsed answered card gives NO visible expand affordance — DISCOVERABILITY FINDING
- **Surface:** `ChatResolvedAskCard.answerSummaryText` collapses the custom answer to one ellipsized line; expansion is a whole-card tap (`onTapGesture`) + AX action, with **no visual hint** (no chevron/More/more-link).
- **Condition:** all modes; most visible wide (`qa-wide-light.png`: "Stage the rollout…widen to 50…" with nothing suggesting the rest is readable) and at AX type (`qa-phone-a11xl.png`: "A Stage the rollout beh…" unrecoverable-looking).
- **Behavior:** tap DOES expand (UI-proofed in the Q/A slice), but a sighted user has no cue. Recommend a trailing "More"/chevron on the collapsed A line when truncation is active — dedicated fix slice (trivial, `ChatInteractionCard.swift`, owned by the Q/A card slice lineage).

### D5 — Floating jump control overlaps content edge at AX type — COSMETIC
- **Surface:** `ChatJumpControl` overlay (trailing, 8pt inset) floats over the transcript.
- **Condition:** accessibility-extra-large type (`bubbles-phone-a11xl.png`, `tables-phone-a11xl.png`, `qa-phone-a11xl.png`); default size shows only padding overlap (no glyphs).
- **Observed:** the 40pt circular button intersects long-bubble/card/table right padding. In every capture it covered padding, never glyphs — but at a11x wrap points the clearance is luck, not reserved space.
- **Recommend:** if a fix is wanted, inset the transcript's trailing padding by the control width while `showsOldest || showsNewest` — cosmetic, low priority.

### D6 — Table zebra/header fills nearly invisible in DARK mode — COSMETIC CONTRAST
- **Surface:** `ChatMarkdownView` table chrome: zebra `Color.primary.opacity(0.045)`, header `0.10`, separators `0.10` (`ChatTableBlock`).
- **Condition:** dark mode, wide + phone (`tables-wide-dark.png`): 4.5% white on black is ≈#0B0B0B — the vision pass read the striped rows as "detached from the table", and zebra starting-row parity was ambiguous between tables.
- **Note:** structurally the table is correct (no actual row detachment — the "cutoff container" impression is the invisible striping). Recommend bumping dark-mode striping opacity (e.g. 0.08–0.10) — trivial, in-surface, but left unfixed per report-only mandate.

### D7 — Wrapped code-span background fragments per line at AX type — COSMETIC
- **Surface:** code span inside a wrapping table cell (`tables-phone-a11xl.png`): `herdr agent attach` wrapped across 3 lines renders as three separate gray chips.
- **Note:** acceptable line-breaking behavior; flagged only because it reads as "broken highlight" at a11x sizes. No action recommended unless a continuous-chrome treatment is cheap.

## Observations judged NOT defects (checked, by design / fixture)

- **No composer on demo chat surfaces** (`bubbles/tables/QA`): the fixture routes pass `deliver` but `router: nil`, and ChatScreen renders the composer only when `router != nil && deliver != nil` (read-only demo transcripts by design). The production chat surface (via `NavigationRedesignProofTests` tap-through) shows the real composer row with + / field / send-arrow. The `chat-phone-light.png` production capture shows the honest "No Transcript" placeholder because the demo console has no broker chat backend — a fixture limitation, not a UI defect (the broker lane is the only chat path and needs a live host).
- **Terminal surface is dark under light system mode**: terminal themes are independent of system appearance and the status chrome resolves against theme luminance (`AgentComposerView.chromeColorScheme`) — by design per code comments.
- **Terminal title pill overlaps scrolling content**: the nav-bar principal rides a blur capsule on the terminal surface specifically so content can scroll under it — by design (`AgentDetailView` toolbar comment).
- **"5 of 5 agents" with 6 visible rows**: 5 real agents + the pinned section's intentional duplicate — by design (pins are bookmarks that duplicate).
- **"Connecting to Offline Server/Field Laptop…" rows persist**: the demo route's deterministic dial window (6s) + 30s reconnect policy — fixture behavior, not a render defect.
- **Status-bar "…" between time and Wi-Fi**: simulator's no-cellular indicator, not app chrome (not present in the app's windows; matches other sims).
- **Pending card shows Cancel but no Confirm/Send at rest**: `submitRow` shows "Send answers" only once all required questions have input; the footer honestly says "N questions left to answer" meanwhile. By design (validated submission), though the helper text "Select one or more, then confirm" slightly oversells the visible affordance — micro-copy nit, listed here for completeness.
- **Search placeholder "Title, host:, workspace:…"**: `host:` is a real filter-token syntax (type `host:foo`), so the comma is intentional syntax documentation, not a typo.

## Not covered (open for physical-device acceptance)

- Physical iPhone/iPad, hardware keyboard, floating (undocked) keyboard, VoiceOver, Reduce Motion — per the design doc these stay open; the design doc's physical-device acceptance-before-main rule is unchanged by this report.
- The unmerged sibling slices (Messages-style composer, header agent-menu, search-gap) will need their own matrix pass when they land.

## Revision notes

- Initial captures at 48580086; origin/main advanced during the run with: Q/A-card note removal + immediate Answered flip (85840b31), blank-viewport scroll-coordinator + keyboard-inset fixes (877b300d, b00b4d09, 9ef85e2d), drawer 44pt band (8f22d6b3, a9b3b2c3). None of those change the graded surfaces: the QA fixture re-capture (no note field) and the new viewport code were re-verified by rebuild at the final tip — the QA fixture's answered cards no longer render a Note row, which only REMOVES content from the graded captures (the D3/D4 findings stand unchanged; D6/D7/D1/D2/D5 are in code untouched by the later commits).
- Proofs: all captures vision-verified (per-capture questions in the slice transcript); `NavigationRedesignProofTests/testChatTerminalToggleKeepsPlacement` green on the QA phone sim. `HerdrOrderingProofTests` was also run on the WIDE sim and failed there for ENVIRONMENTAL reasons: on the iPad split the agents column starts hidden (detailOnly), so the phone-oriented proofs cannot reach the rows (the wide suite's own tests reveal the column through "Show Sidebar" first). NOT a product defect — herdr ordering + Pinned rendering is proven by the phone captures (`console-phone-light/dark/a11xl.png`).
