# Halo Review 2.0 Roadmap

Halo Review 2.0 makes review optional per Paste Mode, adds safe direct delivery, and evolves Halo into a revision workspace with Change Lens and five focused refinements. Halo remains opt-in, Mini remains the application default, and Respond and Custom Command Modes continue to use Mini.

## Delivery principles

- Continue on `codex/cursor-halo-prototype`; no feature flag or persisted-schema replacement.
- Existing saved Modes decode to **Always Review**. New and starter Paste Modes default to **Review When Needed**.
- Never paste into a destination known to have changed. A destination mismatch or an unposted paste command opens a retryable review.
- Persist History and initial session metrics once before direct delivery or review becomes actionable.
- Keep frozen recording context in memory only for the lifetime of a review.
- Preserve exactly-once paste delivery, clipboard restoration, licensing, trailing-space handling, and auto-send ordering.
- Refinements reuse the resolved Mode's provider, connection, model, prompt, vocabulary, and frozen context without fallback.

## Status board

Status values are **Ready**, **In Progress**, **Blocked**, and **Done**. Update this table in the same milestone commit that completes each story.

| Story | Status | Depends on | Milestone deliverable |
| --- | --- | --- | --- |
| HR2-00 | **Done** | — | This roadmap, dependency graph, acceptance criteria, and verification gates |
| HR2-01 | **Done** | HR2-00 | Mode policy persistence, defaults, runtime configuration, and Mode UI |
| HR2-02 | **Done** | HR2-01 | Decision resolver, destination-safe direct delivery, raw-fallback policy, and recovery review |
| HR2-03 | **Done** | HR2-02 | Session override shortcut, status chips, and Pasted confirmation pulse |
| HR2-04 | **Done** | HR2-01 | Review session, revision, reducer, and inactivity-lifecycle foundation |
| HR2-05 | **Done** | HR2-02, HR2-04 | `finalizedText`, delivery finalization, History consumers, and CSV export |
| HR2-06 | **Done** | HR2-04 | Pure grouped word-diff engine and accessible representation |
| HR2-07 | **In Progress** | HR2-06 | Final/Changes/Original UI, lens shortcuts, revision navigation, and panel sizing |
| HR2-08 | Ready | HR2-04 | Refinement protocol, prompt builder, provider/auth reuse, cancellation, and mocks |
| HR2-09 | Ready | HR2-05, HR2-07, HR2-08 | Refinement Orbit UI, revision creation, parent comparison, and timeout integration |
| HR2-10 | Ready | HR2-03, HR2-09 | Cross-feature hardening, localization, compatibility audit, full tests, and manual checklist |

## Story acceptance criteria

### HR2-00 — Roadmap

- [x] The roadmap exists at `docs/HALO_REVIEW_2_ROADMAP.md`.
- [x] Stories show status, dependencies, acceptance criteria, and milestone intent.
- [x] `BACKLOG.md` is not modified or incorporated.

### HR2-01 — Delivery policy

- [x] `ModeConfig` persists Codable `alwaysReview`, `reviewWhenNeeded`, and `pasteImmediately` values.
- [x] Missing saved values decode as `alwaysReview`; new and starter Paste Modes explicitly use `reviewWhenNeeded`.
- [x] The Mode editor exposes **Halo Result** under Paste options and preserves it across output-type changes.
- [x] Runtime configuration carries the policy and resolves it again after trigger-word Mode selection.
- [x] Mini and Notch continue to ignore the policy.

### HR2-02 — Safe direct delivery

- [x] A pure delivery resolver covers policy, enhancement outcome, explicit session override, and destination state.
- [x] Successful Always Review opens review; successful Review When Needed and Paste Immediately deliver directly.
- [x] Enhancement failure reviews raw for Always Review and Review When Needed, and directly pastes raw with a warning for Paste Immediately.
- [x] Direct delivery validates the captured PID and compatible focused-element identity.
- [x] Destination mismatch or an unposted paste command opens the same payload in retryable review.
- [x] History and metrics are persisted once before either route is actionable.
- [x] Paste posts exactly once and auto-send happens only after a successful paste post.

### HR2-03 — Session override and confirmation

- [x] During active Halo processing, `Command-Return` toggles a non-persisted force-direct or force-review override.
- [x] Explicit overrides survive late trigger-word Mode selection; otherwise the final Mode policy wins.
- [x] Halo shows **Quick Apply armed** or **Review this result** while the override is set.
- [x] Review treats Return and Command-Return as Apply.
- [x] Override state resets on delivery, cancellation, timeout, style change, reset, and new recording.
- [x] Successful direct paste shows one non-key, mouse-transparent **Pasted** pulse for about 450 ms.

### HR2-04 — Review foundation

- [x] Immutable session and revision types snapshot destination, context, metadata, payload, and initial result.
- [x] The pure reducer handles lens selection, revision selection, refinement lifecycle, timeout, and stale responses.
- [x] The resolution gate remains the authoritative exactly-once delivery gate.
- [x] Reviews contain at most six revisions and never evict an existing revision.
- [x] A two-minute inactivity timer resets on qualifying interactions and pauses during refinement.
- [x] Cancellation, style changes, reset, and shutdown clear frozen in-memory context and cancel work.

### HR2-05 — Finalized History

- [x] `Transcription.finalizedText` is optional and compatible with existing SwiftData stores.
- [x] It is written only after a Halo paste command posts successfully.
- [x] Copy, cancellation, expiration, and failed delivery do not finalize a transcription.
- [x] User-facing result consumers prefer `finalizedText ?? enhancedText ?? text`.
- [x] History details distinguish Original, Enhanced, and Final when values differ.
- [x] CSV appends a `Final Transcript` column without reordering existing columns.
- [x] Refinements do not duplicate initial enhancement metrics.

### HR2-06 — Change Lens engine

- [x] The pure tokenizer preserves words, punctuation, whitespace, Unicode, emoji, and line breaks.
- [x] Adjacent insertions and removals are grouped into readable phrase-level edits.
- [x] Diff output represents unchanged, added, and removed content with accessible labels.
- [x] Identical, empty, multiline, and long inputs are covered by unit tests.
- [x] Background diff consumers can discard cancelled or stale results.

### HR2-07 — Review lenses and navigation

- [ ] Review opens on Final at the first line of the selected revision in an approximately 500×380 panel.
- [ ] Final, Changes, and Original lenses are selectable; Changes compares revision 1 to raw and later revisions to their parent.
- [ ] Additions are blue, removals muted coral with restrained strikethrough, and unchanged text off-white.
- [ ] Command-1/2/3 select lenses and Command-bracket navigates revisions.
- [ ] Return and Command-Return apply; Escape cancels review unless it first cancels an active refinement.
- [ ] Selective interaction and event-tap failure remain safe and mouse-operable.

### HR2-08 — Refinement service

- [ ] `HaloRefinementServicing` is injectable and exposes exactly Shorter, Clearer, Friendlier, Formal, and Fix terms.
- [ ] Requests combine raw text, selected revision, original Mode requirements, vocabulary, frozen context, and one action.
- [ ] Requests require a complete replacement with no commentary or invented facts.
- [ ] Provider, authentication route, and model are reused exactly; no provider or credential fallback occurs.
- [ ] Only one request runs at a time and supports cancellation and stale-result rejection.
- [ ] Empty, unchanged, unauthorized, rate-limited, timeout, network, malformed, and backend outcomes are sanitized and tested.

### HR2-09 — Refinement Orbit

- [ ] Five refinement actions are present and disabled at the six-revision limit.
- [ ] Apply, Copy, navigation, and other refinement actions are disabled during a request; Cancel remains available.
- [ ] Success appends and selects a revision, prepares its exact paste payload, and switches to parent-relative Changes.
- [ ] Empty or unchanged results add no revision and preserve the current selection.
- [ ] Refinement completion resumes and resets the inactivity timer.
- [ ] Successful refined delivery finalizes History with the pasted revision.

### HR2-10 — Hardening and acceptance

- [ ] New strings are localized and recorder/output compatibility is audited.
- [ ] Focused Halo, Mode, delivery, History, diff, reducer, and refinement tests pass.
- [ ] The complete non-UI test suite passes using temporary Derived Data.
- [ ] A Debug build succeeds using temporary Derived Data.
- [ ] Manual acceptance is recorded for supported editors, display configurations, providers, policies, shortcuts, failures, auto-send, and History.

## Milestone commits

Each story is delivered as a focused commit on `codex/cursor-halo-prototype`. The intended dependency order is:

1. `HR2-00 Add Halo Review 2.0 roadmap`
2. `HR2-01 Add per-Mode Halo delivery policy`
3. `HR2-02 Add destination-safe Halo direct delivery`
4. `HR2-03 Add Halo Quick Apply and confirmation pulse`
5. `HR2-04 Add Halo review session and revision foundation`
6. `HR2-05 Finalize pasted Halo results in History`
7. `HR2-06 Add grouped word diff engine`
8. `HR2-07 Add Halo Change Lens and revision navigation`
9. `HR2-08 Add provider-stable Halo refinement service`
10. `HR2-09 Add Refinement Orbit revisions`
11. `HR2-10 Harden and verify Halo Review 2.0`

HR2-06 and HR2-08 may be developed in parallel after HR2-04, but their commits remain dependency-ordered in the shared worktree.

## Verification gates

### Automated

- Mode Codable compatibility, starter defaults, editor persistence, backup round trips, and trigger-word re-resolution.
- Full policy × enhancement outcome × override × destination-state decision matrix.
- Exactly-once paste, destination validation, recovery review, finalization timing, auto-send ordering, and confirmation cleanup.
- Existing-store migration plus History preview, detail, search, Copy Last, Paste Last Enhancement, dashboard, and CSV precedence.
- Diff tokenization/grouping, reducer transitions, revision cap, inactivity, cancellation, and stale work.
- Refinement success, unchanged/empty responses, provider/auth reuse, cancellation, and sanitized failures.
- Keyboard suppression, mouse-region fallback, event-tap failure, Reduce Motion, and display reconciliation.

### Manual acceptance

- TextEdit, Mail, Safari/contenteditable, Chromium/Electron, and a code editor.
- Fullscreen, multiple displays, Accessibility denied, realtime and non-realtime transcription.
- Raw and enhanced Modes, OAuth Luna, API-key enhancement, all three policies, and Quick Apply.
- Destination focus changes, every refinement action, refinement failures, auto-send, and History retention.

## Deferred work

Free-form typed refinement, voice refinement, parallel variants, continuous caret tracking, post-paste undo, and Time-Shift Capture remain outside Halo Review 2.0.
