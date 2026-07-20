# Product Backlog

## Cursor Halo review workflow

**Status:** Halo Review 2.0, Halo 3.0, and Halo 4.0 delivered; Halo 5.0 planning is next

**Delivered:** `docs/HALO_REVIEW_2_ROADMAP.md`

**Completed reliability work:** `docs/HALO_3_ROADMAP.md`

**Completed voice-refinement work:** `docs/HALO_4_ROADMAP.md`

Halo Review 2.0 delivered per-Mode Always Review, Review When Needed, and Paste Immediately policies; session Quick Apply/Review overrides; destination-safe direct delivery; Final/Changes/Original lenses; revision history; and five provider-stable refinements.

Halo 3.0 delivered the reliability and control work:

- Prevent clicks inside the visible Halo review surface from changing the destination underneath it.
- Provide an explicit manual focus-recovery flow.
- Make Review When Needed consider deterministic local risk signals rather than enhancement failure alone.
- Make Original a pasteable result and support manual Final revisions.
- Collect privacy-preserving local outcome counters and add a development-only visual state gallery.

Halo 4.0 built on that foundation with ephemeral, voice-directed refinement inside the existing Halo review. It reuses the user's recording shortcuts and original transcription/enhancement route, adds a microphone fallback and futuristic listening states, and creates immutable parent-linked revisions without persisting the spoken instruction.

### Halo 5.0 planning candidates

- Displaying, editing, confirming, or persisting recognized voice-refinement instructions.
- Free-form typed refinement through the same immutable revision pipeline.
- Voice commands for Apply, Copy, Cancel, and lens or revision navigation.
- Continuous caret and destination tracking.
- True post-paste Undo with target-safe behavior across native, browser, Electron, and contenteditable inputs.
- Parallel refinement variants with explicit latency, cost, and provider-limit controls.
- Time-Shift Capture with an explicit privacy and resource-management contract.
- Safe destination activation or guided focus recovery without silently pasting into a different field.

## Confirmed bugs

### BUG-HALO-001 — Halo can crash before review appears after enhancement

**Status:** Fixed

**Impact:** The app can intermittently crash after enhancement completes, before the Halo review panel is displayed.

**Root cause:** `DashboardStatsSnapshotStore.saveSummary(_:)` removes a `UserDefaults` value on its utility queue. The resulting `UserDefaults.didChangeNotification` is delivered on that background queue, where `HaloWindowManager` currently responds by resizing its AppKit panel. AppKit traps because window operations must run on the main thread.

**Evidence:** Crash reports from July 17 and July 20, 2026 share the same `DashboardStatsSnapshotStore.saveSummary(_:)` → `HaloWindowManager.resizeVisiblePanel(animated:)` → `HaloRecorderPanel.update(frame:animated:)` stack and the message `Must only be used from the main thread`.

**Fix:** `HaloWindowManager` now receives `UserDefaults.didChangeNotification` on the main queue before resizing its AppKit panel, with regression coverage for a notification posted from a background queue.
