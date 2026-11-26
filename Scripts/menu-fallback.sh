#!/bin/bash
# Independent fallback for the Phase 2 hardware tests (design §8). Runs detached, logs every
# change in the active-display count and, once no display is active, can start the menu app
# and later retries `displayctl connect all` until a display is active or a deadline passes.
# Written for macOS /bin/bash 3.2.
set -euo pipefail

KICKSTART_AFTER=""
CONNECT_ALL_AFTER=30
DEADLINE=90
DISPLAYCTL="$HOME/.local/bin/displayctl"
LABEL="com.github.duncandoyle.displayctl-menu"
LOG_DIR="$HOME/Library/Logs/displayctl-menu-fallback"
# Proof mode: run connect all once even while a display is active, to show the detached
# process can restore a display in the GUI session.
EVEN_IF_ACTIVE=0
# Without a dark period within this many seconds the fallback exits.
WAIT_FOR_DARK=600

usage() {
  echo "usage: $0 [--even-if-active] [--kickstart-after S] [--connect-all-after S] [--deadline S] [--displayctl PATH]" >&2
  exit 64
}

CHILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kickstart-after) KICKSTART_AFTER="${2:?}"; shift 2 ;;
    --connect-all-after) CONNECT_ALL_AFTER="${2:?}"; shift 2 ;;
    --deadline) DEADLINE="${2:?}"; shift 2 ;;
    --displayctl) DISPLAYCTL="${2:?}"; shift 2 ;;
    --child) CHILD="${2:?}"; shift 2 ;;
    --even-if-active) EVEN_IF_ACTIVE=1; shift ;;
    *) usage ;;
  esac
done

now() { date +%s; }
# Runs a command with a time limit, so a hung command cannot hold up the deadline.
limit() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
stamp() { date '+%H:%M:%S'; }

# Seconds left to the hard deadline once no display is active; empty before that.
time_left() {
  if [ -n "${dark_at:-}" ]; then echo $(( dark_at + DEADLINE - $(now) )); fi
}

# Like limit, capped by the time left; does not start the command once the deadline has passed.
bounded() {
  local secs="$1" left
  shift
  left="$(time_left)"
  if [ -n "$left" ]; then
    if [ "$left" -le 0 ]; then return 124; fi
    if [ "$left" -lt "$secs" ]; then secs="$left"; fi
  fi
  limit "$secs" "$@"
}

# Number of displays `displayctl list` reports as active; -1 when list fails.
active_count() {
  local out
  if ! out="$(bounded 10 "$DISPLAYCTL" list 2>/dev/null)"; then
    echo -1
    return
  fi
  printf '%s\n' "$out" | awk -F '\t' 'NR > 1 && $6 == "true" { n++ } END { print n + 0 }'
}

run_child() {
  local log="$1" start last count elapsed dark_at="" t kicked=0
  echo $$ > "$log.pid"
  start="$(now)"
  last="unset"
  echo "$(stamp) fallback started (kickstart-after=${KICKSTART_AFTER:-none}, connect-all-after=$CONNECT_ALL_AFTER, deadline=$DEADLINE; times count from when no display is active)"
  # Ready only once displayctl answers, so a broken setup fails before the test starts.
  if [ "$(active_count)" = "-1" ]; then
    echo "$(stamp) displayctl list failed; fallback not ready."
    return 1
  fi
  : > "$log.ready"
  while :; do
    if [ -n "$dark_at" ] && [ "$(time_left)" -le 0 ]; then
      echo "$(stamp) dark+$(( $(now) - dark_at ))s deadline reached; giving up. Replug the external display or reboot."
      return 1
    fi
    elapsed=$(( $(now) - start ))
    count="$(active_count)"
    # Timers start at the zero reading, before the diagnostic list below can use its limit.
    if [ -z "$dark_at" ] && [ "$EVEN_IF_ACTIVE" -eq 0 ] && [ "$count" = "0" ]; then
      dark_at="$(now)"
      echo "$(stamp) no active display: timers start now"
    fi
    listing="$(bounded 10 "$DISPLAYCTL" list 2>&1 || true)"
    if [ "$listing" != "$last" ]; then
      echo "$(stamp) t=${elapsed}s active displays: $count"
      printf "%s\n" "$listing" | sed "s/^/$(stamp)   /"
      last="$listing"
    fi
    if [ "$EVEN_IF_ACTIVE" -eq 1 ]; then
      if [ "$elapsed" -ge "$CONNECT_ALL_AFTER" ]; then
        echo "$(stamp) proof mode: running connect all"
        limit 20 "$DISPLAYCTL" connect all 2>&1 | sed "s/^/$(stamp)   /" || true
        echo "$(stamp) active displays after: $(active_count). Done."
        return 0
      fi
      sleep 1
      continue
    fi
    if [ -z "$dark_at" ]; then
      if [ "$elapsed" -ge "$WAIT_FOR_DARK" ]; then
        echo "$(stamp) no display went dark within ${WAIT_FOR_DARK}s; fallback exits."
        return 0
      fi
      sleep 1
      continue
    fi
    t=$(( $(now) - dark_at ))
    if [ "$count" -gt 0 ]; then
      echo "$(stamp) a display is active again ${t}s after going dark. Done."
      return 0
    fi
    if [ -n "$KICKSTART_AFTER" ] && [ "$kicked" -eq 0 ] && [ "$t" -ge "$KICKSTART_AFTER" ]; then
      kicked=1
      echo "$(stamp) dark+${t}s kickstart $LABEL"
      bounded 10 launchctl kickstart "gui/$(id -u)/$LABEL" || echo "$(stamp) kickstart failed"
    fi
    if [ "$t" -ge "$CONNECT_ALL_AFTER" ]; then
      echo "$(stamp) dark+${t}s still no active display: running connect all"
      bounded 20 "$DISPLAYCTL" connect all 2>&1 | sed "s/^/$(stamp)   /" || true
    fi
    # Sleeps min(1, time left), so the loop does not run past the deadline.
    if [ "$(time_left)" -gt 0 ]; then sleep 1; fi
  done
}


if [ -n "$CHILD" ]; then
  run_child "$CHILD"
  exit $?
fi

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/run.$(date +%Y%m%d-%H%M%S).log"
# Own process group and nohup: survives a closed terminal and Ctrl-C, like the Phase 1 watchdog.
( set -m; nohup /bin/bash "$0" --child "$LOG" --connect-all-after "$CONNECT_ALL_AFTER" \
    --deadline "$DEADLINE" --displayctl "$DISPLAYCTL" \
    $( [ "$EVEN_IF_ACTIVE" -eq 1 ] && echo --even-if-active ) \
    ${KICKSTART_AFTER:+--kickstart-after "$KICKSTART_AFTER"} \
    >> "$LOG" 2>&1 < /dev/null & )
# The readiness probe may take its full 10 s list limit, so wait 12 s before reporting failure.
for _ in $(seq 1 120); do
  [ -e "$LOG.ready" ] && break
  sleep 0.1
done
if [ ! -e "$LOG.ready" ]; then
  echo "Fallback did not start; do not continue the test. Log: $LOG" >&2
  exit 1
fi
echo "Fallback armed (pid $(cat "$LOG.pid")). Log: $LOG"
