# Halo 5.0 — User-Led Intelligence, Presence, and Recall

Halo 5.0 makes Halo configurable as a product surface rather than a fixed recorder style. Users decide which refinement, focus, comparison, and memory-only capture capabilities are available, while destination validation, exactly-once delivery, provider/authentication freezing, and Time-Shift privacy guarantees remain non-disableable.

Halo stays opt-in for Paste Modes. Mini remains the application default, Respond and Custom Command continue to use Mini, and the existing per-Mode Halo Result policy remains the only Mode-level Halo setting. No developer feature flag or external API is introduced.

## Product defaults

| Capability | Default | User control |
| --- | --- | --- |
| Spoken refinement | On | Global Halo setting |
| Typed refinement | On | Global Halo setting |
| Exact `Halo …` review commands | On | Global Halo setting |
| Another Take | On | Global Halo setting |
| Guided return to the original app | On | Global Halo setting |
| Continuous caret following | Off | Stable Anchor / Follow Original Caret |
| Precise & Natural comparison | Off | Global Halo setting with two-request disclosure |
| Time-Shift Capture | Off | Global Halo setting; arming remains session-only |

Spoken refinements always require confirmation. Apply and Cancel voice commands require a visible one-step confirmation. Time-Shift is fixed at fifteen seconds, one-shot, memory-only, visibly armed, and always opens review.

## Status board

| Story | Status | Depends on | Milestone deliverable |
| --- | --- | --- | --- |
| H5-00 | **Done** | — | Roadmap, dependency board, baseline reconciliation, and acceptance contract |
| H5-01 | **Done** | H5-00 | Capability store, defaults, backup v3, Settings tabs, and guided Halo overview |
| H5-02 | **Done** | H5-01 | Unified instruction draft, reducer, privacy lifecycle, and free-form prompt boundary |
| H5-03 | **Done** | H5-02 | Voice confirmation/correction, typed refinement, and Settings controls |
| H5-04 | **Done** | H5-03 | Exact local `Halo …` commands and consequential-command confirmation |
| H5-05 | **Done** | H5-01 | Guided application return with manual recovery fallback |
| H5-06 | **Done** | H5-05 | Identity-safe continuous caret tracking and position setting |
| H5-07 | **Done** | H5-02 | Another Take through the frozen route and immutable revision pipeline |
| H5-08 | **Done** | H5-01 | PCM snapshot, secure rolling buffer, CoreAudio memory sink, and WAV encoder |
| H5-09 | **Done** | H5-08 | Audio leases, Time-Shift lifecycle, memory clearing, and aggregate metrics |
| H5-10 | **Planned** | H5-09 | In-memory transcription boundary, provider adapters, and capability checks |
| H5-11 | **Planned** | H5-10 | Forced-review Time-Shift pipeline, menu controls, shortcuts, and armed pulse |
| H5-12 | **Planned** | H5-07 | Concurrent Precise/Natural variant engine and stale-result handling |
| H5-13 | **Planned** | H5-12 | Variant Deck UI, winner materialization, and opt-in cost disclosure |
| H5-14 | **Planned** | H5-04, H5-06, H5-11, H5-13 | Localization, accessibility, compatibility audit, full verification, and acceptance |

## Story acceptance criteria

### H5-00 — Roadmap and clean baseline

- [x] Halo 3.0 and Halo 4.0 acceptance are closed in their roadmap documents.
- [x] The no-speech/edge-case implementation is already isolated in `881a3acc`.
- [x] `docs/HALO_5_ROADMAP.md` and `BACKLOG.md` identify Halo 5.0 as current work.
- [x] The status-board contract requires every implementation story to record its focused commit and verification evidence here.

### H5-01 — User-controlled capabilities

- [x] Settings contains General and Halo tabs; Halo remains discoverable when Mini or Notch is selected.
- [x] The guided Halo page exposes the approved global controls, defaults, status, `Use Halo`, and `Manage Modes` actions.
- [x] A typed, injectable capability store publishes runtime snapshots and capability-change reconciliation notifications.
- [x] Backup schema v3 exports optional Halo preferences and Time-Shift shortcuts while v1/v2 imports retain recommended defaults.
- [x] Armed state, audio, drafts, recovery state, variants, and session overrides are never persisted or backed up.

### H5-02 — Unified instruction foundation

- [x] Voice and typed instructions share an ephemeral draft, reducer, bounds, escaping, and complete-replacement prompt contract.
- [x] The draft freezes its base revision and rejects stale capture, edit, submission, and refinement completions.
- [x] Instruction text never enters revisions, History, logs, diagnostics, defaults, backups, or aggregate metrics.
- [x] Provider, authentication, model, Mode prompt, vocabulary, and frozen context never reroute.

### H5-03 — Confirmable voice and typed refinement

- [x] Final voice recognition shows `I heard: …` with Refine, Edit, and Cancel before any model call.
- [x] `Type change` opens an accessible editor; Command-Return submits and Escape exits text entry first.
- [x] Empty, excessive, unchanged, failed, cancelled, and expired instructions preserve the selected review revision.
- [x] Disabling either capability cancels only its active operation and keeps review usable.

### H5-04 — Exact local voice commands

- [x] Final recognized exact commands support Apply, Copy, Cancel, lens selection, and revision navigation without a model call.
- [x] Partial or near-match speech never executes; unmatched speech becomes a draft only when spoken refinement is enabled.
- [x] Apply and Cancel require visible confirmation and retain destination/exactly-once safety.
- [x] Disabling commands removes command execution without disabling spoken refinement.

### H5-05 — Guided destination return

- [x] A user-triggered action verifies PID and bundle identity before activating the original application.
- [x] Stable element identity is revalidated; uncertain fields require the user to click the field and Continue.
- [x] Recovery never pastes, auto-sends, or guesses a destination. Apply remains separate.
- [x] Disabling guided recovery preserves manual refocus, Continue, Copy, and Cancel.

### H5-06 — Continuous caret presence

- [x] Expected paste identity remains immutable while the last-safe visual anchor may update.
- [x] AX notifications and a low-rate watchdog coalesce updates, allow one lookup in flight, and ignore jitter/quality downgrades.
- [x] Tracking accepts only the original validated field, freezes on mismatch, and pauses during text entry and delivery.
- [x] Stable Anchor remains the default and final Apply validation remains authoritative.

### H5-07 — Another Take

- [x] Another Take performs one cancellable request through the frozen route from the selected revision.
- [x] Success appends one parent-linked revision and opens Changes; empty, unchanged, failed, or stale output creates none.
- [x] The six-revision cap, exact payload preparation, timeout lifecycle, and destination safety remain intact.

### H5-08 — Memory-only audio foundation

- [x] A thread-safe, fixed-capacity fifteen-second PCM ring buffer supports wraparound, snapshotting, duration, and explicit zeroing.
- [x] CoreAudio can feed memory without opening a file, muting the system, pausing media, or playing recorder sounds.
- [x] PCM snapshots can produce scoped floats or an in-memory WAV without a filesystem URL.

### H5-09 — Time-Shift lifecycle and ownership

- [x] Time-Shift implements off, arming, armed, capturing/processing, and off with stale-operation rejection.
- [x] A lease coordinator prevents overlapping Time-Shift, normal recording, and Halo instruction capture.
- [x] Disable, capture, cancel, error, normal recording, device change, permission loss, lock, sleep, and termination clear memory and require explicit re-arming.
- [x] Metrics contain only aggregate action, duration, and sanitized outcome categories.

### H5-10 — In-memory transcription

- [ ] File and in-memory audio share an internal transcription-source boundary.
- [ ] Supported local/cloud adapters consume memory directly; capability checks reject unsupported models visibly.
- [ ] Time-Shift never falls back to a file, provider, connection, authentication method, or model.
- [ ] No network request, destination/context lookup, or History creation occurs while merely armed.

### H5-11 — Time-Shift product workflow

- [ ] Settings, menu bar, and stored shortcuts provide unambiguous Arm/Disarm and Capture actions.
- [ ] A cross-Space, non-key, click-through compact pulse and menu state remain visible whenever armed.
- [ ] Capture snapshots the current destination/Mode/context, auto-disarms, transcribes once, and always opens Halo review.
- [ ] History has sample-derived duration and no audio URL; missing destinations allow Copy but block Apply.

### H5-12 — Precise/Natural engine

- [ ] Compare starts at most two cancellable requests through the same frozen route with fact-preserving Precise and Natural profiles.
- [ ] Candidates remain provisional, stale results are ignored, and partial or total failure preserves the current revision.
- [ ] Comparison is unavailable without one remaining revision slot.

### H5-13 — Variant Deck

- [ ] The review displays an accessible A/B segmented deck rather than a side-by-side layout.
- [ ] Only an explicitly selected winner becomes a revision; the unselected candidate is cleared from memory.
- [ ] Settings and the review disclose that comparison uses two model requests.

### H5-14 — Hardening and acceptance

- [ ] Capability toggles, backup import, review expiry, reset, style changes, and termination cancel/clear only the appropriate transient state.
- [ ] Mini, Notch, Respond, Custom Command, delivery policies, Quick Apply, OAuth/API routing, History, clipboard restoration, and auto-send retain existing behavior.
- [ ] VoiceOver, Reduce Motion, Accessibility-denied, event-tap failure, multiple-display, and lifecycle behavior are verified.
- [ ] Focused tests, the complete non-UI suite, and a Debug build pass using temporary Derived Data.
- [ ] Manual acceptance covers native, browser, Electron, code-editor, fullscreen, device, privacy, and provider matrices.

## Delivery order and commits

Stories use focused `H5-XX …` commits in dependency order. H5-05, H5-07, and H5-08 may proceed after H5-01 while H5-02 is in flight; H5-12 begins only after the sequential Another Take contract is proven. Each completed story changes its board status to **Done**, records the commit SHA, and appends automated or manual evidence below.

## Verification record

- 2026-07-20: `881a3acc` isolated the no-speech and Halo review edge-case baseline.
- 2026-07-20: `9ceb8db7` closed Halo 3.0 and Halo 4.0 documentation after product-owner acceptance.
- 2026-07-20: `f6e820a9` materialized H5-00 and established this status board.
- 2026-07-20: `ed573cb6` completed H5-01; focused capability/default/backup tests passed (6 tests), and the Debug build succeeded using `/tmp/VoiceInk-H5-01`.
- 2026-07-21: `64b23a13` completed H5-02 with the unified memory-only instruction draft, reducer, bounds, prompt escaping, and frozen-route contract.
- 2026-07-21: `d26cdb69` completed H5-03; focused instruction, reducer, refinement-service, keyboard, and presentation suites passed serially with code signing disabled in `/tmp/VoiceInk-H5-refine-final`; the same run compiled the full application and test targets.
- 2026-07-21: `66559c73` completed H5-04; exact-command parser, review engine, confirmation UI, presentation, and keyboard suites passed serially in `/tmp/VoiceInk-H5-refine-final`; exact commands use no model call and near matches remain inert.
- 2026-07-21: `71ab51c8` completed H5-05; recovery, destination-matcher, review-engine, and compact-layout suites passed serially in `/tmp/VoiceInk-H5-refine-final`; recovery validates PID, bundle, and field identity while keeping paste as a separate action.
- 2026-07-21: `738cc2bf` completed H5-06; caret-tracker, capability, and layout suites passed serially in `/tmp/VoiceInk-H5-refine-final`; tests cover AX notifications, watchdog fallback, focus freezing, jitter, quality, operation pauses, and non-cooperative lookup recovery.
- 2026-07-21: `04398bd1` completed H5-07; refinement-service, reducer, engine, and presentation suites passed serially in `/tmp/VoiceInk-H5-refine-final`; Another Take uses the frozen route, shares the cancellable exclusive slot, and materializes exactly one revision.
- 2026-07-21: `45dde15f` completed H5-08; PCM and CoreAudio-source suites passed 21 focused tests serially in `/tmp/VoiceInk-H5-refine-final`; capture stays off the main actor, retained stale callbacks are generation-rejected, reusable audio storage and intermediate copies are zeroed, and the source exposes no file or normal-recorder side-effect API.
- 2026-07-21: H5-09 lifecycle, controller, presentation, normal-recorder lease, and Halo voice-lease suites passed 40 focused tests serially in `/tmp/VoiceInk-H5-refine-final`; normal recording preempts Time-Shift only after memory clearing, Halo voice capture never preempts it, late lease acquisition is cancellation-safe, lifecycle invalidation zeroes retained snapshots, and metrics expose only action, duration, and sanitized outcome.

## Deferred beyond Halo 5.0

- Exact AX field activation or automatic clicking of uncertain fields.
- Post-paste Undo across native, browser, Electron, and contenteditable destinations.
- Cross-model or cross-provider comparisons.
- Variable, persistent, background-auto-armed, or disk-backed Time-Shift Capture.
- More than two provisional alternatives or more than six durable review revisions.
