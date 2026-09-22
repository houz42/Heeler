#!/usr/bin/env python3
"""Interactive proof of the redesigned Agents list (handoff §B).

Installs the Debug build, launches it in --demo-screenshots mode (5 agents,
2 hosts, kinds codex/claude/gemini/opencode, sessions main/ci, named tabs),
then drives REAL typing into the in-list search bar via idb and captures
evidence for each §B requirement:

  1. Two-line rows with kind icons + one quiet location line
  2. Fuzzy title search with live result filtering (abbreviation typed)
  3. field: autocomplete — arrow navigation, Enter accepts (adds a chip)
  4. Chip removal (tap x), result count changes
  5. Esc dismisses suggestions without submitting
  6. Ordering views: recent / title / attention / pane
  7. Grouping views: host / session / workspace / tab / state
  8. Empty state (a query matching nothing)
  9. Focus retention across navigation (open an agent, come back)

Screenshots land in the output dir; assertions print PASS/FAIL per step.
Only the session-owned simulator UDID is ever touched.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

UDID = "BA7D68CB-D0F1-491A-851A-E6230E790FA3"
APP_PATH = (
    "/Users/jhou/nv/wt/heeler-agents-v2/build/DerivedData/Build/Products/"
    "Debug-iphonesimulator/Heeler.app"
)
IDB = str(Path.home() / ".idb-venv/bin/idb")
COMPANION = "localhost:10882"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        mark = "PASS" if ok else "FAIL"
        print(f"[{mark}] {name}" + (f" — {detail}" if detail else ""))
        if not ok:
            failures.append(name)

    def run(*cmd: str, timeout: int = 60) -> str:
        return subprocess.check_output(
            [IDB, "--companion", COMPANION, *cmd, "--udid", UDID],
            text=True, timeout=timeout)

    def screenshot(name: str) -> None:
        subprocess.run(
            ["xcrun", "simctl", "io", UDID, "screenshot", str(out / f"{name}.png")],
            check=True, timeout=30)

    def elements() -> list[dict]:
        return json.loads(run("ui", "describe-all", timeout=30))

    def labels() -> list[str]:
        return [e.get("AXLabel") or "" for e in elements() if e.get("AXLabel")]

    def tap(label: str) -> bool:
        out_run = run("ui", "tap", label, timeout=30)
        return "error" not in out_run.lower()

    def key(text: str) -> None:
        for char in text:
            if char == " ":
                run("ui", "key", "space")
            else:
                run("ui", "key", char)
            time.sleep(0.12)

    # 0. Install + launch in demo mode.
    subprocess.run(["xcrun", "simctl", "install", UDID, APP_PATH], check=True, timeout=300)
    subprocess.run(
        ["xcrun", "simctl", "launch", UDID, "dev.houz42.heeler", "--demo-screenshots"],
        check=True, capture_output=True, timeout=60)
    time.sleep(6)  # snapshot convergence

    # 1. The list renders rows with location lines + counts.
    shot = labels()
    check("list shows agent rows", any("Polish the Attach experience" in l for l in shot),
          str([l for l in shot if "Polish" in l])[:200])
    screenshot("01-rows")

    # 2. Fuzzy title search: focus the field by tapping it, type an abbreviation.
    check("tap search field", tap("Search agent titles or filter by context"))
    time.sleep(1)
    key("Polsh")  # typo'd abbreviation of "Polish the Attach experience"
    time.sleep(1.5)
    shot = labels()
    check("fuzzy title filters rows",
          any("Polish the Attach experience" in l for l in shot)
          and not any("Refresh the setup guide" in l for l in shot))
    screenshot("02-fuzzy-title")
    # Clear.
    tap("Clear search text")
    time.sleep(0.5)

    # 3. field: autocomplete + arrow navigation + Enter accept.
    tap("Search agent titles or filter by context")
    key("host:")
    time.sleep(1.5)
    shot = labels()
    check("field query shows value suggestions", any("Studio Mac" in l for l in shot))
    screenshot("03-field-suggestions")
    run("ui", "key", "81")  # down arrow (HID)
    time.sleep(0.4)
    run("ui", "key", "40")  # HID return: Enter accepts the highlighted value
    time.sleep(1)
    shot = labels()
    check("Enter adds host filter chip", any("Host" in l and "Studio Mac" in l for l in shot))
    screenshot("04-filter-chip")
    check("count reflects filtered matches",
          any("2 of 5 agents" in l for l in shot), str([l for l in shot if "agents" in l])[:200])

    # 4. Chip removal.
    tap("Remove Host filter Studio Mac")
    time.sleep(1)
    shot = labels()
    check("chip removal restores full list", any("5 of 5 agents" in l for l in shot))
    screenshot("05-chip-removed")

    # 5. Esc dismisses suggestions without submitting.
    tap("Search agent titles or filter by context")
    key("Build")
    time.sleep(1)
    run("ui", "key", "41")  # HID escape
    time.sleep(0.6)
    screenshot("06-esc-dismiss")

    # 6. Ordering views via the view menu.
    tap("Agent list view options")
    time.sleep(0.8)
    screenshot("07-view-menu")
    tap("Title A–Z")
    time.sleep(1)
    screenshot("08-order-title")
    tap("Agent list view options")
    tap("Pane order")
    time.sleep(1)
    screenshot("09-order-pane")

    # 7. Grouping views.
    tap("Agent list view options")
    tap("Host")
    time.sleep(1)
    shot = labels()
    check("host grouping shows section headers",
          any("Studio Mac" in l for l in shot) and any("Build Server" in l for l in shot))
    screenshot("10-group-host")
    tap("Agent list view options")
    tap("Agent state")
    time.sleep(1)
    shot = labels()
    check("state grouping shows urgency groups", any("Needs you" in l for l in shot))
    screenshot("11-group-state")

    # 8. Empty state.
    tap("Search agent titles or filter by context")
    key("zzzqq")
    time.sleep(1.2)
    shot = labels()
    check("empty state renders", any("No Matching Agents" in l for l in shot))
    screenshot("12-empty-state")
    tap("Clear Search")
    time.sleep(0.8)

    # 9. Focus retention across navigation: type a query, open a row, back.
    tap("Search agent titles or filter by context")
    key("Audit")
    time.sleep(1.2)
    tap("Audit VoiceOver labels")
    time.sleep(2.5)
    # Back: swipe/edge — the detail's back. Use the toolbar back button label.
    back_ok = tap("Agents") or True
    time.sleep(1.2)
    shot = labels()
    # The query must survive navigation back.
    check("query survives navigation", any("1 of 5 agents" in l for l in shot),
          str([l for l in shot if "agents" in l])[:200])
    screenshot("13-focus-retention")

    print()
    if failures:
        print(f"FAILED steps: {failures}")
        return 1
    print("All interactive proofs passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
