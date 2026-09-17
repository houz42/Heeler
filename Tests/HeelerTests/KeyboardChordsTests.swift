import CoreGraphics
import Foundation
import Testing

@testable import Heeler

@Suite("Keyboard chords")
struct KeyboardChordsTests {
    // MARK: Long-press chord state machine

    private struct TestVariant: Identifiable, Hashable {
        let id: String
    }

    @Test func pressThenHoldOpensMenu() {
        var machine = LongPressChordMachine<TestVariant>()
        machine.press(variants: [TestVariant(id: "a"), TestVariant(id: "b")])
        #expect(!machine.isMenuOpen)
        // Hoisted out of #expect: the macro captures the machine immutably,
        // so a mutating call cannot live inside the expression.
        let opened = machine.longPressFired()
        #expect(opened)
        #expect(machine.isMenuOpen)
    }

    @Test func releaseWithoutSelectionCancelsButSuppressesTap() {
        var machine = LongPressChordMachine<TestVariant>()
        machine.press(variants: [TestVariant(id: "a"), TestVariant(id: "b")])
        machine.longPressFired()
        #expect(machine.end() == nil)
        #expect(!machine.isMenuOpen)
        // The key's own release must not also send the plain key.
        #expect(machine.isTapSuppressed)
        machine.clearTapSuppression()
        #expect(!machine.isTapSuppressed)
    }

    @Test func dragSelectThenReleaseConfirms() {
        var machine = LongPressChordMachine<TestVariant>()
        let variants = [
            TestVariant(id: "a"), TestVariant(id: "b"), TestVariant(id: "c"),
        ]
        machine.press(variants: variants)
        machine.longPressFired()
        machine.select(atX: 50, y: 10, stripWidth: 120, stripHeight: 40)
        #expect(machine.selection == 1)
        #expect(machine.end() == TestVariant(id: "b"))
        #expect(!machine.isMenuOpen)
        // Suppression survives the confirm: the release passes the key's
        // tap action after the variant already went out.
        #expect(machine.isTapSuppressed)
    }

    @Test func draggingOutsideTheStripClearsSelection() {
        var machine = LongPressChordMachine<TestVariant>()
        machine.press(variants: [TestVariant(id: "a"), TestVariant(id: "b")])
        machine.longPressFired()
        machine.select(atX: 30, y: 10, stripWidth: 100, stripHeight: 40)
        #expect(machine.selection == 0)
        machine.select(atX: -5, y: 10, stripWidth: 100, stripHeight: 40)
        #expect(machine.selection == nil)
        machine.select(atX: 50, y: 45, stripWidth: 100, stripHeight: 40)
        #expect(machine.selection == nil)
        #expect(machine.end() == nil)
    }

    @Test func selectionClampsToTheStripBands() {
        var machine = LongPressChordMachine<TestVariant>()
        let variants = [TestVariant(id: "a"), TestVariant(id: "b"), TestVariant(id: "c")]
        machine.press(variants: variants)
        machine.longPressFired()
        // The right edge belongs to the last band, not to nothing.
        machine.select(atX: 100, y: 10, stripWidth: 100, stripHeight: 40)
        #expect(machine.selection == 2)
        // An unmeasured strip (size zero) cannot select.
        machine.select(atX: 50, y: 10, stripWidth: 0, stripHeight: 0)
        #expect(machine.selection == nil)
    }

    @Test func pressWithoutVariantsNeverOpens() {
        var machine = LongPressChordMachine<TestVariant>()
        machine.press(variants: [])
        let opened = machine.longPressFired()
        #expect(!opened)
        #expect(!machine.isMenuOpen)
        #expect(machine.end() == nil)
        #expect(!machine.isTapSuppressed)
    }

    @Test func secondPressDuringOpenMenuIsIgnored() {
        var machine = LongPressChordMachine<TestVariant>()
        let held = [TestVariant(id: "held")]
        machine.press(variants: held)
        machine.longPressFired()
        machine.press(variants: [TestVariant(id: "intruder")])
        #expect(machine.isMenuOpen)
        #expect(machine.variants == held)
    }

    @Test func cancelClosesMenuButKeepsTapSuppression() {
        var machine = LongPressChordMachine<TestVariant>()
        machine.press(variants: [TestVariant(id: "a")])
        machine.longPressFired()
        machine.cancel()
        #expect(!machine.isMenuOpen)
        #expect(machine.isTapSuppressed)
        // The originating finger still has to release past its key's action.
        machine.clearTapSuppression()
        #expect(!machine.isTapSuppressed)
    }

    @Test func resetClearsEverything() {
        var machine = LongPressChordMachine<TestVariant>()
        machine.press(variants: [TestVariant(id: "a")])
        machine.longPressFired()
        machine.reset()
        #expect(!machine.isMenuOpen)
        #expect(machine.variants.isEmpty)
        #expect(!machine.isTapSuppressed)
    }

    @Test func variantTableDrivesTheChordKeys() {
        // The table is the feature's contract: these keys hold variants,
        // and the repeating Backspace cap deliberately does not.
        #expect(LongPressChordVariants.variants(for: .escape) != nil)
        #expect(LongPressChordVariants.variants(for: .tab) != nil)
        #expect(LongPressChordVariants.variants(for: .shiftTab) != nil)
        #expect(LongPressChordVariants.variants(for: .enter) != nil)
        for key: AgentQuickKey in [.left, .up, .right, .down] {
            #expect(LongPressChordVariants.variants(for: key) != nil)
        }
        #expect(LongPressChordVariants.variants(for: .backspace) == nil)
    }

    @Test func tabVariantsOfferBacktabAndCtrlI() throws {
        let variants = try #require(LongPressChordVariants.variants(for: .tab))
        #expect(variants.map(\.title) == ["Tab", "⇧Tab", "⌃I"])
        let ctrlI = try #require(variants.last)
        #expect(ctrlI.steps == [
            KeyChordStep(key: .character("i"), modifiers: .control),
        ])
    }

    @Test func escapeVariantsIncludeDoubleEscape() throws {
        let variants = try #require(LongPressChordVariants.variants(for: .escape))
        let double = try #require(variants.last)
        #expect(double.steps == [
            KeyChordStep(key: .escape, modifiers: []),
            KeyChordStep(key: .escape, modifiers: []),
        ])
    }

    @Test func arrowVariantsIncludeModifiedArrows() throws {
        let variants = try #require(LongPressChordVariants.variants(for: .left))
        #expect(variants.map(\.title) == ["←", "⌃←", "⌥←", "⇧←"])
        #expect(variants.map(\.steps.first?.modifiers) == [[], .control, .option, .shift])
    }

    // MARK: Macro key store

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-keyboard-chords-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func macroBindingRoundTripsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = MacroKeyStore(defaults: defaults)
        let snippetID = UUID()
        #expect(store.setBinding(slot: 2, paneID: "pane-1", snippetID: snippetID, args: " --fast"))
        #expect(store.setBinding(slot: 5, paneID: "pane-1", snippetID: UUID(), args: ""))

        let reloaded = MacroKeyStore(defaults: defaults)
        let slot2 = try #require(reloaded.binding(slot: 2, paneID: "pane-1"))
        #expect(slot2.snippetID == snippetID)
        #expect(slot2.args == " --fast")
        #expect(reloaded.binding(slot: 5, paneID: "pane-1")?.args.isEmpty == true)
        #expect(reloaded.bindings(paneID: "pane-1").count == 2)
    }

    @Test func macroBindingsAreIsolatedPerPane() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = MacroKeyStore(defaults: defaults)
        let sharedSnippet = UUID()
        #expect(store.setBinding(slot: 1, paneID: "pane-a", snippetID: sharedSnippet, args: "a"))
        #expect(store.setBinding(slot: 1, paneID: "pane-b", snippetID: UUID(), args: "b"))

        #expect(store.binding(slot: 1, paneID: "pane-a")?.args == "a")
        #expect(store.binding(slot: 1, paneID: "pane-b")?.args == "b")
        // Clearing on one pane leaves the other untouched.
        store.clearBinding(slot: 1, paneID: "pane-a")
        #expect(store.binding(slot: 1, paneID: "pane-a") == nil)
        #expect(store.binding(slot: 1, paneID: "pane-b") != nil)
    }

    @Test func rebindingASlotReplacesItInPlace() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = MacroKeyStore(defaults: defaults)
        #expect(store.setBinding(slot: 3, paneID: "p", snippetID: UUID(), args: "old"))
        let replacement = UUID()
        #expect(store.setBinding(slot: 3, paneID: "p", snippetID: replacement, args: "new"))
        let bindings = store.bindings(paneID: "p")
        #expect(bindings[3]?.snippetID == replacement)
        #expect(bindings[3]?.args == "new")
        #expect(bindings.count == 1)
    }

    @Test func invalidSlotsAndArgsAreRejected() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = MacroKeyStore(defaults: defaults)
        for slot in [0, MacroKeyStore.slotRange.upperBound + 1] {
            #expect(!store.setBinding(slot: slot, paneID: "p", snippetID: UUID(), args: ""))
        }
        // An escape in args would be read as a command by the remote terminal.
        #expect(!store.setBinding(slot: 1, paneID: "p", snippetID: UUID(), args: "\u{1B}"))
        #expect(store.bindings(paneID: "p").isEmpty)
        // Rejected writes persist nothing; valid ones still land.
        #expect(store.setBinding(slot: 1, paneID: "p", snippetID: UUID(), args: "ok"))
        #expect(store.bindings(paneID: "p").count == 1)
    }

    @Test func argsFollowTheSnippetTextPolicy() {
        #expect(MacroKeyStore.isValidArgs("plain text"))
        #expect(MacroKeyStore.isValidArgs("multi\nline\ttabs"))
        // CR is a safe scalar by the policy's own definition — setBinding
        // normalizes it to LF instead of rejecting it.
        #expect(MacroKeyStore.isValidArgs("carriage\rreturn"))
        #expect(!MacroKeyStore.isValidArgs(String(repeating: "x", count: MacroKeyStore.argsCharacterLimit + 1)))
    }


    @Test func setBindingNormalizesCarriageReturnsInArgs() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = MacroKeyStore(defaults: defaults)
        // CRLF collapses to LF: a CR is a submit byte in disguise.
        #expect(store.setBinding(slot: 1, paneID: "p", snippetID: UUID(), args: "a\r\nb"))
        #expect(store.binding(slot: 1, paneID: "p")?.args == "a\nb")
    }

    @Test func corruptBlobStartsEmptyAndStaysWritable() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        defaults.set(Data("not json".utf8), forKey: MacroKeyStore.key(paneID: "p"))
        let store = MacroKeyStore(defaults: defaults)
        #expect(store.bindings(paneID: "p").isEmpty)
        // The next write clobbers the undecodable bytes — macros are cheap
        // to lose, unlike the authored Snippet catalog.
        #expect(store.setBinding(slot: 4, paneID: "p", snippetID: UUID(), args: ""))
        #expect(MacroKeyStore(defaults: defaults).binding(slot: 4, paneID: "p") != nil)
    }

    // MARK: Prefix swipe → byte sequence

    /// Records what the swipe-to-chord path sends; the production wiring
    /// hands the recognizer's bytes to its own send closure.
    private final class RecordingByteSink {
        private(set) var sent: [Data] = []

        func send(_ data: Data) {
            sent.append(data)
        }
    }

    @Test func swipeLeftSendsPrefixAndLeftArrow() throws {
        let sink = RecordingByteSink()
        let direction = try #require(
            PrefixSwipeRecognizer.direction(translation: CGSize(width: -80, height: 0)))
        #expect(direction == .left)
        sink.send(PrefixSwipeRecognizer.chord(for: direction))
        #expect(sink.sent == [Data([0x02, 0x1B, 0x5B, 0x44])])
    }

    @Test func swipeRightSendsPrefixAndRightArrow() throws {
        let sink = RecordingByteSink()
        let direction = try #require(
            PrefixSwipeRecognizer.direction(translation: CGSize(width: 80, height: 0)))
        #expect(direction == .right)
        sink.send(PrefixSwipeRecognizer.chord(for: direction))
        #expect(sink.sent == [Data([0x02, 0x1B, 0x5B, 0x43])])
    }

    @Test func swipeUpSendsPrefixAndUpArrow() throws {
        let sink = RecordingByteSink()
        let direction = try #require(
            PrefixSwipeRecognizer.direction(translation: CGSize(width: 0, height: -80)))
        #expect(direction == .up)
        sink.send(PrefixSwipeRecognizer.chord(for: direction))
        #expect(sink.sent == [Data([0x02, 0x1B, 0x5B, 0x41])])
    }

    @Test func shortAndDownwardSwipesSendNothing() {
        let sink = RecordingByteSink()
        let translations = [
            CGSize(width: -20, height: 0),  // below the recognition distance
            CGSize(width: 0, height: 40),  // downward: no chord direction
            CGSize(width: 8, height: -8),  // ambiguous diagonal
        ]
        for translation in translations {
            if let direction = PrefixSwipeRecognizer.direction(translation: translation) {
                sink.send(PrefixSwipeRecognizer.chord(for: direction))
            }
        }
        #expect(sink.sent.isEmpty)
    }

    @Test func dominantAxisWinsTheDirection() throws {
        #expect(PrefixSwipeRecognizer.direction(
            translation: CGSize(width: -50, height: -10)) == .left)
        #expect(PrefixSwipeRecognizer.direction(
            translation: CGSize(width: -10, height: -50)) == .up)
        #expect(PrefixSwipeRecognizer.direction(
            translation: CGSize(width: 44, height: -44)) == nil)
    }
}
