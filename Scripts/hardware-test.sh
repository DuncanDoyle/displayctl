#!/bin/bash
# Interactive hardware validation for displayctl. Written for macOS /bin/bash 3.2.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_PATH")")"

# Timeouts in whole seconds; override via env to test with a stub displayctl.
CONFIRM_TIMEOUT="${HARDWARE_TEST_CONFIRM_TIMEOUT:-20}"
ARMED_MAX="${HARDWARE_TEST_ARMED_MAX:-180}"
RESTORE_DEADLINE="${HARDWARE_TEST_RESTORE_DEADLINE:-90}"
RETRY_INTERVAL="${HARDWARE_TEST_RETRY_INTERVAL:-2}"
PROMPT_TIMEOUT="${HARDWARE_TEST_PROMPT_TIMEOUT:-60}"
CMD_TIMEOUT="${HARDWARE_TEST_CMD_TIMEOUT:-60}"
TRIAL_SECONDS="${HARDWARE_TEST_TRIAL_SECONDS:-10}"
TRIAL_SETTLE="${HARDWARE_TEST_TRIAL_SETTLE:-5}"
export HARDWARE_TEST_CONFIRM_TIMEOUT="$CONFIRM_TIMEOUT" HARDWARE_TEST_ARMED_MAX="$ARMED_MAX" \
  HARDWARE_TEST_RESTORE_DEADLINE="$RESTORE_DEADLINE" HARDWARE_TEST_RETRY_INTERVAL="$RETRY_INTERVAL" \
  HARDWARE_TEST_CMD_TIMEOUT="$CMD_TIMEOUT"

log() {
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"
}

# Runs a command with stdin closed and kills it after $1 seconds (exit 124).
run_bounded() {
  local limit_ticks=$(( $1 * 5 )) ticks=0 pid
  shift
  "$@" </dev/null &
  pid=$!
  [[ -n "${RECORD_PID:-}" ]] && printf '%s\n' "$pid" > "$RECORD_PID"
  while kill -0 "$pid" 2>/dev/null; do
    if (( ticks >= limit_ticks )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    ticks=$(( ticks + 1 ))
  done
  wait "$pid"
}

active_uuids() {
  local json
  json="$(run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" list --json)" || return 1
  printf '%s\n' "$json" | jq -r 'if type == "array" then .[] | select(.isActive) | .uuid else error("not an array") end' \
    | sort
}

# Succeeds when every UUID listed in file $1 is currently active.
originals_active() {
  local current uuid
  current="$(active_uuids)" || return 1
  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue
    printf '%s\n' "$current" | grep -Fqx -- "$uuid" || return 1
  done < "$1"
}

# Retries `connect all` until the UUIDs in $1 are active, a cancel file $3 appears, or $2 seconds pass.
# A live pid in file $4 is a displayctl mutation still running; the set counts as restored only after it exits.
restore_loop() {
  local originals="$1" deadline=$(( SECONDS + $2 )) cancel_file="${3:-}" mutator_file="${4:-}"
  local attempt=0 restored output rc
  while true; do
    restored=0
    originals_active "$originals" && restored=1
    if (( restored )) && ! { [[ -s "$mutator_file" ]] && kill -0 "$(cat "$mutator_file")" 2>/dev/null; }; then
      log "Restored: every originally active display is active."
      return 0
    fi
    if [[ -n "$cancel_file" && -e "$cancel_file" ]]; then
      log "Cancelled by the test script."
      return 0
    fi
    if (( SECONDS >= deadline )); then
      log "Hard deadline reached; originally active displays are not all active."
      return 1
    fi
    if (( restored )); then
      log "Displays are active, but a displayctl mutation is still running; waiting for it to exit."
    else
      attempt=$(( attempt + 1 ))
      rc=0
      output="$(run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" connect all 2>&1)" || rc=$?
      log "connect all attempt $attempt exited $rc: $(printf '%s' "$output" | tr '\n' ' ')"
    fi
    sleep "$RETRY_INTERVAL"
  done
}

# Detached watchdog: $1 state dir, $2 seconds to wait for confirmation before restoring.
watchdog_main() {
  local dir="$1" fire_after="$2" start=$SECONDS reason
  set +e
  trap '' HUP INT
  printf '%s\n' "$$" > "$dir/pid"
  log "Armed (pid $$): confirm within ${fire_after}s, restore by ${ARMED_MAX}s at the latest."
  : > "$dir/ready"
  while true; do
    if [[ -e "$dir/cancel" ]]; then
      log "Disarmed by the test script."
      exit 0
    fi
    if [[ -e "$dir/fire" ]]; then
      reason="the test script requested recovery"
      break
    fi
    if [[ ! -e "$dir/confirmed" ]] && (( SECONDS - start >= fire_after )); then
      reason="no confirmation within ${fire_after}s"
      break
    fi
    if (( SECONDS - start >= ARMED_MAX )); then
      reason="still armed after ${ARMED_MAX}s"
      break
    fi
    sleep 1
  done
  : > "$dir/fired"
  log "Firing: $reason."
  if restore_loop "$dir/originals" "$RESTORE_DEADLINE" "$dir/cancel" "$dir/mutator"; then
    : > "$dir/restored"
    exit 0
  fi
  : > "$dir/failed"
  exit 1
}

if [[ "${1:-}" == "--watchdog" ]]; then
  DISPLAYCTL="${DISPLAYCTL:?DISPLAYCTL must be set for the watchdog}"
  watchdog_main "$2" "$3"
fi

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
ARMED_AT=0
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

# Reads one line into ANSWER within $1 seconds; fails on timeout or EOF.
ask() {
  local t="$1"
  (( t < 1 )) && t=1
  ANSWER=""
  IFS= read -r -t "$t" ANSWER || { ANSWER=""; return 1; }
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

# Ends the run if the watchdog has fired; the EXIT trap then verifies recovery.
check_watchdog() {
  if [[ "$ARMED" == 1 && -e "$WD_DIR/fired" ]]; then
    echo "The watchdog fired; the disruptive sequence ends here." >&2
    echo "Another disconnect needs a fresh run of this script and a fresh opt-in." >&2
    exit 1
  fi
}

arm_watchdog() {
  local fire_after="$1" i
  WD_DIR="$(mktemp -d "$RUN_DIR/watchdog.XXXXXX")"
  if ! active_uuids > "$WD_DIR/originals" || [[ ! -s "$WD_DIR/originals" ]]; then
    echo "Could not record the active display set; no disconnect attempted." >&2
    exit 1
  fi
  # Own process group and nohup: survives Ctrl-C, a closed terminal and a foreground stuck in read.
  set -m
  nohup /bin/bash "$SCRIPT_PATH" --watchdog "$WD_DIR" "$fire_after" >> "$WD_DIR/watchdog.log" 2>&1 < /dev/null &
  WD_PID=$!
  disown "$WD_PID"
  set +m
  for (( i = 0; i < 50; i++ )); do
    [[ -e "$WD_DIR/ready" ]] && break
    sleep 0.1
  done
  if [[ ! -e "$WD_DIR/ready" ]]; then
    kill "$WD_PID" 2>/dev/null || true
    echo "The watchdog did not start; no disconnect attempted." >&2
    exit 1
  fi
  ARMED=1
  ARMED_AT=$SECONDS
  MUTATION_STARTED=1
  echo "Watchdog armed (log: $WD_DIR/watchdog.log). Without confirmation it restores displays after ${fire_after}s."
}

disarm_watchdog() {
  local i
  : > "$WD_DIR/cancel"
  for (( i = 0; i < 50; i++ )); do
    kill -0 "$WD_PID" 2>/dev/null || break
    sleep 0.1
  done
  ARMED=0
}

# Like run_bounded, but records the pid so recovery waits until this mutation has exited.
run_mutation() {
  local rc=0
  RECORD_PID="$WD_DIR/mutator"
  run_bounded "$@" || rc=$?
  RECORD_PID=""
  return "$rc"
}

# Restores the set recorded at arming, verifies it, then disarms.
restore_and_disarm() {
  if restore_loop "$WD_DIR/originals" "$RESTORE_DEADLINE" "" "$WD_DIR/mutator"; then
    disarm_watchdog
  else
    return 1
  fi
}

# Asks for proof of a usable screen within what is left of the confirmation window.
confirm_screen() {
  local remaining
  check_watchdog
  remaining=$(( CONFIRM_TIMEOUT - (SECONDS - ARMED_AT) ))
  echo "$1 Type YES within ${remaining}s, or displays are restored automatically:"
  if ask "$remaining" && [[ "$ANSWER" == "YES" ]]; then
    check_watchdog
    : > "$WD_DIR/confirmed"
    echo "Screen confirmed. The watchdog stays armed until the original displays are verified active."
  else
    echo "No YES in time; ending the disruptive sequence." >&2
    exit 1
  fi
}

on_exit() {
  local status=$? target
  trap - EXIT INT TERM HUP
  if [[ "$MUTATION_STARTED" != 1 ]]; then
    exit "$status"
  fi
  echo ""
  echo "Recovery: restoring every display that was active..."
  target="$INITIAL_ACTIVE_FILE"
  if [[ "$ARMED" == 1 ]]; then
    : > "$WD_DIR/fire"
    target="$WD_DIR/originals"
  fi
  if restore_loop "$target" "$RESTORE_DEADLINE" "" "${WD_DIR:+$WD_DIR/mutator}"; then
    [[ "$ARMED" == 1 ]] && disarm_watchdog
    echo "Recovery verified with list --json. Check every physically present display visually."
  else
    print_recovery_help
    (( status == 0 )) && status=1
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

echo ""
echo "WARNING: This test invokes undocumented private macOS APIs and will"
echo "temporarily disconnect displays and change physical monitor brightness."
echo "A detached watchdog restores displays if you do not confirm a usable screen"
echo "within ${CONFIRM_TIMEOUT}s. Keep another recovery terminal available. No force option is used."
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
  echo "HDMI validation requires exactly one external display; found $EXTERNAL_COUNT." >&2
  echo "Disconnect other external displays and rerun before any mutation." >&2
  exit 1
fi
if [[ "$(grep -c . "$INITIAL_ACTIVE_FILE")" -lt 2 ]]; then
  echo "Both displays must be active before the test starts. Run '$DISPLAYCTL connect all' first." >&2
  exit 1
fi
echo "displayctl does not report connector type; verify the external display is physically on HDMI."

confirm_exact "I UNDERSTAND THE DISPLAY DISRUPTION"
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

choose_uuid "internal" "$INTERNAL_UUIDS"
INTERNAL_UUID="$REPLY"
choose_uuid "external (HDMI)" "$EXTERNAL_UUIDS"
EXTERNAL_UUID="$REPLY"
confirm_exact "USE PHYSICALLY HDMI-CONNECTED DISPLAY $EXTERNAL_UUID"

echo ""
echo "HDMI brightness read (read-back is optional on some monitors):"
if BRIGHTNESS_RESULT="$(run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" brightness get "$EXTERNAL_UUID")"; then
  echo "$BRIGHTNESS_RESULT"
  confirm_observed "HDMI brightness get returned a plausible hardware value."
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
confirm_exact "SET HDMI BRIGHTNESS $BRIGHTNESS_PERCENT"
run_bounded "$CMD_TIMEOUT" "$DISPLAYCTL" brightness set "$EXTERNAL_UUID" "$BRIGHTNESS_PERCENT"
confirm_observed "The HDMI monitor changed physical brightness."

# Step 1: app-only trial; macOS should revert it when displayctl exits.
echo ""
echo "Trial: the internal display goes dark for up to ${TRIAL_SECONDS}s and should return by itself."
confirm_exact "TRIAL DISCONNECT INTERNAL $INTERNAL_UUID"
arm_watchdog $(( TRIAL_SECONDS + CONFIRM_TIMEOUT ))
TRIAL_STATUS=0
run_mutation $(( TRIAL_SECONDS + CMD_TIMEOUT )) "$DISPLAYCTL" disconnect "$INTERNAL_UUID" --trial "$TRIAL_SECONDS" \
  || TRIAL_STATUS=$?
echo "Trial command exited $TRIAL_STATUS; checking with list --json that the display returned..."
TRIAL_REVERTED=0
for (( i = 0; i <= TRIAL_SETTLE; i++ )); do
  if originals_active "$WD_DIR/originals"; then
    TRIAL_REVERTED=1
    break
  fi
  sleep 1
done
if [[ "$TRIAL_REVERTED" != 1 ]]; then
  echo "FAIL: the internal display did not return after the trial; app-only revert is not proven." >&2
  echo "Session-scoped disconnects are skipped." >&2
  exit 1
fi
disarm_watchdog
echo "The internal display is active again after the trial."
if [[ "$TRIAL_STATUS" != 0 ]]; then
  echo "FAIL: the trial command itself failed; session-scoped disconnects are skipped." >&2
  exit 1
fi
confirm_observed "The internal display went dark during the trial and came back by itself."

# Session-scoped disconnect and reconnect of one display, guarded by the watchdog.
session_round_trip() {
  local label="$1" uuid="$2"
  echo ""
  confirm_exact "DISCONNECT $label $uuid"
  arm_watchdog "$CONFIRM_TIMEOUT"
  if ! run_mutation "$CMD_TIMEOUT" "$DISPLAYCTL" disconnect "$uuid"; then
    echo "The disconnect failed; ending the disruptive sequence." >&2
    exit 1
  fi
  confirm_screen "The $label display should now be dark and another screen usable."
  confirm_exact "RECONNECT $label $uuid"
  check_watchdog
  run_mutation "$CMD_TIMEOUT" "$DISPLAYCTL" connect "$uuid" || echo "connect $uuid failed; retrying connect all." >&2
  if ! restore_and_disarm; then
    echo "Could not verify the original active displays; ending the disruptive sequence." >&2
    exit 1
  fi
  confirm_observed "The $label display reconnected."
}

# Step 2: internal session-scoped round trip.
session_round_trip "INTERNAL" "$INTERNAL_UUID"
echo ""
echo "Internal display steps passed."

# Step 3: external steps, only after the internal pass and a separate opt-in.
echo ""
echo "The external steps disable the HDMI display, which once needed a reboot to recover."
echo "Type exactly the line below to run them; anything else skips them."
echo "I OPT IN TO EXTERNAL DISPLAY DISCONNECT TESTS"
if ! ask "$PROMPT_TIMEOUT" || [[ "$ANSWER" != "I OPT IN TO EXTERNAL DISPLAY DISCONNECT TESTS" ]]; then
  echo "External steps skipped. Internal results stand."
  exit 0
fi
session_round_trip "EXTERNAL" "$EXTERNAL_UUID"

echo ""
echo "Final-display protection: every active display except the internal one is disconnected first."
PREPARE_UUIDS="$(active_uuids | grep -Fvx -- "$INTERNAL_UUID" || true)"
echo "Displays to disconnect:"
echo "$PREPARE_UUIDS"
confirm_exact "PREPARE FINAL DISPLAY TEST"
arm_watchdog "$CONFIRM_TIMEOUT"
while IFS= read -r PREPARE_UUID; do
  [[ -z "$PREPARE_UUID" ]] && continue
  if ! run_mutation "$CMD_TIMEOUT" "$DISPLAYCTL" disconnect "$PREPARE_UUID"; then
    echo "Disconnect of $PREPARE_UUID failed; ending the disruptive sequence." >&2
    exit 1
  fi
done <<< "$PREPARE_UUIDS"
confirm_screen "Only the internal display should be lit and usable."
if [[ "$(active_uuids)" != "$INTERNAL_UUID" ]]; then
  echo "Could not establish exactly one active display; ending the disruptive sequence." >&2
  exit 1
fi
confirm_exact "ATTEMPT PROTECTED DISCONNECT $INTERNAL_UUID"
check_watchdog
if REFUSAL_OUTPUT="$(run_mutation "$CMD_TIMEOUT" "$DISPLAYCTL" disconnect "$INTERNAL_UUID" 2>&1)"; then
  echo "CRITICAL: disconnecting the final active display unexpectedly succeeded." >&2
  exit 1
fi
echo "$REFUSAL_OUTPUT"
if [[ "$REFUSAL_OUTPUT" != *"Cannot disconnect the last active display"* ]]; then
  echo "The command failed for an unexpected reason; this is not a safety pass." >&2
  exit 1
fi
echo "The command returned the expected last-active-display error."
confirm_observed "The final active display remained connected after the refusal."
check_watchdog
if ! restore_and_disarm; then
  echo "Could not verify the original active displays after the final-display test." >&2
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
