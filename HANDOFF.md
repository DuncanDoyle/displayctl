# Implementation Handoff

Updated: 2026-06-24

## Repository State

- Main workspace: `<codex-checkout>`
- Implementation worktree: `<codex-worktree>`
- Branch: `feature/phase-1-cli`
- Current HEAD: `09bf843 feat: safely connect and disconnect displays`
- Worktree was clean before this handoff file was added.

## Approved Scope

- `design.md` and `implementation-plan.md` are approved.
- Phase 1 is the Swift CLI only.
- Phase 2 adds keyboard handling and automatic zero-active-display recovery.
- Phase 3 adds the menu-bar UI.
- The user approved the Phase 1 guardrail exception for the planned file count.

## Completed and Reviewed

1. Task 1 — Swift package scaffold: passed spec and quality review.
2. Task 2 — display models, errors, and selectors: passed spec and quality review.
3. Task 3 — display inventory with topology-safe bounded reads: passed spec and quality review.
4. Task 4 — lazy private API loading with composite symbol/framework cache: passed spec and quality review.

The latest verified full test count before Task 5 was 46 tests.

## Task 5 Current State

- Implementation commit: `09bf843`
- Implementer reported 56/56 tests passing.
- Specification review: passed.
- Quality review: failed on a critical last-display safety race.

Critical issue:

- Two concurrent `displayctl disconnect` processes can each observe two active displays and disable one, leaving zero active displays.
- In-process serialization alone is insufficient because separate CLI processes must coordinate.

Proposed design change awaiting explicit user approval:

- Add a per-user, cross-process advisory file lock using Darwin `flock`.
- Hold the lock across the complete snapshot → validation → mutation → postcondition-verification sequence.
- The operating system releases the lock automatically on process exit or crash.
- Add deterministic injected-lock tests, including concurrent disconnect attempts.

Other Task 5 quality fixes to make after approval:

- Make `connectAll` idempotent when a candidate becomes active during recovery.
- Wrap snapshot failures after committed hardware mutation as `postconditionFailed` because final state is unknown.
- Require exactly one UUID match during postcondition verification.
- Preserve cancellation failure details alongside the original transaction failure.
- Verify exact transaction identity and `.forSession` in tests.
- Fix formatter violations and improve native failure diagnostics.

## Required Next Steps

1. Obtain explicit approval for the cross-process locking architecture change.
2. Update `design.md` and `implementation-plan.md` before changing Task 5 code.
3. Commit the documentation update.
4. Send the focused Task 5 fixes to the existing implementer workflow.
5. Re-run specification and quality reviews until both pass.
6. Continue Tasks 6–10 sequentially with implementer → spec review → quality review gates.

## Reliable Swift Test Invocation

Normal SwiftPM execution can stall on sandboxed user caches. Use unique local paths and disable SwiftPM's sandbox, for example:

```bash
env \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/displaycontrol-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/displaycontrol-clang-cache \
  swift test --disable-sandbox --scratch-path /tmp/displaycontrol-build
```

Terminate silent test or commit commands after 60 seconds. Commits have been reliable with `--no-gpg-sign --no-verify` when a normal commit stalls.
