# displayctl

`displayctl` is a Phase 1 command-line tool for inspecting macOS displays, safely
soft-connecting or soft-disconnecting them, and controlling compatible external
monitors through hardware DDC/CI brightness commands. It targets an Apple
Silicon M5 Mac running macOS Tahoe 26.5 and requires Swift 6.2 or newer.

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

## Build and test

```sh
swift build
swift test
.build/debug/displayctl --help
```

In a restricted sandbox, SwiftPM's user caches can stall or be unavailable. Use
local temporary caches and disable SwiftPM's own sandbox:

```sh
env \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/displaycontrol-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/displaycontrol-clang-cache \
  swift test --disable-sandbox --scratch-path /tmp/displaycontrol-build
```

Use the same environment with `swift build` in place of `swift test` when the
build itself needs the workaround.

## CLI usage

```text
displayctl --help
displayctl list [--json]
displayctl connect <selector>
displayctl connect all
displayctl disconnect <selector>
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

If testing is interrupted or a display remains soft-disconnected, reconnect all
physically present displays exposed by macOS:

```sh
.build/debug/displayctl connect all
```

The command reports each attempted recovery independently. If the current shell
cannot see displays, log out and back in; session-scoped changes revert at that
boundary. Keep `connect all` available from another terminal or remote shell
during manual testing.

## Hardware validation

Run the opt-in test only from an interactive terminal on the target Mac with an
internal display and HDMI monitor attached:

```sh
Scripts/hardware-test.sh
```

The script builds once, prints the initial JSON inventory, accepts only UUIDs
present in the internal/external inventory groups, and requires exact typed
confirmation before every brightness or connection mutation. Its exit/signal
trap attempts `connect all`; it never uses a force override. USB-C recabling and
logout/login remain manual because automating them would be unsafe or impossible.

Hardware validation has **not yet been executed in an interactive user session**.
No item below should be read as a pass. During Task 10, record observed evidence
for every item rather than converting unrun checks into successes:

- [ ] Build completes on the Tahoe 26.5 M5 target.
- [ ] Automated tests pass on the target.
- [ ] Interactive `list` shows internal and HDMI displays with stable UUIDs.
- [ ] HDMI brightness get succeeds, or unsupported read-back is recorded.
- [ ] HDMI brightness set is visually confirmed on the physical monitor.
- [ ] The external display disconnects and reconnects.
- [ ] The internal display disconnects and reconnects.
- [ ] Disconnecting the final active display is refused with a nonzero exit.
- [ ] USB-C DDC is manually tested after recabling and its result is recorded.
- [ ] Logout/login restores session-scoped connection state.
- [ ] Manual `displayctl connect all` recovery restores available displays.

After the scripted checks, manually reconnect the monitor over USB-C, run `list`,
then try `brightness get` and a carefully confirmed `brightness set`; record
supported or unsupported without expecting a fallback. Finally, test logout/login
recovery and run `connect all` once manually.

## Roadmap

Phase 1 covers the CLI, display inventory/selection, safe session-scoped
connection changes, external hardware brightness, automated tests, and hardware
validation. Phase 2 is separately gated work for mouse-targeted keyboard
brightness handling and automatic recovery from zero active displays. Phase 3
is a separately designed native menu-bar interface. Neither later phase is part
of this implementation.
