# Halo 3.0 — Reliability and Control

Halo 3.0 makes the review surface focus-safe, gives users a deliberate recovery path when the original destination changes, makes **Review When Needed** genuinely risk-aware, and adds direct control over the text that will be pasted. Halo remains opt-in, Mini remains the application default, and Respond and Custom Command Modes continue to use Mini.

## Delivery principles

- Continue on `codex/cursor-halo-prototype`; no feature flag or external API change.
- A click inside the visible rounded review surface must never reach the destination underneath it.
- Halo remains non-key and non-main during recording, delivery, review, and focus recovery. User-invoked manual editing is the sole temporary key-window exception; destination validation runs again before delivery.
- Never silently adopt a different destination or paste into a known-changed field.
- Explicit session overrides remain authoritative except that a known destination mismatch always blocks delivery.
- Risk routing uses deterministic, testable local signals and never sends transcript text to an additional service.
- Original selection and manual edits become immutable revisions and continue through the existing exactly-once delivery gate.
- Product counters are local, aggregate, resettable, and never contain transcript, prompt, context, application, or model text.

## Status board

| Story | Status | Depends on | Milestone deliverable |
| --- | --- | --- | --- |
| H3-00 | **Done** | — | Roadmap, backlog reconciliation, dependencies, and acceptance criteria |
| H3-01 | **Done** | H3-00 | Visible-surface click shield with transparent-margin pass-through |
| H3-02 | **Done** | H3-01 | Explicit focus-recovery flow that hides/collapses Halo for manual refocus |
| H3-03 | **Done** | H3-01 | Destination identity hardening and recoverable validation states |
| H3-04 | **Done** | H3-00 | Pure local Halo delivery-risk evaluator |
| H3-05 | **Done** | H3-04 | Risk-aware Review When Needed integration and Mode guidance |
| H3-06 | **Done** | H3-00 | Use Original as an immutable, pasteable revision |
| H3-07 | **Done** | H3-06 | Manual Final editing as an immutable revision |
| H3-08 | **Done** | H3-00 | Privacy-preserving local Halo outcome counters |
| H3-09 | **Done** | H3-00 | Development-only state gallery over contrasting backgrounds |
| H3-10 | **Automated complete; manual pending** | H3-02, H3-03, H3-05, H3-07, H3-08, H3-09 | Localization, compatibility audit, automated verification, and manual handoff |

## Story acceptance criteria

### H3-00 — Roadmap and backlog

- [x] `docs/HALO_3_ROADMAP.md` records status, dependencies, acceptance criteria, and deferred work.
- [x] `BACKLOG.md` identifies the earlier discovery item as superseded by Halo Review 2.0 and Halo 3.0.
- [x] The completed Halo Review 2.0 roadmap remains unchanged as historical evidence.

### H3-01 — Review-surface focus shield

- [x] The entire visible rounded review surface absorbs mouse clicks.
- [x] The transparent visual-effect margin remains click-through.
- [x] Buttons, lenses, text selection, navigation, and refinements remain mouse-operable.
- [x] Listening, transcribing, enhancing, confirmation, and non-Halo panels retain existing behavior.
- [x] Halo stays non-key/non-main except while the user explicitly edits the Final text; leaving the editor resigns key status and delivery revalidates the captured destination.

### H3-02 — Focus recovery

- [x] A destination mismatch offers an explicit **Refocus** action alongside Copy and Cancel.
- [x] Refocus temporarily collapses Halo so the original field is reachable.
- [x] The user manually restores focus and explicitly resumes; Halo never clicks or selects a field for them.
- [x] Successful revalidation restores Apply without consuming or changing the pending payload.
- [x] Failed recovery keeps the review pending and Copy available.

### H3-03 — Destination identity hardening

- [x] Validation distinguishes process changes, stable-element changes, and unavailable/unstable AX identity.
- [x] Same-field recovery works in native controls and compatible browser/Electron controls without permitting a known different field.
- [x] Destination snapshots and diagnostics remain transient and sanitized.
- [x] Direct and reviewed delivery use the same validation policy.

### H3-04 — Risk evaluator

- [x] The pure `HaloDeliveryRiskEvaluator` produces deterministic assessments and sanitized review reasons.
- [x] Signals cover auto-send, enhancement fallback, empty output, material length change, and material grouped-word change, including unspaced CJK text.
- [x] Identical and lightly cleaned results remain low-risk.
- [x] No network request, provider reroute, persisted transcript, or model confidence claim is introduced.

### H3-05 — Review When Needed

- [x] Successful low-risk results paste directly.
- [x] Risky results open review with a concise, sanitized reason.
- [x] Always Review, Paste Immediately, explicit session overrides, and known destination mismatch preserve their contracts.
- [x] Mode UI explains the effective Review When Needed behavior.

### H3-06 — Use Original

- [x] Original can be selected as the exact prepared paste result with one explicit action.
- [x] Selection creates or reuses an immutable revision without mutating the initial enhancement.
- [x] Apply, Copy, History finalization, trailing-space handling, licensing, and auto-send use that revision's payload.

### H3-07 — Manual Final editing

- [x] Editing starts from the selected revision and never mutates an existing revision.
- [x] Saving a nonempty changed value creates and selects one manual revision with a regenerated payload.
- [x] Empty/unchanged edits create no revision; cancellation restores the prior selection.
- [x] Revision limits, inactivity, refinement exclusion, multiline editing, shortcuts, VoiceOver, and exactly-once delivery remain correct.

### H3-08 — Local outcome counters

- [x] Aggregate counters cover direct paste, review shown, Apply, Cancel, Copy, expiry, mismatch, retry, refinement success/failure, Use Original, and manual edit.
- [x] Counters contain no transcript, prompt, context, application, provider, model, or destination identifiers.
- [x] Storage is local, bounded, resettable, and failure cannot block recording or delivery.

### H3-09 — State gallery

- [x] A development-only harness renders representative Halo phases and review states, including focus recovery and manual editing.
- [x] States can be inspected over light, dark, and high-contrast backgrounds.
- [x] The harness is excluded from production behavior and persistent settings.

### H3-10 — Hardening and acceptance

- [x] Focused Halo, routing, reducer, delivery, History, and counter tests pass.
- [x] The complete non-UI test suite and a Debug build pass with temporary Derived Data.
- [x] Manual acceptance covers native, browser, Electron, fullscreen, multi-display, Accessibility-denied, Reduce Motion, VoiceOver, OAuth/API enhancement, every delivery policy, focus loss/recovery, and History.

## Verification evidence

- 2026-07-17: focused Halo safety, delivery-risk, shortcut, review/refinement, interaction, and outcome-metric tests passed serially.
- 2026-07-17: the complete `VoiceInkTests` non-UI target passed with parallel testing disabled.
- 2026-07-17: the VoiceInk Debug scheme built successfully using temporary Derived Data and the existing resolved package cache.
- 2026-07-20: product-owner acceptance was confirmed after live experimentation with the Halo workflow, closing the manual handoff gate.

## Delivery order

1. H3-00 materializes the roadmap.
2. H3-01 fixes the reported focus-loss defect.
3. H3-02 and H3-03 complete focus recovery and validation hardening.
4. H3-04 and H3-05 make routing genuinely risk-aware.
5. H3-06 and H3-07 add result control.
6. H3-08 and H3-09 add evidence and visual regression support.
7. H3-10 closes with compatibility and verification.

H3-04, H3-06, H3-08, and H3-09 may proceed in parallel after H3-00. H3-02 and H3-03 may proceed in parallel after H3-01 but must share one final validation contract.

## Deferred from Halo 3.0

- True post-paste Undo across native, browser, Electron, and contenteditable destinations.
- Automatic activation or clicking of a destination field.
- Free-form voice refinement was delivered in Halo 4.0. Parallel model variants, continuous caret tracking, and Time-Shift Capture remain candidates for Halo 5.0 planning.
