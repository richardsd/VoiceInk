# Halo 4.0 — Voice-Directed Refinement

Halo 4.0 turns the Review workspace into a hands-free revision surface: while a Halo review is open, the user can invoke their existing recording shortcut or the microphone control, speak a change such as “make this more concise but keep the dates,” and receive a new immutable revision through the same provider, authentication route, model, Mode requirements, vocabulary, and frozen context as the original enhancement.

Halo remains opt-in, Mini remains the application default, and Respond and Custom Command Modes continue to use Mini. No feature flag, external API, or persisted-schema change is introduced.

## Delivery principles

- Reuse the configured Primary and Secondary recording shortcuts during Halo review; provide a mouse- and VoiceOver-operable microphone button when shortcuts are unavailable or undesirable.
- Treat spoken instructions as ephemeral review input. Never persist or log the instruction, temporary audio, partial transcript, prompt, destination identity, or frozen context.
- Reuse the original transcription configuration for the spoken instruction and the original enhancement provider, authentication method, model, Mode prompt, vocabulary, and frozen context for the replacement result. Never silently fall back.
- Keep every result immutable and parent-linked. A successful voice refinement appends one revision, selects it, and opens Changes against its parent.
- Preserve the six-revision cap, destination validation, exactly-once paste gate, licensing, trailing-space handling, clipboard restoration, auto-send ordering, and History finalization rules.
- Keep the review panel usable throughout failure: microphone, transcription, refinement, cancellation, and timeout failures preserve the selected revision and never consume the pending paste.

## Status board

| Story | Status | Depends on | Milestone deliverable |
| --- | --- | --- | --- |
| H4-00 | **Done** | — | Roadmap, backlog reconciliation, dependencies, acceptance criteria, and verification gates |
| H4-01 | **Done** | H4-00 | Pure voice-refinement state machine and reducer transitions |
| H4-02 | **Done** | H4-00 | Frozen original transcription configuration in the in-memory review session |
| H4-03 | **Done** | H4-01, H4-02 | Injectable, ephemeral audio capture and instruction transcription service |
| H4-04 | **Done** | H4-01 | Primary/Secondary shortcut lifecycle plus microphone-button fallback |
| H4-05 | **Done** | H4-01 | Free-form directive request and hardened replacement-output prompt contract |
| H4-06 | **Done** | H4-03, H4-05 | Engine orchestration from spoken instruction to immutable revision |
| H4-07 | **Done** | H4-04, H4-06 | Listening, Understanding, and Refining review UI with accessible feedback |
| H4-08 | **Done** | H4-06 | Cancellation, timeouts, cleanup, destination safety, and aggregate outcome metrics |
| H4-09 | **Done** | H4-07, H4-08 | Development gallery, localization hooks, accessibility, and focused verification |
| H4-10 | **Done** | H4-09 | Automated gates and manual application acceptance complete |

## Story acceptance criteria

### H4-00 — Roadmap and backlog

- [x] `docs/HALO_4_ROADMAP.md` records status, dependencies, acceptance criteria, milestones, verification gates, and deferred work.
- [x] `BACKLOG.md` points current work to Halo 4.0 without rewriting the completed Halo 2.0 and 3.0 records.
- [x] The current branch and unrelated user-owned worktree changes remain untouched.

### H4-01 — Voice-refinement state machine

- [x] Review state represents idle, listening, transcribing, refining, and non-destructive failure without storing instruction text in revisions.
- [x] A pure reducer accepts only valid phase transitions and rejects stale capture, transcription, and refinement completions.
- [x] Only one voice operation can run at a time; preset refinement and manual editing remain mutually exclusive with it.
- [x] Escape cancels an active voice operation first; a subsequent Escape follows the existing review-cancel behavior.
- [x] Review inactivity pauses while voice work is active and resets after every success or failure.

### H4-02 — Frozen transcription configuration

- [x] The resolved transcription model, language, realtime capability, and request context used for the original recording are captured in the in-memory Halo review session.
- [x] Late Mode changes cannot reroute the instruction transcription or replacement enhancement.
- [x] Frozen configuration and context are cleared on Apply, Cancel, expiry, style change, reset, and application shutdown.
- [x] No persisted model or backup schema changes are introduced.

### H4-03 — Ephemeral audio and transcription service

- [x] An injectable internal service records a maximum twenty-second instruction to an isolated temporary file and transcribes it with the frozen configuration.
- [x] Realtime-capable models may publish sanitized partial text; batch models show no fabricated partial transcript.
- [x] Empty and silent instructions create no revision and return to the selected result with a concise status.
- [x] Every success, error, timeout, and cancellation path stops capture, releases the microphone, cancels the session, and deletes temporary audio.
- [x] Tests require no real microphone, Accessibility permission, provider credentials, or network access.

### H4-04 — Shortcut and fallback controls

- [x] During Halo review, Primary and Secondary recording shortcuts route to voice refinement before the normal recorder path.
- [x] Toggle, Push to Talk, and Hybrid activation modes preserve their configured down/up semantics.
- [x] Review shortcuts never start a new full transcription session and their events are suppressed only when handled.
- [x] A second toggle stops capture; a long Hybrid release stops capture; a short Hybrid release remains hands-free until explicitly stopped or capped.
- [x] A microphone button provides Start/Stop and remains available when the global keyboard event tap is unavailable.

### H4-05 — Free-form directive contract

- [x] The refinement service accepts a free-form spoken directive without adding it to persisted revision metadata.
- [x] The prompt combines raw transcription, selected parent revision, original Mode requirements, vocabulary, frozen context, and the ephemeral directive.
- [x] User directives cannot override the complete-replacement, fact-preservation, no-commentary, and no-invented-facts output contract.
- [x] Empty, excessive, unchanged, malformed, unauthorized, rate-limited, timeout, network, and backend outcomes are sanitized and tested.
- [x] Provider, authentication route, and model remain exactly those frozen for the review; 401/403 invalidates OAuth without API-key fallback.

### H4-06 — Voice-to-revision orchestration

- [x] The engine performs listening → transcribing → refining with request identity and stale-result rejection at every asynchronous boundary.
- [x] Success appends one immutable `.voiceRefinement` revision, regenerates the exact prepared paste payload, selects it, and opens Changes against its parent.
- [x] Empty or unchanged output creates no revision; the selected parent remains active.
- [x] Apply, Copy, revision navigation, manual edit, preset actions, and another voice action are disabled while processing; Cancel remains available.
- [x] The existing six-revision cap and `PasteReviewResolutionGate` remain authoritative.

### H4-07 — Futuristic review presentation

- [x] An explicit **Say change** control appears separately from the five preset refinements.
- [x] Listening shows a live coral waveform and, only when real partial text exists, a compact bottom-following instruction preview.
- [x] Transcribing shows **Understanding your request…** and refining shows **Applying your spoken change…** without exposing backend payloads.
- [x] The approximately 500×380 review layout remains stable, clamped, pinned, selectable, and compatible with Reduce Motion.
- [x] VoiceOver announces phase changes, cancellation, failure, and the newly selected revision; controls have descriptive labels and state/value text.

### H4-08 — Lifecycle safety and metrics

- [x] Capture, transcription, and refinement each have bounded cancellation and timeout behavior; the hard capture limit is twenty seconds.
- [x] Apply cannot run during voice work, and destination focus is revalidated immediately before eventual delivery.
- [x] Review cancellation, timeout, reset, style change, and application termination cancel every active task and clear ephemeral data.
- [x] Aggregate local counters record only voice-started, completed, cancelled, empty, transcription-failed, and refinement-failed outcomes.
- [x] Counters never contain instruction, transcript, prompt, context, provider, model, application, or destination text.

### H4-09 — Gallery, localization, accessibility, and focused tests

- [x] The development-only Halo gallery renders listening, partial, understanding, refining, empty, cancelled, and failure states over contrasting backgrounds.
- [x] User-facing source strings are localizable without overwriting unrelated string-catalog work.
- [x] Keyboard-only, mouse-only, VoiceOver, Reduce Motion, event-tap-unavailable, and display-reconciliation behavior is covered by focused tests or the manual handoff below.
- [x] State-machine, capture-cleanup, shortcut-mode, prompt, orchestration, revision-cap, stale-result, lifecycle, and metrics tests pass.

### H4-10 — Hardening and acceptance

- [x] Focused Halo 4.0 and existing Halo/Mode/delivery/History tests pass.
- [x] The complete non-UI `VoiceInkTests` target passes using temporary Derived Data.
- [x] A Debug build succeeds using temporary Derived Data and the existing resolved package cache.
- [x] Compatibility with Mini, Notch, Respond, Custom Command, direct delivery, preset refinement, manual edit, History, clipboard restoration, and auto-send is audited.
- [x] Manual acceptance is recorded for native, browser, Electron, fullscreen, multi-display, Accessibility-denied, realtime, batch, OAuth, API-key, shortcut modes, microphone fallback, and destination focus changes.

## Delivery order

1. H4-00 materializes the approved scope.
2. H4-01 and H4-02 establish the state and frozen configuration contracts in parallel.
3. H4-03, H4-04, and H4-05 add the testable capture, interaction, and request boundaries.
4. H4-06 integrates those boundaries into immutable review revisions.
5. H4-07 and H4-08 complete the presentation and lifecycle hardening.
6. H4-09 and H4-10 close with gallery coverage, accessibility, compatibility, and verification.

## Milestone commits

The intended focused commit sequence on `codex/cursor-halo-prototype` is:

1. `H4-00 Add Halo 4.0 roadmap`
2. `H4-01 Add voice refinement review state`
3. `H4-02 Freeze transcription configuration for Halo review`
4. `H4-03 Add ephemeral voice instruction capture`
5. `H4-04 Route review recording shortcuts`
6. `H4-05 Add free-form voice refinement contract`
7. `H4-06 Orchestrate voice-directed Halo revisions`
8. `H4-07 Add Halo voice refinement presentation`
9. `H4-08 Harden voice refinement lifecycle and metrics`
10. `H4-09 Add gallery and focused Halo 4.0 verification`
11. `H4-10 Verify and hand off Halo 4.0`

## Verification gates

### Automated

- Pure state transitions, invalid transitions, request identity, stale result rejection, and cancellation precedence.
- Frozen transcription/enhancement route reuse with no provider, authentication, model, or language fallback.
- Capture start/stop, toggle/push-to-talk/hybrid semantics, twenty-second cap, empty audio, cleanup, timeout, and cancellation.
- Prompt contract, input bounds, full replacement validation, unchanged output, sanitized provider failures, and OAuth invalidation.
- Immutable parent-linked revision creation, exact payload regeneration, revision cap, lens selection, inactivity behavior, and exactly-once delivery compatibility.
- Phase UI state, partial transcript gating, microphone fallback, shortcut-event suppression, VoiceOver labels, Reduce Motion, display reconciliation, and aggregate metrics.

### Manual acceptance

- TextEdit, Mail, Safari/contenteditable, Chromium/Electron, and a code editor.
- Toggle, Push to Talk, and Hybrid Primary/Secondary shortcuts plus mouse-only control.
- Realtime and non-realtime transcription models, OAuth Luna, and API-key enhancement.
- Fullscreen, multiple displays, display removal, Accessibility denied, VoiceOver, and Reduce Motion.
- Apply after voice refinement, destination focus loss and recovery, Copy, cancellation, expiry, auto-send, History Final output, and temporary-file cleanup.

## Verification record

Automated verification completed on 2026-07-19:

- Focused Halo 4.0 state, capture, shortcut, prompt, orchestration, presentation, metrics, and delivery tests passed.
- The complete non-UI `VoiceInkTests` target passed with `-parallel-testing-enabled NO` using `/tmp/VoiceInk-Halo4-Final`.
- A Debug build passed using the same temporary Derived Data and the existing resolved package cache.
- Source-level compatibility review confirmed that Halo voice refinement is reachable only from an active Halo Paste review; Mini, Notch, Respond, Custom Command, direct delivery, preset refinement, manual edit, History finalization, clipboard restoration, and auto-send retain their existing paths.
- `VoiceInk/Localizable.xcstrings` was incorporated in the follow-up `Include strings` commit after the Halo 4.0 implementation commit.

Manual application acceptance was confirmed by the product owner on 2026-07-20 after live experimentation with the Halo workflow. Halo 4.0 has no remaining delivery gates.

## Deferred from Halo 4.0 and candidates for Halo 5.0

- Displaying, editing, confirming, or persisting the recognized spoken instruction.
- Parallel refinement variants, continuous caret tracking, true post-paste Undo, Time-Shift Capture, and automatic destination activation.
- Voice commands that directly invoke Apply, Copy, Cancel, or arbitrary application actions.
