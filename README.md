# displayctl

`displayctl` is a Phase 1 command-line tool for inspecting macOS displays, safely
soft-connecting or soft-disconnecting them, and controlling compatible external
monitors through hardware DDC/CI brightness commands. It targets an Apple
Silicon M5 Mac running macOS 27 (first built for Tahoe 26.5) and requires Swift 6.2 or newer.

> [!WARNING]
> Display connection and DDC access use undocumented private macOS APIs. Apple
> may change or remove them in any macOS update. This project is currently for
> local, personal builds; open-source or wider distribution would first require
> a supported-version matrix, compatibility testing, signing/notarization work,
> and appropriate licensing review. Mac App Store distribution is not expected
> to be viable. Keep a recovery path available whenever testing display changes.

The executable is self-contained and has no BetterDisplay runtime dependency.
It does not copy BetterDisplay implementation details. Brightness operations use
monitor hardware DDC/CI only: there is no software gamma or overlay fallback.

## Install

```sh
swift build -c release
cp .build/release/displayctl ~/.local/bin/   # any directory on your PATH
```

Rebuild and copy again after pulling changes.

## Everyday use

```sh
displayctl list                          # displays, their UUIDs and state
displayctl disconnect internal           # turn off the built-in screen
displayctl connect internal              # turn it back on
displayctl brightness get external       # read the monitor's brightness
displayctl brightness set external 40    # set it, 0 to 100
```

A disconnected display disappears from `list`; `displayctl` remembers it, so `connect internal` still works. The last active display is never turned off. Logging out does not bring a display back on macOS 27.

If a screen does not come back:

1. Run `displayctl connect all`.
2. Reboot only as a last resort. A reboot brings the display back.

Brightness works over HDMI and USB-C on a Dell U2720Q (macOS 27.0.1). Other monitors need DDC/CI enabled in their own menu.

## Menu bar app

`displayctl-menu` puts a display icon in the menu bar. It starts at login as a LaunchAgent.

```sh
Scripts/install-menu.sh     # build, install, start
Scripts/uninstall-menu.sh   # stop and remove the LaunchAgent
```

`install-menu.sh` builds release, copies `displayctl-menu` and `displayctl` to `~/.local/bin/`, writes `~/Library/LaunchAgents/com.github.duncandoyle.displayctl-menu.plist` and starts it. It installs the CLI too, so both run the same build. Run it again after pulling changes. `uninstall-menu.sh` stops the app and removes the plist. It keeps both binaries and the ledger.

The panel lists each display with an on/off switch. The switch of the last active display is disabled. External monitors with DDC/CI get a brightness slider. A failure shows one line under its row. The app and the CLI share the ledger and the lock, so a CLI change shows up in the panel.

Quit stops the app until the next login. To start it sooner:

```sh
launchctl kickstart gui/$(id -u)/com.github.duncandoyle.displayctl-menu
```

If it crashes, launchd restarts it. Logs:

```sh
log show --predicate 'subsystem == "displayctl"' --last 1h
```

Safety net: when no usable display is active (the macOS placeholder does not count), at launch, after a display change, after wake, and every 10 s while a display it turned off is in the saved list, the app turns displays that `displayctl` turned off back on, up to 3 attempts. The check and the reconnect happen under the same lock as the CLI. It never turns a display off and never starts while a usable display is active; once it starts at zero it may turn on every display it can, like `connect all`. After an attempt run that ends without a usable display (3 failed attempts, or a display list that kept changing) it waits 60 s; a wake ends the wait. When it finds a usable display active, it also clears saved entries for displays that are already on.

After an undock, macOS may show a placeholder display with no name. `displayctl` ignores it, and `list` notes it on standard error.

## Build and test

```sh
swift build
swift test
.build/debug/displayctl --help
```

## CLI usage

```text
displayctl --help
displayctl list [--json]
displayctl connect <selector>
displayctl connect all
displayctl disconnect <selector>
displayctl forget <uuid|all>
displayctl brightness get <selector>
displayctl brightness set <selector> <0...100>
```

Canonical selectors are a stable display UUID or the current decimal runtime
display ID. `internal` and `external` are convenience selectors and work only
when exactly one display of that kind matches. Display names are informational,
not selectors. `all` is accepted only by `connect all`. For `connect`, the candidates for `internal` or `external` are the inactive displays of that kind plus displays of that kind that `displayctl` turned off; exactly one must match, so with two external monitors use the UUID.

```sh
.build/debug/displayctl list
.build/debug/displayctl list --json
.build/debug/displayctl disconnect 37D8832A-2D66-02CA-B9F7-8F30A301B230
.build/debug/displayctl connect 37D8832A-2D66-02CA-B9F7-8F30A301B230
.build/debug/displayctl brightness get external
.build/debug/displayctl brightness set 2 45
.build/debug/displayctl connect all
```

`list` reports UUID, runtime ID, name, internal/external kind, online/active/main
state, and DDC capability. A headless shell may validly return an empty list
because Core Graphics inventory is login-session scoped. That is not hardware
acceptance: interactive validation requires both the internal display and a
physically connected external display to appear with stable UUIDs.

Connection changes use the session configuration option, but on macOS 27 they survive logout/login (D-008). A reboot undoes them (D-010).
Disconnect refuses to remove the last active display.
A cross-process lock serializes connection operations so simultaneous CLI
processes cannot both pass the last-active check against stale state. There is
no `--force` option.

Brightness commands accept external displays only. `candidate` means a plausible
DDC service exists; only a successful operation confirms support. Reads can fail
on monitors that accept writes. Failures never produce an invented value and
never fall back to software dimming.

## Errors, exits, and recovery

Errors are written to standard error. The main exit categories are:

- `0`: command completed successfully.
- `64`: invalid command, selector syntax, or brightness value.
- `69`: required private API or usable DDC service is unavailable/unsupported.
- `75`: temporary failure, try again: DDC timeout, transport failure or invalid reply; another `displayctl` holds the lock; the display setup kept changing while it was read.
- `1`: other selection, state, safety, configuration, response, or verification
  failure, including last-active-display refusal.

### Disabled-display ledger

macOS can drop a soft-disabled display from its online display list. `connect` alone could then never find it again. So `displayctl` keeps a ledger of every display it disables, in `~/Library/Application Support/displayctl/` next to the operation lock.

- `disconnect` records the display's UUID, runtime ID, name and boot session in the ledger before it touches the display. If the ledger cannot be written, the display is left alone and the command fails.
- `connect <selector>` and `connect all` look up the UUID first. If macOS lists the UUID online, its current runtime ID is used, even if the ID changed.
- A display macOS no longer lists is enabled by its recorded runtime ID only if the entry is from the current boot and no other display holds that ID. Otherwise it is skipped and reported.
- An entry is removed once its UUID is verified active again, or by `forget`.
- `forget <uuid|all>` removes ledger entries without touching any display. Use it for a monitor that is unplugged for good, so `connect all` stops reporting it as a failure.

On macOS 27 a disabled display disappears from `list`, and `disconnect` counts that as success (D-005). `list` then names it only in a note on standard error, read from the ledger.

### Recovery

If testing is interrupted or a display stays dark, recover in this order:

1. Run `.build/debug/displayctl connect all`, from another terminal if needed. It tries every online inactive display and every ledger entry, and reports each result. It exits nonzero if anything failed, including an unreadable ledger, but it still tries the online displays. Repeat it if another `displayctl` holds the lock.
2. Check the result with `.build/debug/displayctl list`.
3. If a display is still missing, reboot; that brings it back (D-010). Logout/login does not help (D-008).

If `connect all` or the menu bar app reports the ledger as unreadable, look at the file:

```sh
cat ~/Library/Application\ Support/displayctl/disabled-displays.json
```

Each entry names a display that `displayctl` turned off. Neither the CLI nor the app rewrites an unreadable file. `displayctl forget all` resets it to empty. Run it only once every display that was turned off is back on: it deletes the record that `connect` needs to find them.

A remote shell helps only if it can list the GUI session's displays. A headless shell may see none.

After a macOS update, check that the placeholder rule still holds (D-013):

```sh
DISPLAYCTL_DEBUG=1 displayctl list
```

It prints one `debug:` line per display on standard error, with the raw vendor, model and serial numbers and whether `displayctl` counts it as the placeholder. The placeholder has vendor 1970170734 (`unkn`), model 1986622068 (`virt`) and serial 0. If a real display matches, or the placeholder no longer does, the rule needs an update.

## Hardware validation

Run the opt-in test only from an interactive terminal on the target Mac, with the internal display and one HDMI monitor attached:

```sh
Scripts/hardware-test.sh
```

The script builds `displayctl`, prints the initial inventory, and accepts only UUIDs from that inventory. Every brightness change and every disconnect needs its own exact typed confirmation. There is no force option. Logs go to `~/Library/Logs/displayctl-hardware-test/`.

### Watchdog

Before each disconnect the script starts a detached watchdog. It runs in its own process group, so Ctrl-C, a closed terminal or a killed script do not stop it.

- The watchdog runs every display change itself. The script only sends it requests. So the watchdog knows about each disconnect before it starts, knows when it ends, and can stop it.
- After each disconnect you must type `YES` within 20 seconds to confirm a usable screen. Without it, or if the script dies, the watchdog fires. A `YES` that arrives after the deadline does not count.
- If the watchdog itself dies, the script restores the displays. It first waits for any running `displayctl` to finish, and stops it at its time limit.
- When it fires, it stops any running `displayctl` (TERM, then KILL), waits until that process is gone, and only then reads the active displays. It retries `connect all` until the original set is active or a 90-second deadline passes. Every `list` and `connect all` call counts toward that deadline.
- Firing ends the run. No later disconnect is accepted, and a new disconnect needs a fresh run and a fresh opt-in.
- The watchdog disarms only after it has verified the original displays are active.

### Test order

1. Brightness get and set on the HDMI monitor.
2. Internal session-scoped disconnect, screen confirmation, then reconnect by UUID, with the watchdog armed.
3. Unattended run. This is a separate run of `Scripts/hardware-test.sh`, done after a run that passed steps 1 and 2. Repeat step 1. At step 2, type the `DISCONNECT INTERNAL` line, then withhold the `YES` for the screen confirmation. The watchdog must fire within 20 seconds and restore a usable screen. Firing ends that run. Record the result, then start a fresh run for step 4.
4. External opt-in, in a fresh run after steps 1 and 2 pass again. You type a separate sentence; anything else skips all external steps.
5. External session-scoped disconnect and reconnect by UUID, with the watchdog armed. No OS safety net exists here (D-006). If the display does not come back, run `connect all`, then reboot.
6. Final-display refusal: each other display is disconnected with its own confirmation, then the script checks that disconnecting the internal display is refused.

USB-C recabling and logout/login stay manual.

### Results on macOS 27

Target: macOS 27.0.1 (D-002). Record observed evidence for each item. An unrun check is not a pass. After a macOS update, run the matrix again, including the logout and reboot checks: they show what undoes a disconnect, and the code relies on that.

- [x] Build completes on the target — observed 2026-11-23 (macOS 27.0.1).
- [x] Automated tests pass on the target (final count in docs/phase-status.md) — observed 2026-11-23 (macOS 27.0.1).
- [x] Interactive `list` shows internal and HDMI displays with stable UUIDs — observed 2026-11-23 (macOS 27.0.1).
- [x] HDMI brightness get succeeds (read 10 and 30) — observed 2026-11-23 (macOS 27.0.1).
- [x] HDMI brightness set is visually confirmed on the physical monitor — observed 2026-11-23 (macOS 27.0.1) with single sends, and again on 2026-11-25 with the doubled sends (owner, installed binary built after the change).
- [x] Watchdog restored the internal display from the ledger after it left the online list — observed 2026-11-23 (macOS 27.0.1).
- [x] Internal session disconnect and reconnect, with the watchdog armed — observed 2026-11-23 (macOS 27.0.1).
- [x] A watchdog timeout restored a usable screen: in run 4 (USB-C) the final YES was withheld, and the watchdog restored the Dell from the ledger 20 s later — observed 2026-11-23 (macOS 27.0.1). It ran at the end of the external steps, not as a separate run before them.
- [x] External disconnect and reconnect over HDMI: the Dell left the online list and `connect <uuid>` restored it from the ledger — observed 2026-11-23 (macOS 27.0.1). Claim support only if recovery of a display that macOS dropped from the online list was observed; otherwise record it as unsupported (D-006).
- [x] Disconnecting the final active display is refused with a nonzero exit — observed 2026-11-23 (macOS 27.0.1).
- [x] USB-C: brightness get and set work once DDC requests are sent twice; disconnect and reconnect of the Dell work — observed 2026-11-23 (macOS 27.0.1).
- [x] Logout/login does not restore a disabled display: the built-in display stayed off through logout and login (D-008) — observed 2026-11-25 (macOS 27.0.1).
- [x] Manual `displayctl connect all` restored the built-in display from the ledger after that login, exit 0 — observed 2026-11-25 (macOS 27.0.1).
- [x] A reboot restores a disabled display: the built-in display came back after a reboot; a later `connect all` removed the leftover ledger entry, exit 0 (D-010) — observed 2026-11-26 (macOS 27.0.1).

After the scripted steps, reconnect the monitor over USB-C, run `list`, then `brightness get` and a carefully confirmed `brightness set`. Record supported or unsupported; there is no fallback. Then disconnect the internal display, log out and back in, and run `connect all` once by hand.

### Results on macOS 27 — menu bar app (Phase 2)

The steps are in `docs/phases/phase-2/design.md` §8. All were observed on 2026-11-26 on macOS 27.0.1, with the Dell U2720Q over USB-C unless a step says HDMI. Before each step that could leave no display on, a detached fallback outside the app was armed.

- [x] 1–5: install, panel, switches, the disabled last-active switch and the brightness slider work.
- [x] 6: a CLI `disconnect internal` shows up in the open panel. The first run found each CLI change took 10 s; the cause was a main-thread call for display names. Observed again with the fix.
- [x] 7–8: launchd restarts the app after `kill -9`; after Quit it stays stopped.
- [x] Placeholder finding: step 9 first failed three times. About 6 s after the unplug, macOS adds a placeholder display, so no moment with zero active displays came (D-012). Its size and mode differ per process, so `displayctl` now detects it by vendor, model and serial only (D-013).
- [x] Fallback only, app stopped, placeholder as main display: the fallback brought the built-in back 6 s after it went dark.
- [x] 9: safety net after an unplug, over USB-C. The app brought the built-in back about 2.5 s after the unplug, started by a `reconfiguration` trigger.
- [x] 10: startup recovery. `kickstart` ran 5 s after the screen went dark; the app recovered by its `launch` trigger, and the built-in was back 9 s after dark.
- [x] 11: wake recovery, passed by another route. The app's enable attempts with the lid closed failed, because the panel cannot light with the lid shut, but they left it enabled. macOS lit it when the lid opened, and the wake check found it active.
- [x] 9 over HDMI: the app brought the built-in back about 3 s after the screen went dark, started by a `reconfiguration` trigger, on its first attempt; the fallback did nothing. The same session read the Dell over HDMI: `brightness get external` returned 20/100, exit 0.
- [x] 9b: periodic check alone (D-014), with display, wake and launch triggers off (`DISPLAYCTL_MENU_NO_EVENTS=1`). The log shows an episode started by `tick`; the built-in was back within 1 s of going dark, because a check happened to run right then.
- [x] 12: after logout and login, the icon appeared without a manual start.

### History: macOS 26.5, 2026-06-30

A partial run on macOS Tahoe 26.5, with the built-in display and a Dell U2720Q over HDMI. It is not evidence for macOS 27.

- [x] Build completed on the M5 target.
- [x] Interactive `list` showed internal and HDMI displays with stable UUIDs.
- [x] HDMI brightness get succeeded.
- [x] HDMI brightness set was visually confirmed.
- [ ] External disconnect and reconnect: `disconnect` returned `postconditionFailed` because the disabled display disappeared from the inventory. The exit trap's `connect all` did not restore it, and neither did unplugging and replugging HDMI. Only a reboot did. USB-C still worked afterwards.
- Not run: internal disconnect, final-display refusal, USB-C DDC, logout/login, manual `connect all`.

## Roadmap

Phase 1 covers the CLI, display inventory and selection, safe connection changes, external hardware brightness, automated tests, and hardware validation.

Phase 2 is a menu bar app with an on/off switch per display, a brightness slider for DDC-capable external displays, and automatic recovery when no display is active (D-009). Phase 3 is the keyboard brightness agent, where the brightness keys follow the mouse pointer. Neither later phase is part of this implementation.
