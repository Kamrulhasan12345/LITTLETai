#!/system/bin/sh
# prep.sh - put the device into measurement hygiene. Runs ON the phone.
#
#   sh prep.sh                 # apply hygiene, verify, self-heal on failure
#   sh prep.sh --restore       # undo it (airplane off)
#
# This runs on-device and detached ON PURPOSE. Enabling airplane mode drops
# WiFi, and WiFi is the only path off this phone - Tailscale rides it, and
# mobile data is disabled. If the sequence were driven over adb and WiFi did
# not come back, adb would die mid-sequence with no way to undo it remotely
# and the phone would need to be picked up. Running locally means the rollback
# always executes, even when nothing can reach the device.
#
# What it does, in order:
#   1. record the current state so it can be put back
#   2. bluetooth off
#   3. airplane mode ON  (kills the LTE radio: SIM is registered, so it is
#      burning power and heat even with mobile data off)
#   4. WiFi back ON      (wifi is in airplane_mode_toggleable_radios)
#   5. wait for wlan0 to hold an address
#   6. prove the PC is still reachable
#   7. if it is not, ROLL BACK and say so
#   8. screen off (screen_off_timeout is infinite on this device, so the
#      screen would otherwise stay lit for the whole run)

set -u
HERE=$(dirname "$0")
. "$HERE/lib.sh"

RESULT="$DEV/prep.result"
SAVED="$DEV/prep.saved"
PC_ADDR="${PC_ADDR:-192.168.0.104 100.100.47.53}"
PC_PORT="${PC_PORT:-9000}"
WIFI_WAIT_S="${WIFI_WAIT_S:-45}"

say() { echo "$*"; echo "$*" >> "$RESULT"; }

wifi_addr() {
  ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 \
    | cut -d' ' -f2
}

pc_reachable() {
  for a in $PC_ADDR; do
    case "$(send_frame "" "PING" "$a" "$PC_PORT" 2 15)" in
      OK*) echo "$a"; return 0 ;;
    esac
  done
  return 1
}

restore() {
  settings put global airplane_mode_on 0
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false \
    >/dev/null 2>&1
  svc wifi enable >/dev/null 2>&1
  echo "restored: airplane off, wifi on"
}

if [ "${1:-}" = "--restore" ]; then
  restore
  exit 0
fi

: > "$RESULT"
say "prep starting $(date '+%Y-%m-%d %H:%M:%S')"

# ---- 1. remember where we started ----------------------------------------
{
  echo "airplane_was=$(settings get global airplane_mode_on)"
  echo "bluetooth_was=$(settings get global bluetooth_on)"
  echo "wifi_was=$(settings get global wifi_on)"
} > "$SAVED"

# ---- 2/3/4. radios --------------------------------------------------------
svc bluetooth disable >/dev/null 2>&1

# Writing the setting is enough on this device: it drops the mobile radio and
# WiFi stays up, which is what SETUP_LOG's hygiene procedure has always relied
# on. `svc wifi enable` afterwards is belt-and-braces, not a fix.
#
# Do NOT try to verify the modem via `getprop gsm.network.type` or
# `dumpsys telephony.registry` - both report cached "last known" values that
# do not refresh on toggle, so they read as unchanged and make a working
# airplane mode look broken. What matters operationally is verified below
# instead: wlan0 still holds an address, and the PC is still reachable.
settings put global airplane_mode_on 1
sleep 3
svc wifi enable >/dev/null 2>&1

# ---- 5. wait for an address ----------------------------------------------
_n=0
while [ "$_n" -lt "$WIFI_WAIT_S" ]; do
  [ -n "$(wifi_addr)" ] && break
  sleep 1; _n=$((_n + 1))
done
IP=$(wifi_addr)
say "  wlan0: ${IP:-NONE} (after ${_n}s)"

# ---- 6/7. prove we can still deliver, or undo -----------------------------
if [ -z "$IP" ]; then
  say "  !! wifi did not come back - ROLLING BACK"
  restore
  say "verdict=ROLLED_BACK_NO_WIFI"
  exit 1
fi

ADDR=$(pc_reachable)
if [ -z "$ADDR" ]; then
  # The run itself would survive this (arms queue on the device), but a run
  # nobody can see for 6 hours is not worth starting.
  say "  !! PC unreachable after airplane mode - ROLLING BACK"
  restore
  sleep 5
  ADDR2=$(pc_reachable)
  say "  after rollback, PC reachable: ${ADDR2:-still no}"
  say "verdict=ROLLED_BACK_NO_PC"
  exit 1
fi
say "  PC reachable at $ADDR"

# ---- 8. screen off --------------------------------------------------------
input keyevent KEYCODE_SLEEP >/dev/null 2>&1
sleep 1
say "  wakefulness: $(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | tr -d ' ')"

# ---- report ---------------------------------------------------------------
say "  airplane   : $(settings get global airplane_mode_on)  (wifi kept up)"
say "  bluetooth  : $(settings get global bluetooth_on)"
say "  battery    : $(bat_capacity)% $(bat_status)"
say "  wakelock   : $(wakelock_state)"
case "$(bat_status)" in
  *Charging*|*Full*) say "  !! STILL PLUGGED IN - energy will be invalid, and"
                     say "     charging heat keeps the thermal gate closed" ;;
esac
say "verdict=OK"
