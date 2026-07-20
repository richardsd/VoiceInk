# Product Backlog

## Cursor Halo review workflow

**Status:** Superseded by implementation and follow-up roadmap

**Delivered:** `docs/HALO_REVIEW_2_ROADMAP.md`

**Completed reliability work:** `docs/HALO_3_ROADMAP.md`

**Current work:** `docs/HALO_4_ROADMAP.md`

Halo Review 2.0 delivered per-Mode Always Review, Review When Needed, and Paste Immediately policies; session Quick Apply/Review overrides; destination-safe direct delivery; Final/Changes/Original lenses; revision history; and five provider-stable refinements.

Halo 3.0 owns the remaining reliability and control work:

- Prevent clicks inside the visible Halo review surface from changing the destination underneath it.
- Provide an explicit manual focus-recovery flow.
- Make Review When Needed consider deterministic local risk signals rather than enhancement failure alone.
- Make Original a pasteable result and support manual Final revisions.
- Collect privacy-preserving local outcome counters and add a development-only visual state gallery.

Halo 4.0 builds on that foundation with ephemeral, voice-directed refinement inside the existing Halo review. It reuses the user's recording shortcuts and original transcription/enhancement route, adds a microphone fallback and futuristic listening states, and creates immutable parent-linked revisions without persisting the spoken instruction.

### Still deferred

- True post-paste Undo remains deferred until target-safe behavior can be demonstrated across native, browser, Electron, and contenteditable inputs.
- Automatic activation or clicking of another application or field remains out of scope.
- Displaying, editing, or persisting recognized voice-refinement instructions remains deferred until the ephemeral workflow is validated.

## Confirmed bugs

### BUG-HALO-001 — Halo can crash before review appears after enhancement

**Status:** Fixed

**Impact:** The app can intermittently crash after enhancement completes, before the Halo review panel is displayed.

**Root cause:** `DashboardStatsSnapshotStore.saveSummary(_:)` removes a `UserDefaults` value on its utility queue. The resulting `UserDefaults.didChangeNotification` is delivered on that background queue, where `HaloWindowManager` currently responds by resizing its AppKit panel. AppKit traps because window operations must run on the main thread.

**Evidence:** Crash reports from July 17 and July 20, 2026 share the same `DashboardStatsSnapshotStore.saveSummary(_:)` → `HaloWindowManager.resizeVisiblePanel(animated:)` → `HaloRecorderPanel.update(frame:animated:)` stack and the message `Must only be used from the main thread`.

**Fix:** `HaloWindowManager` now receives `UserDefaults.didChangeNotification` on the main queue before resizing its AppKit panel, with regression coverage for a notification posted from a background queue.
