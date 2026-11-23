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

A disconnected display disappears from `list`; `displayctl` remembers it, so `connect internal` still works. The last active display is never turned off. Logging out should restore every display; that is not yet verified on macOS 27.

If a screen does not come back:

1. Run `displayctl connect all`.
2. Log out and back in.
3. Reboot only as a last resort.

Brightness works over HDMI and USB-C on a Dell U2720Q (macOS 27.0.1). Other monitors need DDC/CI enabled in their own menu.

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
not selectors. `all` is accepted only by `connect all`.

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

Connection changes are scoped to the current login session and intentionally
revert after logout/login. Disconnect refuses to remove the last active display.
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
- `75`: temporary DDC timeout or transport failure.
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
3. If a display is still missing, log out and log back in. Session-scoped changes revert at logout.
4. Reboot only if logout and login did not bring it back.

A remote shell helps only if it can list the GUI session's displays. A headless shell may see none.

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
5. External session-scoped disconnect and reconnect by UUID, with the watchdog armed. No OS safety net exists here (D-006). If the display does not come back, run `connect all`, then log out and in, then reboot.
6. Final-display refusal: each other display is disconnected with its own confirmation, then the script checks that disconnecting the internal display is refused.

USB-C recabling and logout/login stay manual.

### Results on macOS 27

Target: macOS 27.0.1 (D-002). Record observed evidence for each item. An unrun check is not a pass. Only the item marked done has been observed on macOS 27.

- [x] Build completes on the target — observed 2026-11-23 (macOS 27.0.1).
- [x] Automated tests pass on the target (146 tests) — observed 2026-11-23 (macOS 27.0.1).
- [x] Interactive `list` shows internal and HDMI displays with stable UUIDs — observed 2026-11-23 (macOS 27.0.1).
- [x] HDMI brightness get succeeds (read 10 and 30) — observed 2026-11-23 (macOS 27.0.1).
- [x] HDMI brightness set is visually confirmed on the physical monitor — observed 2026-11-23 (macOS 27.0.1).
- [x] Watchdog restored the internal display from the ledger after it left the online list — observed 2026-11-23 (macOS 27.0.1).
- [x] Internal session disconnect and reconnect, with the watchdog armed — observed 2026-11-23 (macOS 27.0.1).
- [ ] One unattended watchdog timeout restores a usable screen.
- [x] External disconnect and reconnect over HDMI: the Dell left the online list and `connect <uuid>` restored it from the ledger — observed 2026-11-23 (macOS 27.0.1). Claim support only if recovery of a display that macOS dropped from the online list was observed; otherwise record it as unsupported (D-006).
- [x] Disconnecting the final active display is refused with a nonzero exit — observed 2026-11-23 (macOS 27.0.1).
- [ ] USB-C DDC is tested after recabling and the result is recorded.
- [ ] Logout/login restores session-scoped connection state.
- [ ] Manual `displayctl connect all` restores available displays.

After the scripted steps, reconnect the monitor over USB-C, run `list`, then `brightness get` and a carefully confirmed `brightness set`. Record supported or unsupported; there is no fallback. Then test logout/login and run `connect all` once by hand.

### History: macOS 26.5, 2026-06-30

A partial run on macOS Tahoe 26.5, with the built-in display and a Dell U2720Q over HDMI. It is not evidence for macOS 27.

- [x] Build completed on the M5 target.
- [x] Interactive `list` showed internal and HDMI displays with stable UUIDs.
- [x] HDMI brightness get succeeded.
- [x] HDMI brightness set was visually confirmed.
- [ ] External disconnect and reconnect: `disconnect` returned `postconditionFailed` because the disabled display disappeared from the inventory. The exit trap's `connect all` did not restore it, and neither did unplugging and replugging HDMI. Only a reboot did. USB-C still worked afterwards.
- Not run: internal disconnect, final-display refusal, USB-C DDC, logout/login, manual `connect all`.

## Roadmap

Phase 1 covers the CLI, display inventory/selection, safe session-scoped
connection changes, external hardware brightness, automated tests, and hardware
validation. Phase 2 is separately gated work for mouse-targeted keyboard
brightness handling and automatic recovery from zero active displays. Phase 3
is a separately designed native menu-bar interface. Neither later phase is part
of this implementation.
