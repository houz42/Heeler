import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The v3 Q/A card: ONE card per ask interaction, a Q/A pair PER
// QUESTION. Unanswered and answered states share the SAME card family
// — paper background, subtle green border, 12pt radius, matching
// width/insets, accent eyebrow + footer separator; only contents and
// actions change after acceptance (option controls become static
// selected-answer chips with Q/A text and notes retained). No
// whole-card green wash, no user-message bubble styling. The design
// doc section 'Answered questions — one paired Q/A card' is the
// authoritative contract.
//
// Gesture arbitration: swipe left/right WITHIN the card navigates
// questions; vertical gestures scroll the conversation (the drag
// recognizer below only engages for predominantly-horizontal
// movement, and never for taps — option buttons, the custom-text
// field and scroll keep their normal behavior). Keyboard arrows and
// accessibility next/previous-question actions provide non-gesture
// equivalents. Long-press selection/text editing never navigates.

/// The shared card family chrome: paper background, subtle green
/// border, 12pt radius, 12pt padding — the exact tokens the v2
/// pending card established (`AgentPendingQuestionCard`), now used by
/// BOTH the unanswered and the answered card so the family reads as
/// one element before and after acceptance.
enum ChatInteractionCardChrome {
    static let cornerRadius: CGFloat = 12
    static let padding: CGFloat = 12
    static let segmentLength: CGFloat = 14
    static let segmentThickness: CGFloat = 2
    static let segmentSpacing: CGFloat = 4

    static let border = Color(
        red: 0xC4 / 255.0, green: 0xD5 / 255.0, blue: 0xCB / 255.0)

    /// The card container background + border. Callers lay content
    /// inside; the chrome is identical for both states.
    static func container<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(padding)
            .background(
                Color(uiColor: .systemBackground),
                in: RoundedRectangle(
                    cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(
                    cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - Thin segmented step indicators

/// The thin progress segments: one capsule per question, filled for
/// questions before the current one (the current question renders a
/// dot accent), unfilled ahead. Single-question cards OMIT the
/// indicators entirely (nothing to indicate; the eyebrow carries the
/// position instead). No Previous/Next buttons — swipe, keyboard
/// arrows and a11y actions navigate.
struct ChatInteractionStepSegments: View {
    /// 1-based current index.
    let step: Int
    let count: Int
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: ChatInteractionCardChrome.segmentSpacing) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                Capsule()
                    .fill(
                        index < step - 1
                            ? accent.opacity(0.55)
                            : (index == step - 1
                                ? accent
                                : Color.secondary.opacity(0.25)))
                    .frame(
                        width: ChatInteractionCardChrome.segmentLength,
                        height: ChatInteractionCardChrome.segmentThickness)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Horizontal question navigation (swipe + keyboard + a11y)

/// The card's question navigation: bound to the card's current
/// question index, driven by horizontal swipe (only), keyboard
/// arrows, and accessibility actions. Never wraps past the ends.
/// Vertical drags pass through untouched (scroll keeps them).
@MainActor
@Observable
final class ChatInteractionQuestionNavigation {
    /// 1-based current question index per interaction id.
    private(set) var stepByInteraction: [String: Int] = [:]

    func step(for interactionID: String) -> Int {
        stepByInteraction[interactionID] ?? 1
    }

    /// Advance/retreat with clamping; returns the new 1-based step.
    @discardableResult
    func move(
        _ direction: Int, interactionID: String, count: Int
    ) -> Int {
        guard count > 1 else { return 1 }
        let current = step(for: interactionID)
        let next = min(max(current + direction, 1), count)
        stepByInteraction[interactionID] = next
        return next
    }

    /// A stale/removed interaction's step never lingers.
    func reset(interactionID: String) {
        stepByInteraction.removeValue(forKey: interactionID)
    }
}

/// The horizontal-only drag that pages questions. `onPage(+1/-1)`
/// fires on a predominantly-horizontal drag of at least the paging
/// threshold; vertical drags never page (the ScrollView owns them),
/// and the gesture is disabled entirely for single-question cards.
private struct ChatInteractionSwipeModifier: ViewModifier {
    var enabled: Bool
    var onPage: (Int) -> Void

    @State private var dragStart: CGSize?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.translation
                        }
                    }
                    .onEnded { value in
                        defer { dragStart = nil }
                        guard enabled,
                            abs(value.translation.width)
                                > abs(value.translation.height),
                            abs(value.translation.width) > 44
                        else { return }
                        onPage(value.translation.width < 0 ? 1 : -1)
                    })
    }
}

// MARK: - The unanswered (interactive) card

/// One built answer payload per answered question — the submit seam's
/// unit. `customText` and `note` ride the payload so the producer
/// receives the full answer (the adapter's RemoteAnswer shape).
struct ChatInteractionAnswerPayload: Sendable, Equatable {
    let questionId: String
    let optionIds: [String]
    var customText: String? = nil
    var note: String? = nil
}

/// The unanswered Q/A card: one active question panel at a time with
/// thin step segments, horizontal swipe between questions (vertical
/// scrolls; horizontal must not trigger Back or a choice tap), radio
/// or checkbox options per the producer, an explicit Other text input
/// when the producer permits custom answers, an optional note, and
/// one Submit that validates every required question. Selecting a
/// single choice can ADVANCE to the next question but never submits
/// the whole interaction automatically.
struct ChatInteractionCard: View {
    let interaction: PendingInteraction
    /// True while the submission is awaiting authoritative
    /// acceptance — the card reads "Submitting answers" and disables
    /// duplicate submissions; only acceptance swaps to the resolved
    /// card (the store's resolution record drives that).
    var isSubmitting: Bool = false
    /// A failed/stale submit — surfaced inline; choices are retained
    /// so the user can retry or go back.
    var errorMessage: String? = nil
    var submit: ([ChatInteractionAnswerPayload]) async throws -> Void
    /// Formats a submit/cancel error into honest user copy (the
    /// screen's wire-message unwrap); nil falls back to
    /// localizedDescription.
    var errorText: ((any Error) -> String?)? = nil
    /// Cancel the whole ask (nil hides the affordance honestly — a
    /// backend without cancel support never fakes one).
    var cancel: (() async throws -> Void)? = nil
    /// External step navigation (keyboard arrows/a11y route through
    /// the same state, so the non-gesture equivalents stay in sync).
    var navigation: ChatInteractionQuestionNavigation? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// Per-interaction draft state (this card's own — the screen owns
    /// nothing): 1-based step, selections, custom text, notes.
    @State private var step: Int = 1
    @State private var selections: [String: Set<String>] = [:]
    @State private var customTexts: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var submitting = false
    @State private var error: String?

    private var questions: [PendingAskQuestion] {
        interaction.effectiveQuestions
    }

    private var currentQuestion: PendingAskQuestion? {
        let list = questions
        guard step >= 1, step <= list.count else { return list.first }
        return list[step - 1]
    }

    private var accent: Color { .accentColor }
    private var accentWash: Color { Color("AccentWash") }
    private var onAccentInk: Color { ChatAccentInk.color }
    private var optionBorder: Color {
        Color(red: 0xCA / 255.0, green: 0xD5 / 255.0, blue: 0xCD / 255.0)
    }

    private var isMultiSelect: Bool { currentQuestion?.multi ?? false }

    var body: some View {
        ChatInteractionCardChrome.container {
            VStack(alignment: .leading, spacing: 7) {
                header
                Text(currentQuestion?.text ?? interaction.question)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if isMultiSelect {
                    Text("Select one or more, then confirm.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                optionsView
                if currentQuestion?.allowCustom == true {
                    customTextView
                }
                noteView
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                footer
                // The footer separator + the single explicit Send
                // (validated by the card; missing questions named).
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 0.5)
                submitRow
            }
        }
        .modifier(ChatInteractionSwipeModifier(
            enabled: questions.count > 1 && !submitting,
            onPage: { direction in moveStep(direction) }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: "Next question") {
            moveStep(1)
        }
        .accessibilityAction(named: "Previous question") {
            moveStep(-1)
        }
        .accessibilityRespondsToUserInteraction(true)
        .onAppear { syncExternalNavigation() }
        .onChange(of: navigation?.step(for: interaction.id) ?? step) {
            _, external in
            // The keyboard/a11y path drove the navigation; adopt.
            if external != step { step = clamp(external) }
        }
        .onChange(of: interaction.id) { _, _ in
            // A re-ask after resolution is a NEW interaction: fresh
            // step, retained choices keyed by question id survive only
            // if the ids repeat (the producer's ids are stable).
            step = 1
            submitting = false
        }
        .onChange(of: isSubmitting) { _, newValue in
            submitting = submitting || newValue
        }
        .onChange(of: errorMessage) { _, newValue in
            error = newValue
        }
    }

    // MARK: chrome pieces

    private var header: some View {
        HStack(spacing: 6) {
            Label("Your input needed", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .fixedSize()
            Spacer(minLength: 0)
            if questions.count > 1 {
                Text("\(step) of \(questions.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                ChatInteractionStepSegments(
                    step: step, count: questions.count, accent: accent)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if step > 1 {
                Button {
                    moveStep(-1)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.footnote)
                }
                .accessibilityLabel("Previous question")
            }
            Spacer(minLength: 0)
            if submitting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Submitting answers")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let cancel {
                Button {
                    Task { @MainActor in
                        do { try await cancel() }
                        catch { setError(error, prefix: "Cancel failed") }
                    }
                } label: {
                    Text("Cancel")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancel this question")
            }
        }
    }

    // MARK: options

    @ViewBuilder
    private var optionsView: some View {
        let options = currentQuestion?.options ?? []
        let allCompact = options.allSatisfy { $0.label.count <= 24 }
        if allCompact {
            OptionFlowLayout(spacing: 8) {
                ForEach(options) { option in
                    optionButton(option, fullWidth: false)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(options) { option in
                    optionButton(option, fullWidth: true)
                }
            }
        }
    }

    private func optionButton(
        _ option: PendingAskQuestion.Option, fullWidth: Bool
    ) -> some View {
        let selected = selections[currentQuestion?.id ?? ""]?
            .contains(option.id) ?? false
        return Button {
            choose(option.id)
        } label: {
            Text(option.label)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 11)
                .frame(
                    maxWidth: fullWidth ? .infinity : nil,
                    minHeight: 44, alignment: .leading)
                .background(
                    selected ? accentWash : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            selected ? accent : optionBorder, lineWidth: 1))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(submitting)
        .accessibilityLabel(
            "\(isMultiSelect ? "Toggle" : "Answer"): \(option.label)")
    }

    private func choose(_ optionId: String) {
        guard !submitting, let question = currentQuestion else { return }
        var perQuestion = selections[question.id] ?? []
        if question.multi {
            if perQuestion.contains(optionId) {
                perQuestion.remove(optionId)
            } else {
                perQuestion.insert(optionId)
            }
            selections[question.id] = perQuestion
        } else {
            selections[question.id] = [optionId]
            // A single selection can ADVANCE to the next question but
            // never submits the whole interaction automatically.
            if step < questions.count {
                moveStep(1)
            }
        }
    }

    // MARK: custom text + note

    private var customTextView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                "Type your own answer", text: bindingForCustomText,
                axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(optionBorder, lineWidth: 1))
                .disabled(submitting)
                .accessibilityLabel("Custom answer")
        }
    }

    private var noteView: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "Add a note (optional)", text: bindingForNote, axis: .vertical)
                .font(.caption)
                .lineLimit(1...3)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(optionBorder, lineWidth: 1))
                .disabled(submitting)
                .accessibilityLabel("Explanatory note")
        }
    }

    private var bindingForCustomText: Binding<String> {
        Binding(
            get: { customTexts[currentQuestion?.id ?? ""] ?? "" },
            set: { customTexts[currentQuestion?.id ?? ""] = $0 })
    }

    private var bindingForNote: Binding<String> {
        Binding(
            get: { notes[currentQuestion?.id ?? ""] ?? "" },
            set: { notes[currentQuestion?.id ?? ""] = $0 })
    }

    // MARK: submission

    /// The footer separator + Submit row: visible whenever EVERY
    /// question is answered (the design's single explicit send), or
    /// disabled with the missing-count reason while some are not.
    @ViewBuilder
    private var submitRow: some View {
        let missing = missingRequiredCount
        if missing == 0 {
            Button {
                submitAnswers()
            } label: {
                Text("Send answers")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        accent, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(onAccentInk)
            }
            .disabled(submitting)
            .accessibilityLabel("Send answers")
        } else {
            Text(
                "\(missing) question\(missing == 1 ? "" : "s") left to answer")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var missingRequiredCount: Int {
        questions.filter { question in
            let hasSelection = !(selections[question.id]?.isEmpty ?? true)
            let hasCustom = !(customTexts[question.id] ?? "").isEmpty
            return !hasSelection && !hasCustom
        }.count
    }

    private func submitAnswers() {
        guard !submitting else { return }
        submitting = true
        error = nil
        var payloads: [ChatInteractionAnswerPayload] = []
        for question in questions {
            let custom = customTexts[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            payloads.append(ChatInteractionAnswerPayload(
                questionId: question.id,
                optionIds: (selections[question.id] ?? []).sorted(),
                customText: (custom?.isEmpty ?? true) ? nil : custom,
                note: notes[question.id]))
        }
        Task { @MainActor in
            do {
                try await submit(payloads)
                // The resolved card replaces this one when the store's
                // resolution lands; submitting stays until then.
            } catch {
                submitting = false
                setError(error, prefix: "Answer failed")
            }
        }
    }

    /// The honest error copy: the caller supplies the formatter (the
    /// screen's existing wire-message unwrap); the raw
 /// localizedDescription renders 'AgentChatError error 0' — opaque.
    private func setError(_ error: any Error, prefix: String) {
        if let errorText = errorText?(error) {
            self.error = "\(prefix): \(errorText)"
        } else {
            self.error = "\(prefix): \(error.localizedDescription)"
        }
    }

    // MARK: navigation

    private func moveStep(_ direction: Int) {
        guard questions.count > 1 else { return }
        let next = clamp(step + direction)
        if next != step {
            step = next
            navigation?.move(
                direction, interactionID: interaction.id,
                count: questions.count)
            // Keep the external nav exactly in sync even at the ends
            // (its own clamp agrees).
        }
    }

    private func clamp(_ value: Int) -> Int {
        min(max(value, 1), max(questions.count, 1))
    }

    private func syncExternalNavigation() {
        if let navigation {
            let external = navigation.step(for: interaction.id)
            if external != step { step = clamp(external) }
        }
    }

    private var accessibilitySummary: String {
        let questionCount = questions.count
        var summary = "Question card"
        if questionCount > 1 {
            summary += ", question \(step) of \(questionCount)"
        }
        if submitting { summary += ", submitting answers" }
        if let error { summary += ", \(error)" }
        return summary
    }
}

// MARK: - The answered (resolved) card

/// The answered Q/A card: the SAME card family, now a static record.
/// Q then A on separate lines per question; selected options render
/// their LABELS in producer order (chips when short, a list when
/// long); a free-text answer renders the actual text as `A:`. The
/// collapsed summary keeps each long answer to ONE ellipsized line;
/// tapping the card expands the full answer and notes (exact source
/// and whitespace preserved, selection/copy intact), tapping again
/// collapses. No Show-details button. Swipe still navigates between
/// questions; single-question cards omit the indicators. The footer
/// separator carries the neutral "Answered" eyebrow regardless of
/// origin (local/remote/terminal styling is identical; provenance is
/// internal, never a user-visible distinction).
struct ChatResolvedAskCard: View {
    let ask: ResolvedAsk

    @State private var step: Int = 1
    @State private var expanded = false

    private var questions: [ResolvedAskQuestion] { ask.questions }

    private var accent: Color { .accentColor }

    private var isAnswered: Bool { ask.outcome == .youAnswered }

    /// The current pair: falls back to a synthetic record for a
    /// zero-question card (remote answer with missing details /
    /// cancelled / expired) so the Q line still renders the anchor
    /// question and the A line the honest outcome.
    private var currentPair: ResolvedAskQuestion {
        if questions.isEmpty {
            return ResolvedAskQuestion(
                id: "q",
                question: ask.questionText ?? "")
        }
        return questions[min(step, questions.count) - 1]
    }

    var body: some View {
        ChatInteractionCardChrome.container {
            VStack(alignment: .leading, spacing: 7) {
                header
                questionView
                answerView
                footer
            }
        }
        .modifier(ChatInteractionSwipeModifier(
            enabled: questions.count > 1,
            onPage: { direction in moveStep(direction) }))
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap toggles expansion — but only when there is
            // long-content to expand (a short one-line answer never
            // gains a meaningless toggle). Selecting text or swiping
            // must not accidentally toggle: selection long-press does
            // not fire tap, and the swipe modifier's drag never
            // completes a tap.
            withAnimation(.snappy) { expanded.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resolved-ask-card-\(ask.id)")
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityAction(named: "Toggle full answer") {
            withAnimation(.snappy) { expanded.toggle() }
        }
        .accessibilityAction(named: "Next question") {
            moveStep(1)
        }
        .accessibilityAction(named: "Previous question") {
            moveStep(-1)
        }
        .accessibilityRespondsToUserInteraction(true)
        .onChange(of: ask.id) { _, _ in
            step = 1
            expanded = false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(
                isAnswered ? "Answered" : eyebrowForOutcome,
                systemImage: isAnswered
                    ? "checkmark.circle" : outcomeIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .fixedSize()
            Spacer(minLength: 0)
            if questions.count > 1 {
                Text("\(min(step, questions.count)) of \(questions.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                ChatInteractionStepSegments(
                    step: min(step, questions.count),
                    count: questions.count, accent: accent)
            }
        }
    }

    private var questionView: some View {
        // Q — the producer's original question/summary, never an AI
        // paraphrase; secondary, compact. Omitted entirely when even
        // the anchor question is unknown.
        Group {
            if !currentPair.question.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Q")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    Text(currentPair.question)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var answerView: some View {
        if isAnswered {
            answeredView
        } else {
            // The honest outcome — never accepted-answer styling.
            Text(ask.outcome.outcomeText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// The answered state: A line (one ellipsized line collapsed;
    /// full text expanded), selected-label chips in producer order,
    /// the additional-answer paragraph, and the separately-labeled
    /// note. Empty optional notes are omitted.
    @ViewBuilder
    private var answeredView: some View {
        let pair = currentPair
        let hasSelections = !pair.selectedOptions.isEmpty
        let hasCustom =
            !(pair.customAnswerText ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
        let note = pair.note?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if !hasSelections && !hasCustom {
                // Missing answer data: the honest placeholder — never
                // a fabricated choice.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("A")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    Text("Answer details unavailable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("A")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    answerSummaryText(pair)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if expanded {
                // Full detail, exact source preserved: selected labels
                // as chips (or a list when long), the additional
                // answer paragraph (ONLY when selection PLUS custom
                // text — a free-text-only answer already IS the A
                // line), the separately-labeled note.
                if hasSelections {
                    selectedOptionsView(pair)
                }
                if hasCustom && hasSelections {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Additional answer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pair.customAnswerText ?? "")
                            .font(.footnote)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !note.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Note")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The A line: selected labels joined with " · " (a wrap-safe
    /// separator that is DISPLAY-ONLY — the stored answer is the
    /// structured record, never this string), or the custom text —
    /// ONE ellipsized line collapsed (the A row's lineLimit does the
    /// truncation), the FULL text expanded (free-text-only answers
    /// expand in place; selection+custom carries the custom text in
    /// the Additional answer paragraph).
    private func answerSummaryText(
        _ pair: ResolvedAskQuestion
    ) -> Text {
        if !pair.selectedOptions.isEmpty {
            return Text(
                pair.selectedOptions.map(\.label).joined(separator: " · "))
        }
        return Text(pair.customAnswerText ?? "Answer details unavailable.")
    }

    /// Selected options in PRODUCER order: short labels flow as
    /// compact chips; long labels stack as a full-width list. Never
    /// serialized with ambiguous punctuation as the stored answer.
    @ViewBuilder
    private func selectedOptionsView(
        _ pair: ResolvedAskQuestion
    ) -> some View {
        let labels = pair.selectedOptions.map(\.label)
        if labels.allSatisfy({ $0.count <= 24 }) {
            OptionFlowLayout(spacing: 6) {
                ForEach(pair.selectedOptions) { option in
                    Text(option.label)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color("AccentWash"),
                            in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pair.selectedOptions) { option in
                    Text(option.label)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The footer separator: the card family's shared quiet base line
    /// (hairline + spacing), carrying n-of-N when multi-question.
    @ViewBuilder
    private var footer: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.top, 2)
    }

    private func moveStep(_ direction: Int) {
        guard questions.count > 1 else { return }
        let next = min(max(step + direction, 1), questions.count)
        if next != step { step = next }
    }

    private var eyebrowForOutcome: String {
        switch ask.outcome {
        case .youAnswered: return "Answered"
        case .answeredInTerminal: return "Answered in terminal"
        case .answeredRemotely: return "Answered"
        case .cancelled: return "Cancelled"
        case .expired: return "Expired"
        case .settledElsewhere: return "Settled"
        }
    }

    private var outcomeIcon: String {
        switch ask.outcome {
        case .youAnswered: return "checkmark.circle"
        case .answeredInTerminal: return "terminal"
        case .answeredRemotely: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        case .expired: return "clock.badge.xmark"
        case .settledElsewhere: return "questionmark.circle"
        }
    }

    private var accessibilitySummary: String {
        var summary = "Answered question card"
        if questions.count > 1 {
            summary += ", question \(min(step, questions.count)) of \(questions.count)"
        }
        if !isAnswered {
            summary += ". \(ask.outcome.outcomeText)"
        }
        return summary
    }
}

// MARK: - The pending (awaiting acceptance) resolved-swap state

/// The "Submitting answers" card: the SAME card family, shown between
/// submit and authoritative acceptance — the pending card stays
/// "Submitting answers" until the store's resolution replaces it.
/// Noninteractive: options render as the chosen chips (readable,
/// proposed), no submit/cancel affordances duplicate-fire.
struct ChatSubmittingAskCard: View {
    let interaction: PendingInteraction
    /// The proposed answers (one payload per question, built by the
    /// unanswered card at submit time).
    let payloads: [ChatInteractionAnswerPayload]

    private var accent: Color { .accentColor }

    var body: some View {
        ChatInteractionCardChrome.container {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Label(
                        "Submitting answers",
                        systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .fixedSize()
                    Spacer(minLength: 0)
                    ProgressView()
                        .controlSize(.small)
                }
                ForEach(Array(zip(interaction.effectiveQuestions, payloads)),
                    id: \.0.id)
                { question, payload in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question.text)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(proposedAnswerText(question: question, payload: payload))
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 0.5)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Submitting answers")
    }

    /// The proposed answer line: selected labels (producer order) or
    /// the custom text — readable while awaiting acceptance, styled
    /// as PROPOSED, never as accepted.
    private func proposedAnswerText(
        question: PendingAskQuestion,
        payload: ChatInteractionAnswerPayload
    ) -> String {
        let labels = question.options
            .filter { payload.optionIds.contains($0.id) }
            .map(\.label)
        if !labels.isEmpty { return "A: " + labels.joined(separator: " · ") }
        if let custom = payload.customText, !custom.isEmpty {
            return "A: " + custom
        }
        return "A: —"
    }
}

// MARK: - Previews

#if DEBUG
private struct ChatInteractionCardPreviewFixture {
    static var multiQuestionAsk: PendingInteraction {
        PendingInteraction(
            id: "demo-ask",
            question: "",
            options: [],
            questions: [
                PendingAskQuestion(
                    id: "q0",
                    text: "Which checks should run before the retry lands?",
                    multi: true,
                    options: [
                        .init(id: "o0", label: "Unit suite"),
                        .init(id: "o1", label: "UI smoke"),
                        .init(id: "o2", label: "Device build"),
                    ]),
                PendingAskQuestion(
                    id: "q1",
                    text: "Who reviews the pull request?",
                    options: [
                        .init(id: "o0", label: "You"),
                        .init(id: "o1", label: "Me"),
                        .init(id: "o2", label: "Both of us"),
                    ],
                    allowCustom: true),
            ])
    }
}

#Preview("Q/A card — unanswered, light") {
    ScrollView {
        ChatInteractionCard(
            interaction: ChatInteractionCardPreviewFixture.multiQuestionAsk,
            submit: { _ in })
            .padding(12)
    }
    .preferredColorScheme(.light)
}

#Preview("Q/A card — unanswered, dark") {
    ScrollView {
        ChatInteractionCard(
            interaction: ChatInteractionCardPreviewFixture.multiQuestionAsk,
            submit: { _ in })
            .padding(12)
    }
    .preferredColorScheme(.dark)
}

#Preview("Q/A card — answered, light") {
    ScrollView {
        VStack(spacing: 12) {
            ChatResolvedAskCard(
                ask: ResolvedAsk(
                    id: "r1",
                    questions: [
                        ResolvedAskQuestion(
                            id: "q0",
                            question: "Which checks should run before the retry lands?",
                            selectedOptions: [
                                .init(id: "o0", label: "Unit suite"),
                                .init(id: "o2", label: "Device build"),
                            ],
                            note: "Include the first ten seconds only."),
                        ResolvedAskQuestion(
                            id: "q1",
                            question: "Who reviews the pull request?",
                            customAnswerText: "I'll take it after lunch"),
                    ],
                    outcome: .youAnswered,
                    questionText: "Which checks should run before the retry lands?"))
            ChatResolvedAskCard(
                ask: ResolvedAsk(
                    id: "r2", questions: [],
                    outcome: .answeredRemotely,
                    questionText: "Ship the v3 slice?"))
        }
        .padding(12)
    }
    .preferredColorScheme(.light)
}

#Preview("Q/A card — answered, dark") {
    ScrollView {
        VStack(spacing: 12) {
            ChatResolvedAskCard(
                ask: ResolvedAsk(
                    id: "r1",
                    questions: [
                        ResolvedAskQuestion(
                            id: "q0",
                            question: "Which checks should run before the retry lands?",
                            selectedOptions: [
                                .init(id: "o0", label: "Unit suite"),
                                .init(id: "o2", label: "Device build"),
                            ],
                            note: "Include the first ten seconds only."),
                        ResolvedAskQuestion(
                            id: "q1",
                            question: "Who reviews the pull request?",
                            customAnswerText: "I'll take it after lunch"),
                    ],
                    outcome: .youAnswered,
                    questionText: "Which checks should run before the retry lands?"))
            ChatResolvedAskCard(
                ask: ResolvedAsk(
                    id: "r2", questions: [],
                    outcome: .answeredRemotely,
                    questionText: "Ship the v3 slice?"))
        }
        .padding(12)
    }
    .preferredColorScheme(.dark)
}

#Preview("Q/A card — submitting") {
    ScrollView {
        ChatSubmittingAskCard(
            interaction: ChatInteractionCardPreviewFixture.multiQuestionAsk,
            payloads: [
                .init(questionId: "q0", optionIds: ["o0", "o2"]),
                .init(questionId: "q1", optionIds: [], customText: "I'll take it"),
            ])
            .padding(12)
    }
}
#endif
