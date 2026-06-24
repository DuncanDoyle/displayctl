#!/bin/zsh
set -euo pipefail

if [[ ! -t 0 || ! -t 1 ]]; then
  print -u2 -- "hardware-test.sh requires interactive stdin and stdout."
  exit 64
fi

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
cd "$REPO_ROOT"

print -- "Building displayctl..."
swift build
DISPLAYCTL="$REPO_ROOT/.build/debug/displayctl"

print -- ""
print -- "WARNING: This test invokes undocumented private macOS APIs and will"
print -- "temporarily disconnect displays and change physical monitor brightness."
print -- "Connection changes are session-scoped, but disruption and API incompatibility"
print -- "are possible. Keep another recovery terminal available. No force option is used."
print -- ""

INITIAL_JSON="$("$DISPLAYCTL" list --json)"
print -- "Initial display inventory (JSON):"
print -r -- "$INITIAL_JSON"
print -- ""

INITIAL_TABLE="$("$DISPLAYCTL" list)"
INTERNAL_UUIDS="$(print -r -- "$INITIAL_TABLE" | awk -F '\t' 'NR > 1 && $4 == "internal" { print $1 }')"
EXTERNAL_UUIDS="$(print -r -- "$INITIAL_TABLE" | awk -F '\t' 'NR > 1 && $4 == "external" { print $1 }')"

if [[ -z "$INTERNAL_UUIDS" || -z "$EXTERNAL_UUIDS" ]]; then
  print -u2 -- "Interactive acceptance requires at least one internal and one external display."
  print -u2 -- "A headless Core Graphics inventory may validly be empty; run this in the logged-in GUI session."
  exit 1
fi

print -- "Type exactly: I UNDERSTAND THE DISPLAY DISRUPTION"
read -r INITIAL_CONFIRMATION
if [[ "$INITIAL_CONFIRMATION" != "I UNDERSTAND THE DISPLAY DISRUPTION" ]]; then
  print -u2 -- "Confirmation did not match; no mutations were attempted."
  exit 1
fi

recover() {
  local original_status=$?
  trap - EXIT INT TERM
  print -- ""
  print -- "Recovery: attempting displayctl connect all..."
  if "$DISPLAYCTL" connect all; then
    print -- "Recovery command completed. Verify every physically present display visually."
  else
    print -u2 -- "Recovery command failed. Run '$DISPLAYCTL connect all' manually or log out/in."
  fi
  exit "$original_status"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

choose_uuid() {
  local kind="$1"
  local choices="$2"
  local selected
  print -- "Available $kind stable UUID selectors:"
  print -r -- "$choices"
  print -- "Enter the exact $kind UUID to test:"
  read -r selected
  if [[ ! "$selected" =~ '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' ]]; then
    print -u2 -- "A canonical UUID is required."
    return 1
  fi
  if ! print -r -- "$choices" | grep -Fqx -- "$selected"; then
    print -u2 -- "That UUID is not in the current $kind inventory group."
    return 1
  fi
  REPLY="$selected"
}

confirm_exact() {
  local expected="$1"
  local entered
  print -- "Type exactly: $expected"
  read -r entered
  if [[ "$entered" != "$expected" ]]; then
    print -u2 -- "Confirmation did not match; aborting to recovery."
    return 1
  fi
}

confirm_observed() {
  local description="$1"
  local answer
  print -- "$description Type exactly YES only if you personally observed it:"
  read -r answer
  if [[ "$answer" == "YES" ]]; then
    print -- "Recorded user confirmation: $description"
  else
    print -- "Not recorded as passed: $description"
  fi
}

choose_uuid "internal" "$INTERNAL_UUIDS"
INTERNAL_UUID="$REPLY"
choose_uuid "external (HDMI)" "$EXTERNAL_UUIDS"
EXTERNAL_UUID="$REPLY"

print -- ""
print -- "HDMI brightness read (read-back is optional on some monitors):"
if BRIGHTNESS_RESULT="$("$DISPLAYCTL" brightness get "$EXTERNAL_UUID")"; then
  print -r -- "$BRIGHTNESS_RESULT"
  confirm_observed "HDMI brightness get returned a plausible hardware value."
else
  print -- "Brightness get was unsupported or failed; record this observed result."
fi

print -- "Enter a hardware brightness percentage from 0 through 100 (50 is conservative):"
read -r BRIGHTNESS_PERCENT
if [[ ! "$BRIGHTNESS_PERCENT" == <-> ]] || (( BRIGHTNESS_PERCENT < 0 || BRIGHTNESS_PERCENT > 100 )); then
  print -u2 -- "Brightness must be a numeric integer from 0 through 100."
  exit 64
fi
confirm_exact "SET HDMI BRIGHTNESS $BRIGHTNESS_PERCENT"
"$DISPLAYCTL" brightness set "$EXTERNAL_UUID" "$BRIGHTNESS_PERCENT"
confirm_observed "The HDMI monitor changed physical brightness."

confirm_exact "DISCONNECT EXTERNAL $EXTERNAL_UUID"
"$DISPLAYCTL" disconnect "$EXTERNAL_UUID"
confirm_observed "The external display disconnected."
confirm_exact "RECONNECT EXTERNAL $EXTERNAL_UUID"
"$DISPLAYCTL" connect "$EXTERNAL_UUID"
confirm_observed "The external display reconnected."
confirm_exact "CONNECT ALL AFTER EXTERNAL"
"$DISPLAYCTL" connect all

confirm_exact "DISCONNECT INTERNAL $INTERNAL_UUID"
"$DISPLAYCTL" disconnect "$INTERNAL_UUID"
confirm_observed "The internal display disconnected."
confirm_exact "RECONNECT INTERNAL $INTERNAL_UUID"
"$DISPLAYCTL" connect "$INTERNAL_UUID"
confirm_observed "The internal display reconnected."
confirm_exact "CONNECT ALL AFTER INTERNAL"
"$DISPLAYCTL" connect all

print -- ""
print -- "Final-display protection: every active display except the selected internal"
print -- "display will first be disconnected, including any additional externals."
ACTIVE_TABLE="$("$DISPLAYCTL" list)"
ACTIVE_UUIDS="$(print -r -- "$ACTIVE_TABLE" | awk -F '\t' 'NR > 1 && $6 == "true" { print $1 }')"
while IFS= read -r ACTIVE_UUID; do
  [[ -z "$ACTIVE_UUID" || "$ACTIVE_UUID" == "$INTERNAL_UUID" ]] && continue
  confirm_exact "PREPARE FINAL DISPLAY TEST DISCONNECT $ACTIVE_UUID"
  "$DISPLAYCTL" disconnect "$ACTIVE_UUID"
done <<< "$ACTIVE_UUIDS"

REMAINING_TABLE="$("$DISPLAYCTL" list)"
REMAINING_ACTIVE="$(print -r -- "$REMAINING_TABLE" | awk -F '\t' 'NR > 1 && $6 == "true" { print $1 }')"
if [[ "$REMAINING_ACTIVE" != "$INTERNAL_UUID" ]]; then
  print -u2 -- "Could not establish exactly one active display; aborting to recovery."
  exit 1
fi
confirm_exact "ATTEMPT PROTECTED DISCONNECT $INTERNAL_UUID"
if REFUSAL_OUTPUT="$("$DISPLAYCTL" disconnect "$INTERNAL_UUID" 2>&1)"; then
  print -u2 -- "CRITICAL: disconnecting the final active display unexpectedly succeeded."
  "$DISPLAYCTL" connect all || true
  exit 1
else
  print -r -- "$REFUSAL_OUTPUT"
  if [[ "$REFUSAL_OUTPUT" != *"Cannot disconnect the last active display"* ]]; then
    print -u2 -- "The command failed for an unexpected reason; this is not a safety pass."
    exit 1
  fi
  print -- "The command returned the expected last-active-display error."
  confirm_observed "The final active display remained connected after the refusal."
fi
confirm_exact "CONNECT ALL AFTER FINAL DISPLAY TEST"
"$DISPLAYCTL" connect all
confirm_observed "The final connect all recovery restored every physically present display."

print -- ""
print -- "Scripted sequence complete. Results count only where you typed YES."
print -- "Manual checks still required:"
print -- "1. Re-cable the external monitor over USB-C; run list, brightness get, and a"
print -- "   carefully confirmed brightness set. Record supported or unsupported."
print -- "2. Soft-disconnect a non-final display, log out and back in, and verify the"
print -- "   session-scoped state recovers."
print -- "3. Run '$DISPLAYCTL connect all' manually and visually verify recovery."
