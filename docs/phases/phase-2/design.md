# Phase 2 Design — Menu bar app

## 1. Status

- Phase: 2 — Menu bar app (D-009)
- Status: Approved by the owner 2026-11-26 (after Codex reviews design-codex.md, design2-codex.md)
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
- The app is not sandboxed: a sandbox would move `~/Library/Application Support` into the app's container and split the ledger and lock from the CLI's.
- The CLI is unchanged. Both processes use the same `ConnectionController` (same ledger, same `flock` lock), so a CLI change and a menu change cannot both pass the last-active check.
- `ConnectionController` gains `recoverIfNoneActive()`: under the operation lock it takes a snapshot and returns `nil` if any display is active; otherwise it runs the same body as `connectAll`. The zero-active check and the mutation therefore happen under one lock, so a CLI `connect` that wins the lock first is never followed by recovery turning on other displays. `connectAll` keeps its unconditional behaviour.

Execution boundaries:
- Blocking controller and inventory calls run on one serial `DispatchQueue` owned by the app, never on the main thread and never on Swift's cooperative pool. Callers `await` them through a continuation. The recovery code depends only on `async` protocols, so the app supplies queue-backed adapters and the CLI keeps its synchronous API.
- DDC calls stay on the existing `DDCBrightnessController` actor. A write blocks one cooperative thread for at most its bounded retries (a few hundred ms). The slider has at most one write in flight, so at most one thread is ever blocked. Accepted trade-off: it keeps Phase 1's DDC code unchanged.
- `DisplayInventory` reads display names from `NSScreen`. When called off the main thread it fetches them with `DispatchQueue.main.sync`. The main thread never waits synchronously on the work queue, so this cannot deadlock.

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
- One row per online display, plus one per ledger entry from the current boot that macOS no longer lists (D-005). Ledger-only rows show as off. Entries from an earlier boot get no row. An orphan left when a display was re-cabled while off (its UUID changes per connection path) cannot be told apart from a real ledger-only display in the same boot, so it shows as an off row; turning it on fails with the controller's error, and `displayctl forget` removes it.
- Switch on = display active. Turning it off calls `disconnect <uuid>`; turning it on calls `connect <uuid>`.
- The switch of the last active display is disabled, with a short caption ("Only active display"). The controller still enforces the rule; the UI only avoids offering it.
- While an operation runs, every switch is disabled and the row shows a spinner. Operations run off the main thread, one at a time.
- A failure shows one short line under its row, from the controller's error. It clears on the next success for that display or when the panel opens again; a background refresh does not clear it. A lock timeout reads "Busy — another displayctl is running. Try again."
- The panel refreshes when it opens, after each operation, and on every display reconfiguration, so a CLI change shows up.
- Each snapshot (from a refresh or from the end of a switch) gets an increasing sequence number when it is requested. A snapshot is published to the rows only if no later one has been published. The switch itself owns its row's busy state and error: those are set when it finishes, whatever snapshots arrived meanwhile.
- The model knows whether the panel is open (`panelOpened`/`panelClosed`). Background refreshes while it is closed update rows but do no DDC reads.
- If the saved display list cannot be read, the panel shows one line: "Saved display list unreadable. See README › Recovery." The file is left as it is. The README explains how to inspect it and when `displayctl forget all` is safe (only after every display that was turned off is back on).
- Ordering: built-in first, then externals by name.

### 6.2 Brightness slider

- Shown under each active external display whose DDC capability is not `unsupported`.
- The app reads the current value (`DDCBrightnessController.get`) when the panel opens and whenever a row gains a slider while the panel is open (display turned on, monitor plugged in). Until a read succeeds the label shows "—" and the slider sits at the last value this app run saw, or the middle. Showing the slider never writes. A reply with maximum 0 counts as a failed read.
- While dragging, at most one DDC write is in flight. When it finishes, the app sends the newest value if it changed. The value where the owner let go is always written last. Slider values reach the coalescer in the order they were produced: the coalescer lives on the main actor and is called synchronously from the slider.
- Each write looks up the display by UUID in a fresh snapshot just before sending, and is dropped if that UUID is no longer online and active. When a display leaves or turns off, its pending value is discarded and late results for it are ignored. A queued value therefore never reaches a different monitor that reused the runtime ID. The guarantee covers queued values, not a write already handed to the DDC actor: a runtime ID reused while that write waits for or runs on the actor can reach the replacement monitor. Accepted on the same grounds as the owner-confirmed Phase 1 case (reviews/design2-codex.md #5): it needs an unplug and a different monitor in that window, and the result is only a brightness change (reviews/code-codex.md #5, owner confirmation pending).
- Write failures show one line under the slider; the next drag tries again.
- Range 0–100 %, step 1.

### 6.3 Safety net (`ZeroActiveRecovery`)

Triggers:
1. App start (covers a launchd restart after a crash).
2. End of a display reconfiguration (`CGDisplayRegisterReconfigurationCallback`, callbacks without the begin flag).
3. System wake (`NSWorkspace.shared.notificationCenter`, `didWakeNotification`).

On a trigger:
1. Wait for a settle period (default 2 s) after the last trigger, so transient states during plug or unplug do not count.
2. Call `recoverIfNoneActive()`. It checks and acts under the operation lock (§5). `nil` means a display is active: done.
3. Otherwise check the result. Recovery succeeded if a fresh snapshot shows at least one active display. Every failed outcome is logged with its display and reason, including a refused earlier-boot entry and an unreadable ledger (returned as an outcome with no display).
4. If still no display is active, retry (default 3 attempts in total, 2 s apart). A thrown error, such as a lock timeout while a CLI command runs, counts as a failed attempt.
5. An inconsistent sample (`inventoryChanged`, thrown once the inventory's 3 samples in total all failed), whether from the locked check or the verification, is not an attempt: it is sampled again after the retry delay, up to 5 times per episode. If those run out, the episode ends as inconclusive.
6. Log every decision with `os.Logger` (subsystem `displayctl`, category `recovery`), including the trigger that started the episode.

Episodes: the attempts above form one episode, and only one runs at a time. Triggers that arrive during an episode, including callbacks caused by its own enable calls, are dropped; the episode re-checks on its own. After an episode:
- **Recovered, display active, or inconclusive:** the next trigger starts a new episode as usual.
- **Failed (still no display active after 3 attempts):** the safety net stays quiet. A wake re-arms it. So does a reconfiguration callback after which the active-display count (a cheap `CGGetActiveDisplayList` count, not a full inventory) is above zero, for example the Dell plugged back in.

This keeps the retry budget bounded without missing the next real undock.

Observer registration is part of the safety net. If `CGDisplayRegisterReconfigurationCallback` returns an error, the app logs it and the panel shows "Safety net off: display changes are not being watched." The callback context lives for the whole process; the C callback only hands the event to the main actor and returns.

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
- An older refresh cannot overwrite the result of a newer operation.
- Brightness: a row that gains a slider while open is read; a display leaving discards its pending write; maximum 0 is a read error.
- Safety net: no-op while any display is active, checked under the lock (a CLI connect that wins the lock leaves other displays off); returned failures and thrown errors both logged and counted; bounded retries; episodes end and re-arm only on wake or an active display; startup trigger runs the same path.

Hardware (owner present, Dell attached). Every step that can leave no active display first arms an independent fallback outside the app. It has the Phase 1 watchdog's guarantees: it is detached, confirms it is running, and from 30 s on retries `displayctl connect all` until a display is active or a 90 s hard deadline passes. Before the first zero-active step, the fallback alone is shown to restore a built-in display that was turned off with the CLI (app stopped, Dell attached). The app must restore a display within 10 s of the event (unplug, launch or wake); the record notes whether the app or the fallback restored it, and which trigger the app logged. Replugging the Dell is the last resort. These steps deliberately leave no other display attached; the fallback makes that acceptable, and a reboot restores the display if all else fails (D-010).

Each step starts with both displays on and the app running unless it says otherwise.
1. Install; icon appears; panel lists both displays with correct state. Close and reopen the panel: it refreshes each time.
2. Built-in off and on from the panel.
3. Dell off and on from the panel (built-in active).
4. The only active display's switch is disabled.
5. Slider changes the Dell's brightness visibly; a fast drag ends on the released value.
6. A CLI `disconnect internal` shows up in the open panel.
7. `kill -9` the app: launchd restarts it and the icon returns.
8. Quit: the app stays stopped until `kickstart` or the next login.
9. Safety net, panel closed: built-in off from the panel, close the panel, unplug the Dell. The built-in display comes back without input; the log shows a `reconfiguration` trigger. Over HDMI; USB-C if available.
10. Startup recovery: Quit the app; turn the built-in off with the CLI. Start the fallback with `--kickstart-after 20`, then unplug the Dell within 10 s. Zero active is established before the kickstart starts the app. The built-in display comes back; the log shows a `launch` trigger and no earlier `reconfiguration` episode.
11. Wake recovery: built-in off, Dell attached; close the lid; unplug the Dell (the Mac sleeps); wait 10 s; open the lid. The built-in display comes back within 10 s of opening; the log shows which trigger started the episode, and the step passes only if it is `wake` or a `reconfiguration` stamped after the wake.
12. Login: log out and in; the icon appears without manual start.

## 9. Risks and open questions

- **Reboot** restores a disabled display (D-010), so a reboot remains a last resort when the app is not running.
- **`MenuBarExtra` from a bare executable.** Unverified that a SwiftPM executable without an app bundle shows a `MenuBarExtra` under launchd. The plan starts with a spike; the fallback is a minimal `.app` bundle (Info.plist with `LSUIElement`) assembled by the install script. If both fail, work stops and the owner decides which requirement changes.
- **Lid closed.** A MacBook with its lid closed and no external display sleeps, so "lid closed, awake, no display" does not occur; recovery runs on wake (hardware step 11).
- **Phase 3 brightness keys** will be a second source of brightness changes in the same process. Ordering between keys and slider is left to Phase 3 (tracked).
- **DDC from two processes.** The CLI and the slider can write DDC at the same time; there is no cross-process DDC lock. Accepted: the last write wins, and the owner drives both.

## 10. Left to the builder

- Exact SwiftUI layout, spacing and captions within §6.1.
- Settle period and retry counts, within the defaults above.
- Whether the last-read brightness is cached across panel openings.

## 11. Acceptance criteria

Phase 2 is complete when:
- The package builds and all automated tests pass on the target Mac.
- Hardware steps 1–12 in §8 pass, recorded in README with dates.
- The README documents install, uninstall, Quit and restart, and recovery.
- Design and plan match the code; `decisions.md` holds any deviation.
