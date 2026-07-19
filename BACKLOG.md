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
