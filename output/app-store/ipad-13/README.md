# Heeler iPad App Store mockups

Five landscape exports for the 13-inch iPad screenshot slot. Each export is an
opaque RGB PNG at 2752 × 2064 pixels. The numbered filenames define the proposed
upload order, with the floating-window presentation first.

## Contents

| Order | Export | Focus |
| --- | --- | --- |
| 1 | `exports/01-fits-your-workspace.png` | A real floating Heeler window on iPad |
| 2 | `exports/02-every-agent-one-console.png` | Agent sidebar and selected Codex conversation |
| 3 | `exports/03-type-directly-stay-in-flow.png` | Direct Input and the full Terminal keyboard |
| 4 | `exports/04-skills-within-reach.png` | Composer Skills dock |
| 5 | `exports/05-control-without-leaving-the-flow.png` | Composer and Agent control keys |

`contact-sheet.jpg` provides an overview; `index.html` links the five full-size
exports. Neither the contact sheet nor the source captures belong in the upload
set. The locally generated `../ipad-13-app-store.zip` contains only the five
exports and is excluded from Git, together with the earlier HTML draft.

## Source preservation

- The sources are real captures from the iPad Pro 13-inch (M5) simulator on
  iOS 26.5, UDID `B33CE5C2-3BB2-477E-A53E-E8034F85031B`.
- All coding content is the user-selected Codex conversation about the current
  project architecture on Local-a.
- Sources 1, 2, 3, and 5 come from the earlier 2026-09-13 simulator capture set;
  their unchanged originals are included in `sources/` for regeneration.
- Source 4 was captured during this mockup task using `xcrun simctl io` on the
  same simulator. Only local mode and dock controls were used. No prompt, draft
  text, terminal key, or Agent control key was submitted.
- The temporary 9:41 status bar override was cleared after the capture. The
  keyboard was dismissed and the selected conversation remains open.
- Source captures are copied unchanged. The renderer scales each 4:3 capture
  uniformly to 2112 × 1584, with a small rounded corner mask. It does not redraw,
  rearrange, stretch, or replace any application content.
- The generated background is reused from `../0.1.7/assets/background.png`.
  Headlines, subheads, frame, and shadow are deterministic compositions adapted
  from the existing iPhone renderer and the approved iPad HTML preview.
- Source and export SHA-256 values, copy, geometry, and format are recorded in
  `manifest.json`.

The English marketing copy follows the existing App Store set. The selected
conversation remains in Chinese, as requested. Additional localized variants
have not been produced.

## Scope and verification

The first image uses the previously captured floating window in place of the
proposed Shell image: opening a Shell can create a remote terminal, which would
exceed the existing read-only Herdr constraint. This image demonstrates windowed
presentation; it does not establish minimum-width behavior.

All five rendered PNGs and the contact sheet were visually inspected. The
renderer checks source dimensions, equal scale on both axes, headline and
subhead safe areas, and output dimensions/color mode. An independent `sips`
check confirmed 2752 × 2064 and `hasAlpha: no` for every export. No App Store
Connect upload or product-page preview was performed.

## Regenerate

From the repository root, with Pillow installed:

```sh
python3 output/app-store/ipad-13/compose_mockups.py
sips -g pixelWidth -g pixelHeight -g hasAlpha output/app-store/ipad-13/exports/*.png
ditto -c -k --norsrc --keepParent output/app-store/ipad-13/exports output/app-store/ipad-13-app-store.zip
```

The renderer uses the system SF fonts on macOS. No application build or test is
needed to regenerate these marketing assets.
