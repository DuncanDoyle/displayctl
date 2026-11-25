# Phase 2 Design — Menu bar app

## 1. Status

- Phase: 2 — Menu bar app (D-009)
- Status: Draft, awaiting user approval and Codex review
- Platform: Apple Silicon Mac, macOS 27.0.1 (D-002)
- Language: Swift, SwiftUI and AppKit; no new third-party dependencies
- Builds on: `DisplayControlCore` from Phase 1, unchanged except for the additions in §5

## 2. Intent

Switching the built-in display off today means opening Terminal and typing `displayctl disconnect internal`. The owner wants the same control one click away: a menu bar icon that opens a small panel with an on/off switch per display and a brightness slider for the external monitor, like the Wi-Fi and Bluetooth panels in Control Center.

The everyday setup is a MacBook docked to a Dell U2720Q with the built-in display off. Undocking in that state leaves no active display, and today the only ways out are typing `displayctl connect all` blind or rebooting (D-008: logout does not help). The app therefore also carries the safety net: when no display is active, it turns disabled displays back on.

## 3. Goals, non-goals, anti-goals

Goals:
- One click from the menu bar to switch any display on or off.
- Hardware (DDC) brightness slider for DDC-capable external displays.
- Automatic recovery when no display is active, without user input.
- Always running: starts at login, restarts after a crash, stays stopped after Quit.

Non-goals (this phase):
- Brightness keys that follow the pointer (Phase 3).
- Brightness for the built-in display; macOS's keys already handle it.
- Notifications, preferences window, per-display presets, display arrangement.
- Signing, notarization, distribution beyond the owner's Mac.

Anti-goals (failure even if it works):
- A switch that leaves the owner with no usable screen.
- A slider that floods the monitor with DDC writes or ends on a value other than where the owner let go.
- The app fighting a choice the owner made on purpose: the safety net never acts while any display is active.
- State that disagrees with the CLI. Both share one ledger and one lock.

## 4. Approaches

UI shape:
- **Control Center-style panel (chosen).** SwiftUI `MenuBarExtra` with the window style: real switches and a native slider. Matches what the owner asked for ("on-off toggles, macOS style").
- Classic menu with checkmarks. Simplest, but a slider needs a custom view; brightness would be steps. Rejected by the owner.

How it stays running:
- **Per-user launchd agent (chosen).** Starts at login, restarted by launchd after a crash, stays stopped after a clean Quit. The safety net matters most when the owner cannot see a screen to restart anything.
- Login item. Simpler install, but a crash removes the icon and the safety net until the next login. Rejected by the owner.

Where the safety net lives:
- **Inside the menu bar app (chosen).** The app is always running anyway; one process, one install. Phase 3's key handling can join the same process later.
- Separate background agent. Two processes and two installs for no requirement this phase has.

## 5. Architecture

```
displayctl (CLI)        displayctl-menu (launchd agent)
      \                    /            \
       \            DisplayMenuKit     SwiftUI views (thin)
        \           (state, intents)
         \               |
          DisplayControlCore  ──  ledger + operation lock
          (+ ZeroActiveRecovery)    ~/Library/Application Support/displayctl/
```

- `DisplayControlCore` gains `ZeroActiveRecovery`: the safety-net policy, UI-free, so Phase 3 can reuse it. Its inputs are a display snapshot, the ledger and `connectAll`; its clock and sleep are injectable.
- New library target `DisplayMenuKit`: the panel's state model (rows, switch enablement, busy and error state), operation dispatch, and the brightness coalescer. No SwiftUI views, so it is unit-testable.
- New executable target `displayctl-menu`: the `MenuBarExtra` scene, views, the display-reconfiguration and wake observers, and process lifecycle. Kept thin.
- The CLI is unchanged. Both processes use the same `ConnectionController` (same ledger, same `flock` lock), so a CLI change and a menu change cannot both pass the last-active check.

## 6. Components

### 6.1 Panel

The icon is the SF Symbol `display` (`display.2` when more than one display is active is the builder's call).

Clicking it opens:

```
┌──────────────────────────────┐
│ Displays                     │
│ Built-in Retina Display  [●○]│
│ DELL U2720Q              [●○]│
│   ☀ ━━━━━━●━━━━━━━  40%      │
│──────────────────────────────│
│ Quit                         │
└──────────────────────────────┘
```

Rows:
- One row per online display, plus one per ledger entry that macOS no longer lists (D-005). Ledger-only rows show as off.
- Switch on = display active. Turning it off calls `disconnect <uuid>`; turning it on calls `connect <uuid>`.
- The switch of the last active display is disabled, with a short caption ("Only active display"). The controller still enforces the rule; the UI only avoids offering it.
- While an operation runs, every switch is disabled and the row shows a spinner. Operations run off the main thread, one at a time.
- A failure shows one short line under its row, from the controller's error. It clears on the next success or when the panel reopens. A lock timeout reads "Busy — another displayctl is running. Try again."
- The panel refreshes when it opens, after each operation, and on every display reconfiguration, so a CLI change shows up.
- Ordering: built-in first, then externals by name.

### 6.2 Brightness slider

- Shown under each active external display whose DDC capability is not `unsupported`.
- On panel open the app reads the current value (`DDCBrightnessController.get`). Until a read succeeds the label shows "—" and the slider sits at the last value this app run saw, or the middle. Showing the slider never writes.
- While dragging, at most one DDC write is in flight. When it finishes, the app sends the newest value if it changed. The value where the owner let go is always written last.
- Write failures show one line under the slider; the next drag tries again.
- Range 0–100 %, step 1.

### 6.3 Safety net (`ZeroActiveRecovery`)

Triggers:
1. App start (covers a launchd restart after a crash).
2. End of a display reconfiguration (`CGDisplayRegisterReconfigurationCallback`).
3. System wake.

On a trigger:
1. Wait for a settle period (default 2 s) after the last trigger, so transient states during plug or unplug do not count.
2. Take a snapshot. An inconsistent snapshot ("inventory changed while sampling") is retried.
3. If any display is active, do nothing.
4. If none is active and the ledger has entries, run `connectAll`.
5. Re-check. If still none is active, retry a bounded number of times (default 3, 2 s apart), then stop and log.
6. Log every decision with `os.Logger` (subsystem `displayctl`, category `recovery`).

It never disconnects anything and never acts while a display is active. Entries from an earlier boot are refused by the ledger rule (§6.3.1 of the Phase 1 design) and logged; see §9.

### 6.4 Process lifecycle and install

- No Dock icon (accessory activation policy).
- Quit exits with status 0. A crash exits non-zero.
- LaunchAgent plist in `~/Library/LaunchAgents/`, label `com.github.duncandoyle.displayctl-menu`: `RunAtLoad` true, `KeepAlive` `{SuccessfulExit: false}`, `LimitLoadToSessionType` `Aqua`, `ProcessType` `Interactive`.
- `Scripts/install-menu.sh` builds release, copies the binary to `~/.local/bin/displayctl-menu`, writes the plist and bootstraps it into `gui/<uid>`. `Scripts/uninstall-menu.sh` boots it out and removes the plist.
- After a Quit, the app starts again at the next login, or with `launchctl kickstart gui/<uid>/com.github.duncandoyle.displayctl-menu`. README documents both.

## 7. Safety and error handling

All Phase 1 safety rules hold. In addition:
- The menu never offers to turn off the last active display, and the controller refuses it regardless.
- One connection operation at a time per process; the shared lock serializes across processes.
- The slider never writes on display, only on user input.
- The safety net acts only at zero active displays.
- If the app is not running, the CLI and its recovery order (`connect all`, then reboot) still apply.

## 8. Testing

Automated (at the `DisplayMenuKit` and `ZeroActiveRecovery` boundaries, with fakes for snapshot, controller, DDC and clock; no timing-based waits):
- Rows: online and ledger-only displays, ordering, last-active switch disabled, busy state, error line set and cleared.
- An operation failure leaves state consistent with a fresh snapshot.
- Brightness coalescer: one write in flight; final value always written; no write without user input; a failed write does not block the next drag.
- Safety net: no-op while any display is active; acts at zero with ledger entries; no-op at zero with an empty ledger (logged); inconsistent snapshot retried; bounded retries; startup trigger runs the same path.

Hardware (owner present, Dell attached; recovery from a failed step is replugging the Dell):
1. Install; icon appears; panel lists both displays with correct state.
2. Built-in off and on from the panel.
3. Dell off and on from the panel (built-in active).
4. The only active display's switch is disabled.
5. Slider changes the Dell's brightness visibly; a fast drag ends on the released value.
6. A CLI `disconnect internal` shows up in the open panel.
7. `kill -9` the app: launchd restarts it and the icon returns.
8. Quit: the app stays stopped until `kickstart` or the next login.
9. Safety net: built-in off from the panel, then unplug the Dell. The built-in display comes back without input. Over HDMI; USB-C if available.

## 9. Risks and open questions

- **Reboot behaviour is unknown (D-008).** If a disable survives a reboot, the ledger refuses its entries and the safety net cannot help after one. The owner's reboot test answers this; a ledger rule change, if needed, goes through Phase 1 or a new decision.
- **`MenuBarExtra` from a bare executable.** Unverified that a SwiftPM executable without an app bundle shows a `MenuBarExtra` under launchd. The plan starts with a spike; the fallback is a minimal `.app` bundle (Info.plist with `LSUIElement`) assembled by the install script.
- **Lid closed.** With the lid closed and the Dell unplugged the Mac sleeps; recovery then runs on wake. Behaviour with the lid closed while awake on power is not designed for.
- **DDC from two processes.** The CLI and the slider can write DDC at the same time; there is no cross-process DDC lock. Accepted: the last write wins, and the owner drives both.

## 10. Left to the builder

- Exact SwiftUI layout, spacing and captions within §6.1.
- Settle period and retry counts, within the defaults above.
- Whether the last-read brightness is cached across panel openings.

## 11. Acceptance criteria

Phase 2 is complete when:
- The package builds and all automated tests pass on the target Mac.
- Hardware steps 1–9 in §8 pass, recorded in README with dates.
- The README documents install, uninstall, Quit and restart, and recovery.
- Design and plan match the code; `decisions.md` holds any deviation.
