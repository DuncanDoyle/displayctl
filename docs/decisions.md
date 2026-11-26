# Decision log

Append-only. Newest at the bottom. Supersede, don't edit.

## D-001 — Continue the project in Claude Code, reviewed by Codex (2026-11-23, phase 1)
**Context:** Phase 1 was designed and implemented by Codex in `<codex-checkout>`.
**Decision:** The repo was cloned with full history into `<this checkout>` (remote `codex`). Claude authors new work; Codex reviews it. Docs moved to the agentic-engineering-sdlc layout under `docs/`.
**Alternatives:** Working in the Codex checkout — rejected to keep the two agents' workspaces separate.
**Consequences:** Phase 1 authorship is mixed: commits up to `c324c9c` are Codex-authored, later ones Claude-authored.

## D-002 — Target platform is now macOS 27 (2026-11-23, phase 1)
**Context:** The design targets macOS Tahoe 26.5. The Mac now runs macOS 27.0.1 (26A434) with Swift 6.4.2. All private APIs used were only observed on 26.5.
**Decision:** Phase 1 validation targets macOS 27.0.1. The June hardware results on 26.5 are history, not evidence for 27. `displayctl list` and all 125 automated tests pass on 27.0.1 (2026-11-23).
**Alternatives:** none — the OS cannot be held back.
**Consequences:** Every hardware matrix item is re-run on 27, including the DDC brightness checks that passed in June.

## D-003 — Disabled displays must always be recoverable without a reboot (2026-11-23, phase 1)
**Context:** On 2026-06-30, disconnecting the HDMI Dell U2720Q made macOS drop it from the online display list. `connect all` only re-enables displays in that list, so it could not bring it back. Replugging HDMI failed too; only a reboot recovered it. The user called this the main pain point of testing.
**Decision:** Two safety mechanisms, approved by the user ("Ledger + watchdog"):
1. A persisted ledger of every display that `displayctl` disables (UUID and runtime ID, written before the disable). `connect <selector>` and `connect all` also try to re-enable ledger entries that macOS no longer lists as online.
2. The hardware test arms a watchdog before each disconnect. It reconnects everything after a short timeout unless the user confirms they can see and use a display.
Hardware testing does the internal display first (the main use case, with the Dell as the safe screen). External disconnect is retested only after the internal one passes.
**Alternatives:** Ledger only (no protection when the user cannot type); internal-only support (drops a designed feature).
**Consequences:** Amends design §6.3, §7.3 and §9.2: `connect` no longer limits itself to displays the OS reports as online, and the tool keeps state across invocations. Done in planned sub-phase 1.1.

## D-004 — Refine D-003 after Codex design review; add a trial disconnect (2026-11-23, phase 1)
**Context:** Codex's review (`docs/phases/phase-1/reviews/1.1-design-codex.md`) found that D-003 could re-enable the wrong display through a reused runtime ID, that the watchdog could be disarmed or lose the lock race, and that nothing proves macOS 27 can re-enable a hidden display.
**Decision:** (1) Ledger entries are matched by UUID first; an offline entry is enabled by its recorded runtime ID only if no other online display holds that ID and the entry is from the current boot. The rollback follows the same rule. (2) Ledger and lock live in `~/Library/Application Support/displayctl/`, written atomically under the lock. (3) The watchdog stays armed until the original active set is restored, and retries until a hard deadline. (4) New test-only `displayctl disconnect <sel> --trial <seconds>` disables the display with the app-only configuration scope, holds it for at most the given time, then exits; macOS should undo the change at process exit. It is the first hardware step. User approved: "Yes, trial first".
**Alternatives:** Ledger + watchdog only — no protection that is independent of our own recovery code.
**Consequences:** One more CLI option. If the trial shows that app-only scope does not revert a private enable, or that a hidden display cannot be re-enabled, external disconnect stays unsupported in Phase 1 until a new decision.

## D-005 — A disabled display counts as disconnected when it leaves the online list (2026-11-23, phase 1)
**Context:** First hardware run on macOS 27.0.1: `disconnect internal --trial 10` failed with "had 0 matches after requesting enabled false", and the rollback re-enabled the internal display at once by its recorded ID 1. The June HDMI run on 26.5 failed with the same message. macOS drops a display disabled with `CGSConfigureDisplayEnabled` from `CGGetOnlineDisplayList`; it does not list it as online and inactive, which the postcondition in §6.3 step 9 expected.
**Decision:** After a disable, the display's UUID being absent from the online list, or present and inactive, both verify the disconnect. Enable still requires the UUID to be present and active. The ledger is the only way back to a display in that state.
**Alternatives:** Reading a wider display list that includes disabled displays — none is known in the public API, and the ledger already covers it.
**Consequences:** The June HDMI "failure" was most likely a successful disconnect misread by the postcondition, followed by recovery that could not find the display. The rollback on 2026-11-23 also showed that macOS 27 re-enables a display that has left the online list, by its recorded runtime ID (internal display; HDMI unverified).

## D-006 — Drop `--trial`; the watchdog and ledger are the safety net (2026-11-23, phase 1)
**Context:** Second macOS 27.0.1 hardware run: `disconnect internal --trial 10` disabled the internal display, held 11 s and exited 0, but the display was still off 5 s after exit. The app-only configuration scope does not undo a `CGSConfigureDisplayEnabled` change at process exit. The watchdog then ran `connect all`, which re-enabled the internal display from the ledger (it had left the online list) on its first attempt.
**Decision:** Remove `--trial` and the app-only scope; its safety promise is false on macOS 27. Supersedes D-004 (4) and design §6.3.2. Hardware test order: internal session round trip, unattended watchdog run, then the external display with the watchdog after a separate opt-in. User chose: "Drop trial, use watchdog".
**Alternatives:** Internal-only support, recording external disconnect as unsupported (no reboot risk, loses a feature); keeping `--trial` for a future macOS (dead code with a false promise).
**Consequences:** No OS-owned safety net exists. If the external display does not come back from the ledger, recovery is `connect all`, then logout/login, then reboot. External disconnect is recorded as supported only if its recovery from a dropped display is observed.

## D-007 — Rewrite history before publishing (2026-11-23)
**Context:** The repo was published to a public GitHub repository. Its history held local filesystem paths in review files, the Codex handoff and this log.
**Decision:** Before the first push, `git filter-repo` replaced local paths with repo-root links, `~/` paths or placeholders (`<codex-checkout>`, `<codex-worktree>`, `<this checkout>`). Commit SHAs changed. SHAs cited in the docs, including inside reviewer text, were updated mechanically to the new ones; the review text is otherwise unchanged. `main` was fast-forwarded to the Phase 1 branch, and only `main` was pushed. User approved: "Make sure everything is clean before we push", "Keep gmail, push now".
**Alternatives:** Squashing to one commit (loses the review trail); leaving the paths (exposes local layout).
**Consequences:** SHAs in earlier chat logs or the original Codex checkout no longer match this repo.

## D-008 — Logout does not undo a disconnect; `connect all` is the recovery path (2026-11-25, phase 1)
**Context:** On macOS 27.0.1 the user ran `disconnect internal`, then logged out and back in. The built-in display stayed off through both, and the Dell stayed on. Design §6.3 assumed session-scoped changes revert at logout. A manual `connect all` then restored the built-in display from the ledger (same boot session), exit 0, with no flicker on the Dell.
**Decision:** Logout/login is not a recovery path. Recovery is `connect all`, then a reboot. Supersedes the logout step in D-006's consequences and the recovery boundary in design §6.3.
**Alternatives:** none — the behaviour is macOS's.
**Consequences:** Whether a reboot restores a disabled display is unverified. If the disable survived a reboot, the ledger would refuse its entries (they come from an earlier boot), and only another display would keep the Mac usable. Until that is tested, do not reboot or unplug the other display while one is off.

## D-009 — Menu bar app becomes Phase 2, with the safety net; keyboard agent moves to Phase 3 (2026-11-25)
**Context:** The roadmap put a keyboard brightness agent with zero-active-display recovery in Phase 2, and a menu bar app in Phase 3. The user wants the menu bar app first, with switches per display and a brightness slider; brightness keys that follow the pointer are not needed now. The safety net (recover when no display is active) is wanted.
**Decision:** Phase 2 is a menu bar app in a Control Center-style panel: an on/off switch per display and a brightness slider for DDC-capable external displays. It holds the zero-active-display recovery from the old §10.2. It runs as a per-user launchd agent that restarts after a crash and stays stopped after Quit. The keyboard agent becomes Phase 3, without the recovery part. Phase 2 design and plan start while Phase 1 is still open; no Phase 2 code before Phase 1 closes. User chose: "B" (launchd agent), "B" (panel), "Commit and push, start Phase 2 design. I'll check phase 1 later".
**Alternatives:** Keep the order (keyboard agent first; the user does not need it now); login-item app (no restart after a crash, when the safety net matters most); classic menu with checkmarks (no native slider).
**Consequences:** Supersedes Phase 1 design §10.2–§10.3 and the Phase 1 guardrail that Phase 2/3 not begin during Phase 1, for design work only. Roadmap reordered.

## D-010 — A reboot restores a disabled display (2026-11-26, phase 1)
**Context:** D-008 left open whether a reboot restores a display that `displayctl` disabled. The owner ran `disconnect internal` with the Dell attached and rebooted.
**Decision:** Reboot is a verified last resort: the built-in display came back on its own after the reboot (macOS 27.0.1). The ledger kept its entry from the earlier boot. A later `connect all` found the UUID already active, removed the entry and exited 0. Recovery order stays `connect all`, then reboot. No ledger rule change is needed.
**Alternatives:** none — observed behaviour.
**Consequences:** Answers D-008's open question and Phase 2 design §9's reboot risk. After a reboot an earlier-boot entry can linger until the next `connect all` or `connect <that display>`; it is harmless because the display is already active.

## D-011 — Second history rewrite to remove local paths (2026-11-26)
**Context:** Reviewer reports link files by absolute local path. Five review files committed and pushed on 2026-11-25 and 2026-11-26 contained the owner's local checkout path (Phase 2 code review, finding 8).
**Decision:** `git filter-repo` replaced the local paths in every commit, as in D-007. SHAs cited in the docs were updated mechanically; `main` was force-pushed. A pre-commit hook (`.githooks/pre-commit`, enabled with `git config core.hooksPath .githooks`) and `Scripts/check-local-paths.sh` now block local paths, and `AGENTS.md` states the rule. Owner: "Rewrite history. And add something somewhere (AGENTS.md?) so this won't happen again."
**Alternatives:** Leaving the old commits as they are (the path stays public).
**Consequences:** SHAs in chat logs and earlier sessions no longer match. Other clones must re-clone or reset to the new `main`.

## D-012 — macOS adds a placeholder display when no real display is left; it does not count as active (2026-11-26, phase 2)
**Context:** Phase 2 hardware step 9 (built-in off with the menu app, then the Dell unplugged) failed three times: the built-in never came back. Probes showed that about 6 s after the unplug macOS creates a placeholder display and keeps it until a real display returns: active, main, external, vendor `unkn` (0x756E6B6E), model `virt` (0x76697274), serial 0, physical size 0×0 mm, no current display mode, no `NSScreen`, 1920×1080; UUID `DEE21DC4-D655-4C72-BB90-001415FBABA5` in both runs, runtime IDs 12 and 13. So "zero active displays", which the safety net and the test fallback wait for, never happens.
**Decision:** `DisplayInventory` marks a display as a placeholder when all four hold: vendor `unkn`, model `virt`, physical size 0×0 mm, no current display mode. It stays in snapshots (so runtime-ID ownership and consistency checks still see it), flagged on `Display`. Every "is a usable display active?" decision skips it: the disconnect last-active check, the post-disable check, `recoverIfNoneActive`, the scheduler's re-arm count, the panel rows and `displayctl list` (which notes it on stderr). The signature is a heuristic verified on macOS 27.0.1 only; the owner rarely uses Sidecar and other virtual displays, so no negative control was captured. Reviewed before coding: reviews/placeholder-codex.md. Owner: "Go".
**Alternatives:** Dropping the placeholder from snapshots (weakens runtime-ID ownership checks, placeholder-codex #1); detecting it only in the safety net (panel and CLI show a ghost row); reacting to "the last external disappeared" (more complex, misses wake cases).
**Consequences:** Amends Phase 2 design §6.1, §6.3 and §8 and the Phase 1 inventory model (one new `Display` field). Re-run the probe after a macOS update.
