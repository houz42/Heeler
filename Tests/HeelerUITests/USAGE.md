# HeelerUITests — the persistent UI-proof harness

One XCUITest bundle every slice reuses. No more temp UITest targets:
add your proof test here, run the `HeelerUITests` scheme, done.

## Where things are

```
Tests/HeelerUITests/
  Support/   helpers (launch, typing, screenshots, trust alerts, timeouts)
  Smoke/     canonical smoke tests — copy their shape
  USAGE.md   this contract
```

## How to add a proof test

1. New file in `Tests/HeelerUITests/` (or `Smoke/` if it is a smoke).
   Copy an existing smoke's shape: `setUp` launches, `tearDown`
   terminates, `continueAfterFailure = false`.
2. Launch via the helpers — never raw `XCUIApplication().launch()`:

```swift
let app = UITestApp.launchDemo(.console)      // demo fixtures, deterministic
let app = UITestApp.launchDemo(.hostForm)    // host form (multipath host)
let app = UITestApp.launch()                  // plain app (empty state only)
```

Demo routes: `.console` `.hostForm` `.hostDetailProbing`
`.hostDetailPick` `.settings` — each maps to the `--demo-*` launch
args already in the app (Debug + simulator only). Demo mode is the ONLY
sanctioned fixture source: no real SSH, no real herdr, no host-dependent
state. CI must pass on a clean checkout with a booted sim.

3. Assert on the accessibility tree (`staticTexts`, `buttons`,
   `textFields` by label/placeholder), not pixel diffs. Keep each test
   to one user-visible behavior.

## The simulator protocol (serialized ownership — MANDATORY)

Same-bundle concurrent installs cross-contaminate (phantom-keyboard
failures, established). Therefore:

- **Announce take** on the hub before any install/launch/test on a
  shared sim: `hub send` "UITest: taking <sim-udid> for <purpose>".
- **Wait for the current holder's release broadcast** before installing.
- **Broadcast release** the moment your last test exits.

Shared sims: iPhone 17 `BA7D68CB-D0F1-491A-851A-E6230E790FA3`,
iPad Pro 13" `B3376366-C8F6-45BD-ACDC-FC37C7144944`. Do not reset
app data / keychain unless the holder before you cleared you to.

## Running

```sh
xcodebuild test \
  -project Heeler.xcodeproj -scheme HeelerUITests \
  -destination 'platform=iOS Simulator,id=BA7D68CB-D0F1-491A-851A-E6230E790FA3'
```

`HeelerUITests` is a **separate scheme** so the default `Heeler` scheme's
test action (`HeelerTests` only) stays fast for every worker. Your
proofs run when you (or the merge gate) invoke the dedicated scheme —
never as part of a routine `xcodebuild test -scheme Heeler`.

If you touched `project.yml`: `xcodegen generate` in your worktree
before building. Project regeneration is branch-local — regen in YOUR
worktree, never in a sibling's checkout.

## The typing bar (user rule)

Form-input work needs **typing proofs**: real keystrokes with
focus-retention assertions. A screenshot of a filled field proves
nothing. Use the helper:

```swift
field.typeTextWithFocusAssertion("10.0.0.5")   // taps, types, asserts focus + value
```

Keyboard-state queries: `app.isKeyboardPresented`,
`app.waitForKeyboard()`, `app.waitForKeyboardDismissal()`.

## The fresh-worktree 0-test flake

The FIRST `xcodebuild test` in a fresh DerivedData can report
`Executed 0 tests` — a known simulator quirk, not a green. **Rerun once
before trusting a green.** A 0-test run is never evidence.

## Trust alerts (TOFU)

Never assert directly on a first-connect alert — buttons re-home
across view states. Use:

```swift
app.confirmTrustAlert()           // waits, taps Trust, absorbs follow-ups
```

Returns `false` if no alert appears; only treat that as failure when your
flow requires one.

## Screenshots

`app.captureScreenshot("name")` attaches to the result bundle
(`.deleteOnSuccess` default — flip to `.keepAlways` when debugging).
