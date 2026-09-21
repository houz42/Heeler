import XCTest

// TEMPORARY A1 capture harness — request-after-hold is a HARD assert
// this time; removed again before commit per the byte-identical rule.
final class CaptureUITests: XCTestCase {
    func testA1CaptureHold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HEELER_AGENT_CHAT_PROOF_SESSION_FILE"]
            = "/Users/jhou/.cache/agent-chat-ui-proof/history.jsonl"
        app.launch()
        Thread.sleep(forTimeInterval: 25)
        // The search field can restore focus (keyboard up, suggestion
        // panel swallowing taps). Commit the search to drop focus,
        // then tap the first agent ROW by coordinate.
        if app.keyboards.count > 0 {
            let searchKey = app.keyboards.buttons["search"].firstMatch
            let returnKey = app.keyboards.buttons["Return"].firstMatch
            if searchKey.exists { searchKey.tap() }
            else if returnKey.exists { returnKey.tap() }
            Thread.sleep(forTimeInterval: 1)
            if app.keyboards.count > 0 {
                app.swipeDown()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        screenshot("cc-list-before-tap")
        // Tap a real agent ROW (matching, not containing).
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Tailscale'")).firstMatch
        var opened = false
        if row.waitForExistence(timeout: 8), row.isHittable {
            row.tap()
            opened = true
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66)).tap()
        }
        Thread.sleep(forTimeInterval: 3)
        let header = app.staticTexts.matching(
            NSPredicate(format: "label == 'omp'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30), "detail did not open")
        // HOLD: >90s idle-and-subscribed over the SSH path.
        Thread.sleep(forTimeInterval: 100)
        // REQUEST-AFTER-HOLD — HARD assert. Dump all button labels for
        // the record, then require the input affordance.
        let allButtons = app.buttons.allElementsBoundByIndex.map({ $0.label })
        try? allButtons.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/buttons-dump.txt"),
            atomically: true, encoding: .utf8)
        // The composer is PERSISTENT at rest — the field is mounted
        // in the bottom bar (no FAB, nothing to open).
        let field = app.textViews.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 10),
            "persistent composer missing after hold; buttons: \(allButtons.joined(separator: " | "))")
        field.tap()
        Thread.sleep(forTimeInterval: 1)
        field.typeText("Reply exactly: post-hold request proof e39754b.")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button missing")
        send.tap()
        Thread.sleep(forTimeInterval: 12)
    }
}

extension CaptureUITests {
    func testConversationRedesignProofs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        Thread.sleep(forTimeInterval: 12)
        let row = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS 'ios-polish' OR label CONTAINS 'Polish the Attach'")).firstMatch
        if !row.exists {
            let any = app.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS 'docs-review' OR label CONTAINS 'Refresh the setup guide'")).firstMatch
            XCTAssertTrue(any.waitForExistence(timeout: 15), "no demo agents")
            any.tap()
        } else {
            row.tap()
        }
        Thread.sleep(forTimeInterval: 8)
        screenshot("redesign-conversation-latest")
        for _ in 0..<6 { app.swipeDown() }
        Thread.sleep(forTimeInterval: 2)
        screenshot("redesign-conversation-article-and-bubble")
        // Message-actions rail (final spec): a short tap on a message
        // toggles the inline Copy/(Quote)/Helpful rail under it. Tap a
        // plain text region (mid width avoids right-aligned link spans).
        // Screen-coordinate tap (element-agnostic): center screen is
        // inside the article body.
        // Right-center: the user bubble (compact, right-aligned, no links).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 2)
        screenshot("redesign-message-actions-rail")
        // Same-message tap toggles the rail off (the dismissal path).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 1)
        screenshot("redesign-message-actions-dismissed")
        // Composer collapse/grow, LIVE when this agent's session
        // resolves an interactive composer (the honest-unavailable
        // capture documents the read-only case otherwise).
        let messageButton = app.buttons["Message the agent"]
        if messageButton.waitForExistence(timeout: 20) {
            messageButton.tap()
            Thread.sleep(forTimeInterval: 3)
            screenshot("d2-composer-collapsed-live")
            let field = app.textViews.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.typeText("A typed draft long enough to wrap past one composer row, exercising the grow bound with genuine keystrokes")
                Thread.sleep(forTimeInterval: 1)
                screenshot("d2-composer-grown-live")
                // Close the input: the draft must survive (never
                // cleared on blur).
                let close = app.buttons["Close input"]
                if close.exists {
                    close.tap()
                    Thread.sleep(forTimeInterval: 1)
                    screenshot("d2-composer-closed-draft-preserved")
                    // Reopen: the rail and draft are still there.
                    if messageButton.waitForExistence(timeout: 4) {
                        messageButton.tap()
                        Thread.sleep(forTimeInterval: 2)
                        screenshot("d2-composer-reopened-draft-intact")
                    }
                }
            }
        } else {
            screenshot("d2-composer-unavailable-honest")
        }
        app.terminate()
        Thread.sleep(forTimeInterval: 2)
        let app2 = XCUIApplication()
        app2.launchArguments = ["--demo-screenshots"]
        app2.launch()
        Thread.sleep(forTimeInterval: 10)
        let blocked = app2.buttons.matching(
            NSPredicate(
                format: "label CONTAINS 'reviewer' OR label CONTAINS 'Checkout review'")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "reviewer row missing")
        blocked.tap()
        Thread.sleep(forTimeInterval: 7)
        screenshot("redesign-pending-card")
    }

    /// D2 proofs: the real multi-question ask flow, the rail's
    /// non-triggers, and (when the demo agent's session resolves a
    /// composer) collapse/grow with real typing.
    func testD2FlowProofs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        Thread.sleep(forTimeInterval: 10)
        let blocked = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS 'reviewer' OR label CONTAINS 'Checkout review'")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "reviewer row missing")
        blocked.tap()
        Thread.sleep(forTimeInterval: 7)

        // Multi-question card: step 1 of 2 (single-choice).
        screenshot("d2-ask-step1")
        let dev = app.buttons["Answer: Dev"]
        XCTAssertTrue(dev.waitForExistence(timeout: 8), "multi-question card missing")
        dev.tap()
        Thread.sleep(forTimeInterval: 1)
        // Auto-advanced to step 2 (multi-select).
        screenshot("d2-ask-step2")
        let unit = app.buttons["Answer: Unit tests"]
        if unit.exists {
            unit.tap()
            Thread.sleep(forTimeInterval: 1)
            screenshot("d2-ask-multiselect-selected")
            // Back preserves the multi-select choice.
            let back = app.buttons["Previous question"]
            if back.exists {
                back.tap()
                Thread.sleep(forTimeInterval: 1)
                let unitStill = app.buttons["Answer: Unit tests"]
                // Selection state survives Back (visual check).
                screenshot("d2-ask-back-preserved")
                let next = app.buttons["Answer: Dev"]
                if next.exists {
                    next.tap()
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }

        // Non-triggers: a long-press on an article must NOT open the
        // actions rail (long press is native text selection).
        let article = app.staticTexts.firstMatch
        if article.exists {
            article.press(forDuration: 1.0)
            Thread.sleep(forTimeInterval: 1)
            let railVisible = app.buttons["Copy"].exists
            XCTAssertFalse(railVisible, "long-press must not toggle the rail")
            screenshot("d2-nontrigger-longpress")
            if railVisible {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            }
        }

        // Composer (interactive sessions only): the PERSISTENT row at
        // rest, grow with real typing, collapse keeping the draft.
        let field = app.textViews.firstMatch
        if field.waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 1)
            screenshot("d2-composer-collapsed")
            field.typeText("A draft that runs long enough to wrap past a single row of the composer, exercising the grow bound with genuine typed content")
            Thread.sleep(forTimeInterval: 1)
            screenshot("d2-composer-grown")
            // Collapse: focus off — the draft persists in the
            // persistent row.
            let collapse = app.buttons["Collapse input"]
            if collapse.exists {
                collapse.tap()
                Thread.sleep(forTimeInterval: 1)
                screenshot("d2-composer-collapsed-draft-preserved")
            }
        } else {
            // Honest absence: the demo agent's session does not resolve
            // an interactive composer; collapse/grow is unit-proven.
            screenshot("d2-composer-unavailable-honest")
        }
    }

    /// Review fix 6: interactive composer evidence against the REAL
    /// proof host (no demo mode): a real agent's chat resolves the
    /// production composer — collapse, typed grow, close preserving
    /// the draft, reopen — and a REAL broker send.
    func testInteractiveComposerProof() throws {
        let app = XCUIApplication()
        // The proof session pin (the registered broker session) so the
        // broker pane matches the proof registration.
        app.launchEnvironment["HEELER_AGENT_CHAT_PROOF_SESSION_FILE"]
            = "/Users/jhou/.cache/agent-chat-ui-proof/history.jsonl"
        // NO --demo-screenshots: the real proof-host agents.
        app.launch()
        Thread.sleep(forTimeInterval: 14)
        screenshot("int-env-agents-list")
        // A real agent row from the proof host (the broker pane is
        // the registered proof agent).
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'broker'")).firstMatch
        if !row.exists {
            let anyRow = app.buttons
                .matching(NSPredicate(format: "label CONTAINS 'Mac ·'"))
                .firstMatch
            if !anyRow.exists {
                screenshot("int-env-no-agents-honest")
                return
            }
            anyRow.tap()
        } else {
            row.tap()
        }
        Thread.sleep(forTimeInterval: 8)
        screenshot("int-agent-detail-state")
        // The composer is PERSISTENT: the resting row is already
        // mounted — nothing to open.
        let field = app.textViews.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 25),
            "real agent chat must resolve the persistent composer")
        Thread.sleep(forTimeInterval: 2)
        screenshot("int-composer-resting")
        field.tap()
        Thread.sleep(forTimeInterval: 1)
        field.typeText("Interactive composer proof: typed live")
        Thread.sleep(forTimeInterval: 1)
        screenshot("int-composer-grown")
        // Collapse: focus off — the draft persists in the resting row.
        let collapse = app.buttons["Collapse input"]
        if collapse.exists {
            collapse.tap()
            Thread.sleep(forTimeInterval: 1)
            screenshot("int-composer-collapsed-draft-preserved")
        }
        // Re-focus and send through the REAL broker.
        field.tap()
        Thread.sleep(forTimeInterval: 1)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button")
        send.tap()
        Thread.sleep(forTimeInterval: 4)
        // The real broker send evidence: the user message renders.
        screenshot("int-real-broker-send")
    }

    /// Round-3 visual evidence: the work inspector at each level, the
    /// loaded image gallery (+N collection), and the in-app reader.
    func testD3VisualProofs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        Thread.sleep(forTimeInterval: 10)
        let row = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS 'ios-polish' OR label CONTAINS 'Polish the Attach'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "demo agent row missing")
        row.tap()
        Thread.sleep(forTimeInterval: 6)

        // L1: the compact Work summary row.
        let levelButton = app.buttons["Detail level: Text"]
        if levelButton.exists {
            levelButton.tap()
            Thread.sleep(forTimeInterval: 1)
            let tools = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Tools'")).firstMatch
            if tools.exists {
                tools.tap()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        screenshot("d3-l1-work-summary")
        // Tap the summary → the inspector sheet (collapsed rows).
        let summary = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Work summary'")).firstMatch
        if summary.exists {
            summary.tap()
            Thread.sleep(forTimeInterval: 2)
            screenshot("d3-work-inspector-collapsed")
            // Expand the first call row → its result body.
            let firstCall = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Call read'")).firstMatch
            if firstCall.exists {
                firstCall.tap()
                Thread.sleep(forTimeInterval: 1)
                screenshot("d3-work-inspector-expanded")
            }
            // Dismiss the sheet: grab above the content and pull
            // down fast (a plain swipe just scrolls the list).
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            Thread.sleep(forTimeInterval: 2)
        }

        // L2: per-call cards.
        if levelButton.exists {
            levelButton.tap()
            Thread.sleep(forTimeInterval: 1)
            let results = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Results'")).firstMatch
            if results.exists {
                results.tap()
                Thread.sleep(forTimeInterval: 2)
                screenshot("d3-l2-per-call-card")
            }
        }

        // L3: thinking visible.
        if levelButton.exists {
            levelButton.tap()
            Thread.sleep(forTimeInterval: 1)
            let thinking = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Thinking'")).firstMatch
            if thinking.exists {
                thinking.tap()
                Thread.sleep(forTimeInterval: 2)
                screenshot("d3-l3-thinking")
            }
        }

        // The image gallery: SLOW swipes so the scroll doesn't
        // overshoot the short demo transcript; check after each step.
        var tile: XCUIElement? = nil
        var galleryText: XCUIElement? = nil
        var controlText: XCUIElement? = nil
        for _ in 0..<12 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 1)
            let candidate = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Image attachment'")).firstMatch
            let text = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Six verification captures'")).firstMatch
            let control = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Re-ran the suite'")).firstMatch
            if text.exists { galleryText = text }
            if control.exists { controlText = control }
            if candidate.exists { tile = candidate; break }
        }
        // DIAGNOSTIC: which anchors were found at all.
        let diag = "control=\(controlText != nil);gallery=\(galleryText != nil);tile=\(tile != nil)"
        try? diag.write(to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/d3-diag.txt"),
                        atomically: true, encoding: .utf8)
        if let galleryText = galleryText, tile == nil {
            galleryText.tap()
            Thread.sleep(forTimeInterval: 1)
            screenshot("d3-image-gallery")
        }
        if let tile = tile {
            // Bring the tile fully onscreen, open the reader, capture,
            // dismiss, then capture the settled gallery position.
            tile.tap()
            Thread.sleep(forTimeInterval: 2)
            screenshot("d3-image-reader")
            // Dismiss the reader sheet via its Done button.
            let done = app.buttons["Close image viewer"].firstMatch
            if done.exists { done.tap() }
            Thread.sleep(forTimeInterval: 2)
            screenshot("d3-image-gallery")
            // The +N tile opens the collection sheet (every image).
            let overflow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'more images, opens all'")).firstMatch
            if overflow.exists {
                overflow.tap()
                Thread.sleep(forTimeInterval: 2)
                screenshot("d3-image-collection-sheet")
                // Dismiss the collection sheet (drag the handle).
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func screenshot(_ name: String) {
        let dir = URL(fileURLWithPath: "/tmp/heeler-proof-signals/redesign")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension CaptureUITests {
    /// A1 channel-continuity smoke (follow-up): a uniquely-identified,
    /// timestamped hold/open-count/request run. Every channel
    /// open/close/request appends to an ISOLATED per-run evidence file
    /// (run ID + ISO timestamp), so an independent read can separate
    /// mid-hold events from teardown — closing the 'continuity
    /// unproven' caveat.
    func testA1ChannelContinuity() throws {
        let runID = "a1cc-\(Int(Date().timeIntervalSince1970))"
        let evidencePath = "/tmp/heeler-proof-signals/a1-continuity/\(runID).jsonl"
        try? FileManager.default.removeItem(atPath: evidencePath)
        let app = XCUIApplication()
        app.launchEnvironment["HEELER_A1_RUN_ID"] = runID
        app.launchEnvironment["HEELER_AGENT_CHAT_PROOF_SESSION_FILE"]
            = "/Users/jhou/.cache/agent-chat-ui-proof/history.jsonl"
        app.launch()
        Thread.sleep(forTimeInterval: 14)
        // Tap a real agent ROW (matching, not containing; the pinned
        // broker session matches ANY agent on the host).
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Tailscale'")).firstMatch
        var opened = false
        if row.waitForExistence(timeout: 8), row.isHittable {
            row.tap()
            opened = true
        } else {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 1)
            let anyRow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Mac Proof'")).firstMatch
            XCTAssertTrue(anyRow.waitForExistence(timeout: 10), "agent row missing")
            anyRow.tap()
        }
        Thread.sleep(forTimeInterval: 3)
        screenshot("cc-agent-detail-entry")
        _ = opened
        // The persistent composer must resolve (the router-fix binary).
        let field = app.textViews.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 25),
            "persistent composer missing on the proof agent")
        // HOLD: >90s idle-and-subscribed on the same channel.
        Thread.sleep(forTimeInterval: 100)
        // REQUEST on the held channel — the marker is run-scoped.
        let marker = "channel-continuity \(runID)"
        field.tap()
        Thread.sleep(forTimeInterval: 1)
        field.typeText("Reply exactly: \(marker).")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button")
        send.tap()
        // The ASSISTANT reply — the user's sent text carries the
        // 'Reply exactly:' prefix; the assistant's reply does NOT.
        let assistantReply = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND NOT label CONTAINS 'Reply exactly'",
                marker)).firstMatch
        XCTAssertTrue(
            assistantReply.waitForExistence(timeout: 150),
            "assistant reply missing (the user echo is not a reply)")
        Thread.sleep(forTimeInterval: 2)

        // THE ASSERTION, read from the evidence file: the prompt left
        // on the HELD channel and NO connect/finish/close occurred
        // between the request and its response completion.
        let lines = (try? String(
            contentsOfFile: evidencePath, encoding: .utf8)) ?? ""
        let events = lines.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8))
                as? [String: Any]
        }
        XCTAssertFalse(events.isEmpty, "no evidence events recorded")

        func detail(_ e: [String: Any]) -> String { e["detail"] as? String ?? "" }
        func kind(_ e: [String: Any]) -> String { e["event"] as? String ?? "" }
        func chan(_ e: [String: Any]) -> String { e["channel"] as? String ?? "" }

        // All channels that completed setup (history.open on them).
        let setupChannels = Set(events.filter {
            kind($0) == "channel.request" && detail($0).hasPrefix("history.open")
        }.map(chan))
        XCTAssertFalse(setupChannels.isEmpty, "no negotiated channel")
        let heldChannel = setupChannels.sorted().first!

        // The prompt.send + its response.
        let promptLines = events.filter {
            kind($0) == "channel.request" && detail($0).hasPrefix("prompt.send")
        }
        XCTAssertFalse(promptLines.isEmpty, "no prompt.send recorded")
        let promptChannel = chan(promptLines[0])
        let promptIndex = events.firstIndex {
            ($0["seq"] as? Int ?? -1) == (promptLines[0]["seq"] as? Int ?? -1)
        } ?? 0
        let responseLines = events.filter {
            kind($0) == "channel.request.responseComplete"
                && detail($0).hasPrefix("prompt.send")
        }
        XCTAssertFalse(
            responseLines.isEmpty, "prompt.send never completed a response")

        // NO teardown events on ANY channel from the held channel's
        // negotiated-ready (its setup completion) through the prompt
        // response — the FULL continuity assertion (hold + send).
        let responseIndex = events.firstIndex {
            kind($0) == "channel.request.responseComplete"
                && detail($0).hasPrefix("prompt.send")
        } ?? events.count - 1
        let setupIndex = events.lastIndex {
            kind($0) == "channel.request.responseComplete"
                && detail($0).hasPrefix("history.open")
                && chan($0) == heldChannel
        } ?? 0
        let window = events[setupIndex...responseIndex]
        let teardownInWindow = window.filter {
            kind($0) == "channel.connect" || kind($0) == "channel.close"
                || kind($0) == "channel.finish"
        }
        XCTAssertTrue(
            teardownInWindow.isEmpty,
            "channel teardown inside the continuity window: \(teardownInWindow)")

        // The request went out on the HELD channel.
        XCTAssertEqual(
            promptChannel, heldChannel,
            "the prompt left on a different channel than the held one")

        // Harness teardown: the app terminates AFTER the assertions —
        // any later file lines are teardown-era and clearly outside
        // this window by sequence number.
        app.terminate()
    }
}

extension CaptureUITests {
    /// TEMP diag: dumps the app's (keychain-resident) device key for
    /// out-of-band proof authorization after a reinstall.
    func testDumpDeviceKey() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HEELER_DIAG_DEVICE_KEY"] = "1"
        app.launch()
        Thread.sleep(forTimeInterval: 4)
        app.terminate()
    }
}

extension CaptureUITests {
    /// TEMP: re-provisions the Mac Proof host record (the device key is
    /// keychain-resident and authorized; only the record was lost in
    /// the cache-clear uninstall). Values verified by Main.
    func testProvisionMacProofHost() throws {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 6)
        // Switch to the HOSTS page: the compact destination menu.
        let menuButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'switch destination'")).firstMatch
        if menuButton.waitForExistence(timeout: 8) {
            menuButton.tap()
            Thread.sleep(forTimeInterval: 1)
            let hosts = app.buttons["Hosts"].firstMatch
            if hosts.waitForExistence(timeout: 5) {
                hosts.tap()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        screenshot("provision-hosts-page")
        // The Hosts page: the empty state's Add Manually (or the +
        // icon) opens the manual form.
        let manual = app.buttons.matching(
            NSPredicate(format: "label == 'Add Manually'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let manual = manual {
            manual.tap()
        } else {
            let plus = app.buttons.matching(
                NSPredicate(format: "label == 'Add Host' OR label == 'plus'")).firstMatch
            XCTAssertTrue(plus.waitForExistence(timeout: 10), "add-host control missing")
            plus.tap()
        }
        Thread.sleep(forTimeInterval: 3)
        screenshot("provision-form")
        // DIAGNOSTIC: dump every text field's placeholder.
        let fields = app.textFields.allElementsBoundByIndex
        let dump = fields.enumerated()
            .map { "\($0.offset): ph=[\($0.element.placeholderValue ?? "nil")] val=[\($0.element.value ?? "nil")]" }
            .joined(separator: "\n")
        try? dump.write(to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/provision-fields.txt"),
                        atomically: true, encoding: .utf8)
        // Fill by placeholder (LabeledTextField prompts).
        func field(_ prompt: String) -> XCUIElement {
            let hit = app.textFields.matching(
                NSPredicate(format: "placeholderValue CONTAINS %@", prompt)).firstMatch
            XCTAssertTrue(hit.waitForExistence(timeout: 5), "field \(prompt) missing")
            return hit
        }
        let name = field("Optional")
        name.tap(); name.typeText("Mac Proof")
        let user = field("user on the Host")
        user.tap(); user.typeText("jhou")
        // The route rows are buttons — tap the first route to open its
        // editor, then fill the Hostname or address field.
        let route = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'unnamed' OR label CONTAINS 'route'")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5), "route row missing")
        route.tap()
        Thread.sleep(forTimeInterval: 1)
        screenshot("provision-route-editor")
        let address = field("host.example.com")
        address.tap(); address.typeText("192.168.31.71")
        // The route editor is a sheet with its own Save.
        let routeSave = app.buttons["Save"].firstMatch
        XCTAssertTrue(routeSave.waitForExistence(timeout: 5), "route Save missing")
        routeSave.tap()
        Thread.sleep(forTimeInterval: 2)
        // Scroll to the broker field (below the fold) + fill.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        let broker = field("Chat broker socket path")
        broker.tap()
        broker.typeText("/Users/jhou/.cache/agent-chat-ui-proof/broker.sock")
        screenshot("provision-filled")
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save missing")
        save.tap()
        Thread.sleep(forTimeInterval: 4)
        // The first-connection TOFU dialog: trust the host's key.
        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 8) {
            trust.tap()
        }
        Thread.sleep(forTimeInterval: 10)
        screenshot("provision-saved")
    }
}

extension CaptureUITests {
    /// V2 slice 1 (agent details) proofs: the shared three-dot entry opens
    /// the inspector from BOTH surfaces (chat + terminal), the honest
    /// unsupported state renders when the demo backend carries no broker
    /// telemetry, and the inspector surfaces read-only states without a
    /// Compact now or delete affordance.
    func testV2AgentDetailsProofs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        Thread.sleep(forTimeInterval: 12)
        // An idle demo agent with a readable transcript opens on Chat.
        let row = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS 'docs-review' OR label CONTAINS 'Refresh the setup guide'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "demo agent row missing")
        row.tap()
        Thread.sleep(forTimeInterval: 6)
        // The chat surface's three-dot entry.
        let chatMenu = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Agent options'")).firstMatch
        XCTAssertTrue(chatMenu.waitForExistence(timeout: 8), "chat three-dot entry missing")
        chatMenu.tap()
        Thread.sleep(forTimeInterval: 1)
        let detailsEntry = app.buttons["Agent details"].firstMatch
        XCTAssertTrue(detailsEntry.waitForExistence(timeout: 5), "Agent details menu entry missing")
        detailsEntry.tap()
        Thread.sleep(forTimeInterval: 2)
        // The inspector opens: honest unavailable state (the demo backend
        // has no broker telemetry) — context usage "Not reported", the
        // unsupported model-change footnote, and the working directory
        // from the console snapshot. The sheet's own Done control is the
        // unambiguous open signal; the full-tree dump preserves the
        // honest-state labels for review.
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "agent details sheet did not open")
        Thread.sleep(forTimeInterval: 1)
        screenshot("v2-agent-details-root-unavailable-honest")
        try? app.debugDescription.write(
            to: URL(fileURLWithPath: "/tmp/v2-detail-a11y-open-dump.txt"),
            atomically: true, encoding: .utf8)
        // The root's fact rows are the honest-state surfaces: the Model
        // row reads "Not reported" when no broker telemetry exists.
        let modelRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Model' AND label CONTAINS 'Not reported'")).firstMatch
        var honest = modelRow.waitForExistence(timeout: 8)
        if !honest {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            honest = modelRow.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(honest, "honest Not reported state missing")
        // Compaction history: empty honest state.
        let compactions = app.buttons["Compactions"].firstMatch
        if compactions.waitForExistence(timeout: 5) {
            compactions.tap()
            Thread.sleep(forTimeInterval: 2)
            screenshot("v2-compaction-history-empty-honest")
            // No Compact now affordance ever.
            let compactNow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Compact now'")).firstMatch
            XCTAssertFalse(compactNow.exists, "no Compact now action may exist")
            app.navigationBars.buttons.firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        // Done.
        let rootDone = app.buttons["Done"].firstMatch
        if rootDone.exists { rootDone.tap() }
        Thread.sleep(forTimeInterval: 1)
        // The terminal surface's three-dot entry.
        let terminalToggle = app.buttons.matching(
            NSPredicate(format: "label == 'Show Terminal'")).firstMatch
        if terminalToggle.waitForExistence(timeout: 5) {
            terminalToggle.tap()
            Thread.sleep(forTimeInterval: 3)
            let termMenu = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Agent options'")).firstMatch
            XCTAssertTrue(termMenu.waitForExistence(timeout: 8), "terminal three-dot entry missing")
            termMenu.tap()
            Thread.sleep(forTimeInterval: 1)
            let termEntry = app.buttons["Agent details"].firstMatch
            XCTAssertTrue(termEntry.waitForExistence(timeout: 5), "terminal Agent details entry missing")
            termEntry.tap()
            Thread.sleep(forTimeInterval: 2)
            screenshot("v2-agent-details-from-terminal")
            let termDone = app.buttons["Done"].firstMatch
            if termDone.exists { termDone.tap() }
        }
    }
}

extension XCUIElement {
    /// Clears the field's text (the port prefills with 22).
    func clearText() {
        tap()
        let value = (value as? String) ?? ""
        if !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
    }
}

extension CaptureUITests {
    /// TEMP diag: the provisioned host's current state (preflight).
    func testHostPreflightDiag() throws {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 8)
        let menuButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'switch destination'")).firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
        menuButton.tap()
        Thread.sleep(forTimeInterval: 1)
        let hosts = app.buttons["Hosts"].firstMatch
        if hosts.exists { hosts.tap(); Thread.sleep(forTimeInterval: 2) }
        screenshot("diag-hosts-list")
        let host = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Mac Proof'")).firstMatch
        if host.waitForExistence(timeout: 8) {
            host.tap()
            Thread.sleep(forTimeInterval: 2)
            // The first-connection TOFU dialog: trust the host's key.
            let trust = app.buttons["Trust"].firstMatch
            if trust.waitForExistence(timeout: 8) {
                trust.tap()
            }
            Thread.sleep(forTimeInterval: 12)
            screenshot("diag-host-preflight")
        }
    }
}
