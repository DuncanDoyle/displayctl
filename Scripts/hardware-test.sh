#!/bin/bash
# Interactive hardware validation for displayctl. Written for macOS /bin/bash 3.2.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_PATH")")"

# Timeouts in whole seconds; override via env to test with a stub displayctl.
CONFIRM_TIMEOUT="${HARDWARE_TEST_CONFIRM_TIMEOUT:-20}"
ARMED_MAX="${HARDWARE_TEST_ARMED_MAX:-300}"
RESTORE_DEADLINE="${HARDWARE_TEST_RESTORE_DEADLINE:-90}"
RETRY_INTERVAL="${HARDWARE_TEST_RETRY_INTERVAL:-2}"
PROMPT_TIMEOUT="${HARDWARE_TEST_PROMPT_TIMEOUT:-60}"
CMD_TIMEOUT="${HARDWARE_TEST_CMD_TIMEOUT:-60}"
DISARM_SETTLE="${HARDWARE_TEST_DISARM_SETTLE:-5}"
KILL_GRACE="${HARDWARE_TEST_KILL_GRACE:-3}"
KILL_WAIT="${HARDWARE_TEST_KILL_WAIT:-2}"
export HARDWARE_TEST_CONFIRM_TIMEOUT="$CONFIRM_TIMEOUT" HARDWARE_TEST_ARMED_MAX="$ARMED_MAX" \
  HARDWARE_TEST_RESTORE_DEADLINE="$RESTORE_DEADLINE" HARDWARE_TEST_RETRY_INTERVAL="$RETRY_INTERVAL" \
  HARDWARE_TEST_CMD_TIMEOUT="$CMD_TIMEOUT" HARDWARE_TEST_DISARM_SETTLE="$DISARM_SETTLE" \
  HARDWARE_TEST_KILL_GRACE="$KILL_GRACE" HARDWARE_TEST_KILL_WAIT="$KILL_WAIT"
# Longest time stopping one process can take.
ESCALATION=$(( KILL_GRACE + KILL_WAIT ))

log() {
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"
}

now() {
  date +%s
}

min() {
  if (( $1 < $2 )); then echo "$1"; else echo "$2"; fi
}

# Succeeds while pid $1 exists and is not a zombie; a zombie can no longer change displays.
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]
}

# Succeeds while pid $1 is a running displayctl, so a reused pid is never mistaken for a worker.
worker_running() {
  [[ -n "$1" ]] && alive "$1" && ps -o command= -p "$1" 2>/dev/null | grep -Fq -- "$DISPLAYCTL"
}

# Sends TERM to every descendant of pid $1, deepest first.
term_descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    term_descendants "$child"
    kill -TERM "$child" 2>/dev/null || true
  done
}

# Sends TERM, then KILL after KILL_GRACE seconds; fails if the process outlives KILL_WAIT more.
stop_pid() {
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null || return 0
  for (( i = 0; i < KILL_GRACE * 5; i++ )); do
    alive "$pid" || return 0
    sleep 0.2
  done
  kill -KILL "$pid" 2>/dev/null || return 0
  for (( i = 0; i < KILL_WAIT * 5; i++ )); do
    alive "$pid" || return 0
    sleep 0.2
  done
  return 1
}

# Runs a command with stdin closed and stops it after $1 seconds (exit 124).
run_bounded() {
  local limit_ticks=$(( $1 * 5 )) ticks=0 pid
  shift
  (( limit_ticks > 0 )) || return 124
  "$@" </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( ticks >= limit_ticks )); then
      if stop_pid "$pid"; then wait "$pid" 2>/dev/null || true; fi
      return 124
    fi
    sleep 0.2
    ticks=$(( ticks + 1 ))
  done
  wait "$pid"
}

# Prints the sorted active UUIDs; `list` is stopped after $1 seconds.
active_uuids() {
  local json
  json="$(run_bounded "$1" "$DISPLAYCTL" list --json)" || return 1
  printf '%s\n' "$json" | jq -r 'if type == "array" then .[] | select(.isActive) | .uuid else error("not an array") end' \
    | sort
}

# Succeeds when every UUID listed in file $1 is active; `list` is stopped after $2 seconds.
originals_active() {
  local current uuid
  current="$(active_uuids "$2")" || return 1
  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue
    printf '%s\n' "$current" | grep -Fqx -- "$uuid" || return 1
  done < "$1"
}

# Retries `connect all` until the UUIDs in $1 are active or $2 seconds pass, every call included.
# A live worker pid $3 blocks success: the active set is only read once that worker is gone.
restore_loop() {
  local originals="$1" end=$(( $(now) + $2 )) worker="${3:-}" attempt=0 remaining output rc
  while true; do
    remaining=$(( end - $(now) - ESCALATION ))
    if (( remaining < 1 )); then
      log "Hard deadline reached; originally active displays are not all active."
      return 1
    fi
    if worker_running "$worker"; then
      log "displayctl worker $worker is still running; the active set is not read until it is gone."
    elif originals_active "$originals" "$(min "$CMD_TIMEOUT" "$remaining")"; then
      log "Restored: every originally active display is active."
      return 0
    else
      remaining=$(( end - $(now) - ESCALATION ))
      if (( remaining >= 1 )); then
        attempt=$(( attempt + 1 ))
        rc=0
        output="$(run_bounded "$(min "$CMD_TIMEOUT" "$remaining")" "$DISPLAYCTL" connect all 2>&1)" || rc=$?
        log "connect all attempt $attempt exited $rc: $(printf '%s' "$output" | tr '\n' ' ')"
      fi
    fi
    remaining=$(( end - $(now) ))
    if (( remaining > 0 )); then sleep "$(min "$RETRY_INTERVAL" "$remaining")"; fi
  done
}

# ---- Watchdog: a detached supervisor that runs every display mutation as its own child. ----

wd_write() { # $1 file name, $2 content; atomic for readers in the other process.
  printf '%s\n' "$2" > "$WD_STATE/$1.tmp" && mv -f "$WD_STATE/$1.tmp" "$WD_STATE/$1"
}

# Starts request $1 as a worker; a disconnect is refused once any watchdog of this run has fired.
wd_start() {
  local seq="$1" line args=()
  {
    IFS= read -r WORKER_TIMEOUT
    while IFS= read -r line; do args+=("$line"); done
  } < "$WD_STATE/req.$seq"
  if [[ "${args[0]}" == "disconnect" ]]; then
    if [[ -e "$RUN_FIRED" ]]; then
      wd_write "res.$seq" refused
      log "Request $seq refused: a watchdog of this run has fired."
      return 0
    fi
    # Each disconnect needs a fresh confirmation.
    rm -f "$WD_STATE/confirmed"
    wd_write confirm_by $(( $(now) + FIRE_AFTER ))
  fi
  "$DISPLAYCTL" "${args[@]}" < /dev/null > "$WD_STATE/out.$seq" 2>&1 &
  WORKER=$!
  WORKER_SEQ="$seq"
  WORKER_DEADLINE=$(( $(now) + WORKER_TIMEOUT ))
  # The test script's own recovery reads this if the watchdog is gone.
  wd_write worker "$WORKER $WORKER_DEADLINE"
  log "Request $seq: started displayctl ${args[*]} as pid $WORKER, limit ${WORKER_TIMEOUT}s."
}

# Succeeds when the confirmation's timestamp is before the deadline; a late one never counts.
wd_confirmed() {
  local at
  at="$(cat "$WD_STATE/confirmed" 2>/dev/null)" || return 1
  [[ "$at" =~ ^[0-9]+$ ]] && (( at < $(cat "$WD_STATE/confirm_by") ))
}

# Sets REASON and succeeds when the watchdog must fire now.
wd_must_fire() {
  if [[ -e "$WD_STATE/fire" ]]; then
    REASON="the test script requested recovery"
  elif ! kill -0 "$FG_PID" 2>/dev/null; then
    REASON="the test script is gone"
  elif [[ -n "$WORKER" ]] && (( $(now) >= WORKER_DEADLINE )); then
    REASON="request $WORKER_SEQ ran past its ${WORKER_TIMEOUT}s limit"
  elif ! wd_confirmed && (( $(now) >= $(cat "$WD_STATE/confirm_by") )); then
    REASON="no confirmation in time"
  elif (( $(now) - ARMED_AT >= ARMED_MAX )); then
    REASON="still armed after ${ARMED_MAX}s"
  else
    return 1
  fi
}

# Verifies the original active set for a disarm, with no worker running.
# Returns 2 if a firing condition comes up meanwhile; each `list` runs in the background.
wd_verify() {
  local end=$(( $(now) + DISARM_SETTLE )) pid
  while true; do
    originals_active "$WD_STATE/originals" "$CMD_TIMEOUT" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if wd_must_fire; then
        term_descendants "$pid"
        stop_pid "$pid" && wait "$pid"
        return 2
      fi
      sleep 0.2
    done
    wait "$pid" && return 0
    (( $(now) >= end )) && return 1
    sleep 1
  done
}

# $1 state dir, $2 test script pid, $3 seconds allowed after each disconnect starts.
watchdog_main() {
  local seq=0 rc
  WD_STATE="$1"
  FG_PID="$2"
  FIRE_AFTER="$3"
  RUN_FIRED="$(dirname "$WD_STATE")/fired"
  WORKER=""
  REASON=""
  set +e
  trap '' HUP INT
  ARMED_AT=$(now)
  wd_write confirm_by $(( ARMED_AT + FIRE_AFTER ))
  wd_write pid "$$"
  log "Armed (pid $$, test script $FG_PID): fires ${FIRE_AFTER}s after a disconnect starts unless confirmed; disarm within ${ARMED_MAX}s."
  : > "$WD_STATE/ready"
  while true; do
    if [[ -n "$WORKER" ]] && ! kill -0 "$WORKER" 2>/dev/null; then
      wait "$WORKER"
      rc=$?
      rm -f "$WD_STATE/worker"
      wd_write "res.$WORKER_SEQ" "$rc"
      log "Request $WORKER_SEQ: exited $rc."
      WORKER=""
    fi
    wd_must_fire && break
    if [[ -z "$WORKER" && -e "$WD_STATE/disarm" ]]; then
      wd_verify
      case $? in
        0)
          : > "$WD_STATE/disarmed"
          log "Disarmed: every originally active display is verified active."
          exit 0 ;;
        1) REASON="the original displays were not all active at disarm" ;;
      esac
      break
    fi
    if [[ -z "$WORKER" && -e "$WD_STATE/req.$(( seq + 1 ))" ]]; then
      seq=$(( seq + 1 ))
      wd_start "$seq"
    fi
    sleep 0.2
  done
  # Firing is terminal for the whole run; nothing ever removes these markers.
  : > "$RUN_FIRED"
  : > "$WD_STATE/fired"
  log "Firing: $REASON. No further disconnect is accepted in this run."
  if [[ -n "$WORKER" ]]; then
    log "Stopping request $WORKER_SEQ (pid $WORKER) before reading the active set."
    if stop_pid "$WORKER"; then
      wait "$WORKER"
      rc=$?
      rm -f "$WD_STATE/worker"
      WORKER=""
    else
      rc=124
      log "pid $WORKER survived SIGKILL; recovery cannot be verified while it runs."
    fi
    wd_write "res.$WORKER_SEQ" "$rc"
  fi
  if [[ -e "$WD_STATE/req.$(( seq + 1 ))" ]]; then wd_write "res.$(( seq + 1 ))" refused; fi
  if restore_loop "$WD_STATE/originals" "$RESTORE_DEADLINE" "$WORKER"; then
    : > "$WD_STATE/restored"
    exit 0
  fi
  : > "$WD_STATE/failed"
  exit 1
}

if [[ "${1:-}" == "--watchdog" ]]; then
  DISPLAYCTL="${DISPLAYCTL:?DISPLAYCTL must be set for the watchdog}"
  watchdog_main "$2" "$3" "$4"
fi

# ---- Foreground test flow. ----

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "hardware-test.sh requires interactive stdin and stdout." >&2
  exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to parse 'displayctl list --json' (macOS ships /usr/bin/jq)." >&2
  exit 69
fi

if [[ -z "${DISPLAYCTL:-}" ]]; then
  echo "Building displayctl..."
  swift build --package-path "$REPO_ROOT"
  DISPLAYCTL="$REPO_ROOT/.build/debug/displayctl"
fi
export DISPLAYCTL

LOG_ROOT="${HARDWARE_TEST_LOG_DIR:-$HOME/Library/Logs/displayctl-hardware-test}"
mkdir -p "$LOG_ROOT"
RUN_DIR="$(mktemp -d "$LOG_ROOT/run.XXXXXX")"
INITIAL_ACTIVE_FILE="$RUN_DIR/initial-active"
MUTATION_STARTED=0
ARMED=0
WD_DIR=""
WD_PID=""
REQ_SEQ=0
OP_OUTPUT=""
UUID_PATTERN='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'

print_recovery_help() {
  cat >&2 <<EOF

RECOVERY NEEDED: not every display that was active came back.
  1. Run: "$DISPLAYCTL" connect all   (repeat it; another displayctl may hold the lock)
  2. Check: "$DISPLAYCTL" list
  3. Still missing? Log out and back in; session-scoped changes revert at logout.
  4. Reboot only if logout/login does not restore it.
Logs: $RUN_DIR
EOF
}

# Reads one line into ANSWER within $1 seconds; fails on timeout or EOF, and at once if $1 < 1.
ask() {
  ANSWER=""
  (( $1 >= 1 )) || return 1
  IFS= read -r -t "$1" ANSWER || { ANSWER=""; return 1; }
}

confirm_exact() {
  echo "Type exactly: $1"
  if ! ask "$PROMPT_TIMEOUT" || [[ "$ANSWER" != "$1" ]]; then
    echo "Confirmation did not match or timed out." >&2
    return 1
  fi
}

confirm_observed() {
  echo "$1 Type exactly YES only if you personally observed it:"
  if ask "$PROMPT_TIMEOUT" && [[ "$ANSWER" == "YES" ]]; then
    echo "Recorded user confirmation: $1"
  else
    echo "Validation failed: exact YES was not received in time." >&2
    return 1
  fi
}

wd_alive() {
  [[ -n "$WD_PID" ]] && kill -0 "$WD_PID" 2>/dev/null
}

# Ends the run once any watchdog has fired, or if the armed watchdog is gone.
check_watchdog() {
  if [[ -e "$RUN_DIR/fired" ]]; then
    echo "The watchdog fired; the disruptive sequence ends here." >&2
    echo "Another disconnect needs a fresh run of this script and a fresh opt-in." >&2
    exit 1
  fi
  if [[ "$ARMED" == 1 ]] && ! wd_alive; then
    echo "The watchdog stopped unexpectedly; ending the disruptive sequence." >&2
    exit 1
  fi
}

# Starts a detached watchdog; $1 is the seconds allowed after each disconnect starts.
arm_watchdog() {
  local fire_after="$1" i
  check_watchdog
  WD_DIR="$(mktemp -d "$RUN_DIR/watchdog.XXXXXX")"
  REQ_SEQ=0
  if ! active_uuids "$CMD_TIMEOUT" > "$WD_DIR/originals" || [[ ! -s "$WD_DIR/originals" ]]; then
    echo "Could not record the active display set; no disconnect attempted." >&2
    exit 1
  fi
  # Subshell, own process group and nohup: survives Ctrl-C, a closed terminal and a killed script.
  ( set -m; nohup /bin/bash "$SCRIPT_PATH" --watchdog "$WD_DIR" "$$" "$fire_after" \
      >> "$WD_DIR/watchdog.log" 2>&1 < /dev/null & )
  for (( i = 0; i < 50; i++ )); do
    [[ -e "$WD_DIR/ready" ]] && break
    sleep 0.1
  done
  WD_PID="$(cat "$WD_DIR/pid" 2>/dev/null || true)"
  if [[ ! -e "$WD_DIR/ready" ]]; then
    if [[ -n "$WD_PID" ]]; then kill "$WD_PID" 2>/dev/null || true; fi
    echo "The watchdog did not start; no disconnect attempted." >&2
    exit 1
  fi
  ARMED=1
  MUTATION_STARTED=1
  echo "Watchdog armed (log: $WD_DIR/watchdog.log). It runs each display change itself."
}

# Asks the watchdog to run `displayctl $2...` with a $1-second limit; output lands in OP_OUTPUT.
request_op() {
  local limit="$1" n end
  shift
  check_watchdog
  REQ_SEQ=$(( REQ_SEQ + 1 ))
  n=$REQ_SEQ
  OP_OUTPUT=""
  printf '%s\n' "$limit" "$@" > "$WD_DIR/req.$n.tmp"
  mv -f "$WD_DIR/req.$n.tmp" "$WD_DIR/req.$n"
  end=$(( $(now) + limit + ESCALATION + 5 ))
  while [[ ! -e "$WD_DIR/res.$n" ]]; do
    if { ! wd_alive || (( $(now) >= end )); } && [[ ! -e "$WD_DIR/res.$n" ]]; then
      echo "No result from the watchdog for: displayctl $*" >&2
      return 124
    fi
    sleep 0.2
  done
  OP_OUTPUT="$(cat "$WD_DIR/out.$n" 2>/dev/null || true)"
  if [[ "$(cat "$WD_DIR/res.$n")" == "refused" ]]; then
    echo "The watchdog refused: displayctl $*" >&2
    return 75
  fi
  return "$(cat "$WD_DIR/res.$n")"
}

# Asks the watchdog to verify the original set and exit; it fires instead if that fails.
disarm_watchdog() {
  local end=$(( $(now) + DISARM_SETTLE + CMD_TIMEOUT + ESCALATION + 5 ))
  : > "$WD_DIR/disarm"
  while wd_alive && (( $(now) < end )); do
    sleep 0.2
  done
  if [[ -e "$WD_DIR/disarmed" ]]; then
    ARMED=0
    return 0
  fi
  echo "The watchdog could not verify the original displays; it restores them and the run ends." >&2
  return 1
}

# Asks for proof of a usable screen before the watchdog's deadline for the last disconnect.
confirm_screen() {
  local deadline remaining at
  check_watchdog
  deadline="$(cat "$WD_DIR/confirm_by")"
  remaining=$(( deadline - $(now) ))
  echo "$1 Type YES within ${remaining}s, or displays are restored automatically:"
  if ask "$remaining" && [[ "$ANSWER" == "YES" ]]; then
    at=$(now)
    if (( at >= deadline )); then
      echo "YES arrived after the deadline; the watchdog restores displays and the run ends." >&2
      exit 1
    fi
    check_watchdog
    # The watchdog ignores a confirmation stamped at or after its deadline.
    printf '%s\n' "$at" > "$WD_DIR/confirmed.tmp" && mv -f "$WD_DIR/confirmed.tmp" "$WD_DIR/confirmed"
    check_watchdog
    echo "Screen confirmed. The watchdog stays armed until the original displays are verified active."
  else
    echo "No YES in time; ending the disruptive sequence." >&2
    exit 1
  fi
}

# Waits for the watchdog's last recorded worker until its deadline, then stops it.
# Prints the worker pid; fails if that worker is still running.
quiesce_worker() {
  local pid="" deadline=0
  if [[ -n "$WD_DIR" && -f "$WD_DIR/worker" ]]; then read -r pid deadline < "$WD_DIR/worker" || true; fi
  echo "$pid"
  worker_running "$pid" || return 0
  echo "displayctl worker $pid is still running; waiting until its deadline before reading displays..." >&2
  while worker_running "$pid" && (( $(now) < deadline )); do sleep 0.2; done
  worker_running "$pid" || return 0
  echo "Stopping displayctl worker $pid (TERM, then KILL)..." >&2
  stop_pid "$pid"
}

on_exit() {
  local status=$? end worker
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$MUTATION_STARTED" != 1 ]]; then
    exit "$status"
  fi
  echo ""
  if [[ "$ARMED" == 1 ]] && wd_alive; then
    echo "Recovery: the watchdog stops any running display change and restores every display that was active..."
    : > "$WD_DIR/fire"
    end=$(( $(now) + DISARM_SETTLE + CMD_TIMEOUT + 2 * ESCALATION + RESTORE_DEADLINE + 5 ))
    while wd_alive && (( $(now) < end )); do
      sleep 0.5
    done
  fi
  if [[ -e "$RUN_DIR/fired" ]]; then
    echo "The watchdog fired in this run. Another disconnect needs a fresh run and a fresh opt-in."
  fi
  if [[ -e "$WD_DIR/restored" || -e "$WD_DIR/disarmed" ]]; then
    echo "Recovery verified with list --json. Check every physically present display visually."
  else
    # No display is read while a worker may still run, whichever process recovers.
    worker="$(quiesce_worker)" || echo "displayctl worker $worker survived SIGKILL; recovery cannot be verified while it runs." >&2
    echo "Recovery: retrying connect all until every display active at the start is back..."
    if restore_loop "$INITIAL_ACTIVE_FILE" "$RESTORE_DEADLINE" "$worker"; then
      echo "Recovery verified with list --json. Check every physically present display visually."
    else
      print_recovery_help
      (( status == 0 )) && status=1
    fi
  fi
  exit "$status"
}

choose_uuid() {
  local kind="$1" choices="$2"
  echo "Available $kind stable UUID selectors:"
  echo "$choices"
  echo "Enter the exact $kind UUID to test:"
  ask "$PROMPT_TIMEOUT" || { echo "No UUID entered in time." >&2; return 1; }
  ANSWER="$(printf '%s' "$ANSWER" | tr '[:lower:]' '[:upper:]')"
  if [[ ! "$ANSWER" =~ $UUID_PATTERN ]]; then
    echo "A canonical UUID is required." >&2
    return 1
  fi
  if ! printf '%s\n' "$choices" | grep -Fqx -- "$ANSWER"; then
    echo "That UUID is not in the current $kind inventory group." >&2
    return 1
  fi
  REPLY="$ANSWER"
}

# Session-scoped disconnect and UUID reconnect of one display, both run by the watchdog.
session_round_trip() {
  local label="$1" uuid="$2"
  echo ""
  confirm_exact "DISCONNECT $label $uuid"
  arm_watchdog "$CONFIRM_TIMEOUT"
  if ! request_op "$CMD_TIMEOUT" disconnect "$uuid"; then
    printf '%s\n' "$OP_OUTPUT"
    echo "The disconnect failed; ending the disruptive sequence." >&2
    exit 1
  fi
  confirm_screen "The $label display should now be dark and another screen usable."
  confirm_exact "RECONNECT $label $uuid"
  if ! request_op "$CMD_TIMEOUT" connect "$uuid"; then
    printf '%s\n' "$OP_OUTPUT"
    echo "connect $uuid failed; the watchdog restores displays and the run ends." >&2
    exit 1
  fi
  if ! disarm_watchdog; then
    exit 1
  fi
  confirm_observed "The $label display reconnected."
}

echo ""
echo "WARNING: This test invokes undocumented private macOS APIs and will"
echo "temporarily disconnect displays and change physical monitor brightness."
echo "A detached watchdog runs every disconnect and restores displays if you do not"
echo "confirm a usable screen within ${CONFIRM_TIMEOUT}s. Keep another recovery terminal available."
echo "No force option is used."
echo ""

INITIAL_JSON="$(run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" list --json)"
echo "Initial display inventory:"
printf '%s\n' "$INITIAL_JSON" | jq -r '.[] | [.uuid, .kind, (if .isActive then "active" else "inactive" end), .name] | @tsv'
echo ""
INTERNAL_UUIDS="$(printf '%s\n' "$INITIAL_JSON" | jq -r '.[] | select(.kind == "internal") | .uuid')"
EXTERNAL_UUIDS="$(printf '%s\n' "$INITIAL_JSON" | jq -r '.[] | select(.kind == "external") | .uuid')"
printf '%s\n' "$INITIAL_JSON" | jq -r '.[] | select(.isActive) | .uuid' | sort > "$INITIAL_ACTIVE_FILE"

if [[ -z "$INTERNAL_UUIDS" || -z "$EXTERNAL_UUIDS" ]]; then
  echo "Interactive acceptance requires at least one internal and one external display." >&2
  echo "A headless Core Graphics inventory may validly be empty; run this in the logged-in GUI session." >&2
  exit 1
fi
EXTERNAL_COUNT="$(printf '%s\n' "$EXTERNAL_UUIDS" | grep -c .)"
if [[ "$EXTERNAL_COUNT" != "1" ]]; then
  echo "Hardware validation requires exactly one external display; found $EXTERNAL_COUNT." >&2
  echo "Disconnect other external displays and rerun before any mutation." >&2
  exit 1
fi
if [[ "$(grep -c . "$INITIAL_ACTIVE_FILE")" -lt 2 ]]; then
  echo "Both displays must be active before the test starts. Run '$DISPLAYCTL connect all' first." >&2
  exit 1
fi
echo "displayctl does not report the connector type; note whether the external display is on HDMI or USB-C."

confirm_exact "I UNDERSTAND THE DISPLAY DISRUPTION"
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

choose_uuid "internal" "$INTERNAL_UUIDS"
INTERNAL_UUID="$REPLY"
choose_uuid "external" "$EXTERNAL_UUIDS"
EXTERNAL_UUID="$REPLY"
confirm_exact "USE PHYSICALLY CONNECTED EXTERNAL DISPLAY $EXTERNAL_UUID"

echo ""
echo "External brightness read (read-back is optional on some monitors):"
if BRIGHTNESS_RESULT="$(run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" brightness get "$EXTERNAL_UUID")"; then
  echo "$BRIGHTNESS_RESULT"
  confirm_observed "External brightness get returned a plausible hardware value."
else
  echo "Brightness get was unsupported or failed; record this observed result."
fi
echo "Enter a hardware brightness percentage from 0 through 100 (50 is conservative):"
ask "$PROMPT_TIMEOUT" || { echo "No brightness entered in time." >&2; exit 64; }
BRIGHTNESS_PERCENT="$ANSWER"
if [[ ! "$BRIGHTNESS_PERCENT" =~ ^(0|[1-9][0-9]?|100)$ ]]; then
  echo "Brightness must be a numeric integer from 0 through 100." >&2
  exit 64
fi
confirm_exact "SET EXTERNAL BRIGHTNESS $BRIGHTNESS_PERCENT"
run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" brightness set "$EXTERNAL_UUID" "$BRIGHTNESS_PERCENT"
confirm_observed "The external monitor changed physical brightness."

# Step 1: internal session-scoped round trip; withholding YES here is the unattended watchdog run.
session_round_trip "INTERNAL" "$INTERNAL_UUID"
echo ""
echo "Internal display steps passed."

# Step 2: external steps, only after the internal pass and a separate opt-in.
echo ""
echo "The external steps disable the external display. Only the watchdog and the ledger bring it back."
echo "If they fail, recover with connect all, then logout/login, then a reboot."
echo "Type exactly the line below to run them; anything else skips them."
echo "I OPT IN TO EXTERNAL DISPLAY DISCONNECT TESTS"
if ! ask "$PROMPT_TIMEOUT" || [[ "$ANSWER" != "I OPT IN TO EXTERNAL DISPLAY DISCONNECT TESTS" ]]; then
  echo "External steps skipped. Internal results stand."
  exit 0
fi

# Step 3: external session-scoped round trip.
session_round_trip "EXTERNAL" "$EXTERNAL_UUID"

# Step 4: final-display refusal; every setup disconnect has its own typed confirmation.
echo ""
echo "Final-display protection: every active display except the internal one is disconnected first."
PREPARE_UUIDS="$(active_uuids "$CMD_TIMEOUT" | grep -Fvx -- "$INTERNAL_UUID" || true)"
if [[ -z "$PREPARE_UUIDS" ]]; then
  echo "No other active display found; the final-display test cannot run." >&2
  exit 1
fi
for PREPARE_UUID in $PREPARE_UUIDS; do
  confirm_exact "DISCONNECT FOR FINAL DISPLAY TEST $PREPARE_UUID"
  if [[ "$ARMED" != 1 ]]; then arm_watchdog "$CONFIRM_TIMEOUT"; fi
  if ! request_op "$CMD_TIMEOUT" disconnect "$PREPARE_UUID"; then
    printf '%s\n' "$OP_OUTPUT"
    echo "Disconnect of $PREPARE_UUID failed; ending the disruptive sequence." >&2
    exit 1
  fi
  confirm_screen "$PREPARE_UUID should now be dark and the internal display usable."
done
if [[ "$(active_uuids "$CMD_TIMEOUT")" != "$INTERNAL_UUID" ]]; then
  echo "Could not establish exactly one active display; ending the disruptive sequence." >&2
  exit 1
fi
confirm_exact "ATTEMPT PROTECTED DISCONNECT $INTERNAL_UUID"
if request_op "$CMD_TIMEOUT" disconnect "$INTERNAL_UUID"; then
  echo "CRITICAL: disconnecting the final active display unexpectedly succeeded." >&2
  exit 1
fi
check_watchdog
echo "$OP_OUTPUT"
if [[ "$OP_OUTPUT" != *"Cannot disconnect the last active display"* ]]; then
  echo "The command failed for an unexpected reason; this is not a safety pass." >&2
  exit 1
fi
echo "The command returned the expected last-active-display error."
confirm_screen "The internal display should still be lit after the refusal. The external display stays off until you type YES; then it is reconnected."
echo "Reconnecting the displays disconnected for this test..."
request_op "$CMD_TIMEOUT" connect all || echo "connect all exited $?; the watchdog now verifies the original set." >&2
printf '%s\n' "$OP_OUTPUT"
if ! disarm_watchdog; then
  exit 1
fi
confirm_observed "Every physically present display is lit again."

echo ""
echo "Scripted sequence complete. Results count only where you typed YES."
echo "Manual checks still required:"
echo "1. Re-cable the external monitor over USB-C; run list, brightness get, and a"
echo "   carefully confirmed brightness set. Record supported or unsupported."
echo "2. Soft-disconnect a non-final display, log out and back in, and verify the"
echo "   session-scoped state recovers."
echo "3. Run '$DISPLAYCTL connect all' manually and visually verify recovery."
