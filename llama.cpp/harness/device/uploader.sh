#!/system/bin/sh
# uploader.sh - drains the outbox to the PC. POSIX sh (toybox).
#
#   sh uploader.sh 192.168.0.104 9000
#   PC_ADDR="192.168.0.104 100.72.54.24" sh uploader.sh
#
# Runs as a SEPARATE process from runner.sh, sharing only the outbox
# directory. That separation is the whole safety property: this script talks
# to the network, and the network is the one thing that must never be able to
# stall a measurement. If the PC is asleep, firewalled, or gone, arms pile up
# here and the benchmark keeps running.
#
# Two queues, and the priority order between them is deliberate:
#   outbox/       the measurement   ~30 KB/arm   ALWAYS drained first
#   outbox_bulk/  perfetto traces   ~16 MB/arm   best effort, size-capped
# A 16 MB diagnostic must never delay - or evict - the 30 KB of data that is
# the actual result.
#
# Deletion happens only after the PC has verified the checksum and said so.
# Anything less and a dropped connection silently destroys a measurement.

set -u

HERE=$(dirname "$0")
. "$HERE/lib.sh"

# Ordered list; the first that answers is used and remembered. LAN first
# (fast), then Tailscale (survives a DHCP change).
# Measured 2026-08-11: when the phone's WiFi path dies (the same event that
# kills adb), the LAN address returns "No route to host" while Tailscale still
# answers. LAN is listed first because it is ~5 MB/s vs a relayed Tailscale
# path, but the fallback is what makes delivery survive.
PC_ADDR="${PC_ADDR:-${1:-192.168.0.104 100.100.47.53}}"
PC_PORT="${PC_PORT:-${2:-9000}}"

POLL_S="${POLL_S:-15}"
HEARTBEAT_S="${HEARTBEAT_S:-60}"
BULK_CAP_MB="${BULK_CAP_MB:-600}"
SEND_TIMEOUT="${SEND_TIMEOUT:-600}"
# Address selection uses a cheap probe, not the full send timeout: a black-
# holed address (no RST, no ICMP) would otherwise stall a 16 MB upload for
# SEND_TIMEOUT before the working address is even tried.
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"
LINGER_S="${LINGER_S:-5}"

LASTGOOD="$DEV/.uploader_addr"
UPLOG="$DEV/uploader.log"

ulog() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$UPLOG"
}

# ------------------------------------------------------------------ sending

pick_addr() {
  # Return the first address that answers, preferring the last one that
  # worked. Cheap by design - this runs before every batch of sends.
  _cands="$PC_ADDR"
  [ -f "$LASTGOOD" ] && _cands="$(cat "$LASTGOOD") $PC_ADDR"
  for _a in $_cands; do
    # PING, not HB: the PC records heartbeats for the operator to read, and
    # a probe every poll cycle would overwrite the real status line with
    # something that says nothing.
    case "$(send_frame "" "PING" "$_a" "$PC_PORT" 2 "$PROBE_TIMEOUT")" in
      OK*) echo "$_a"; return 0 ;;
    esac
  done
  return 1
}

send_one() {
  # Ship one arm directory. Returns 0 only when the PC confirmed receipt.
  _dir="$1"; _queue="$2"; _addr="$3"
  _id=$(basename "$_dir")
  _tar="$DEV/.up_$_id.tar"

  rm -f "$_tar"
  tar -cf "$_tar" -C "$_queue" "$_id" 2>/dev/null || {
    ulog "tar failed for $_id"; rm -f "$_tar"; return 1; }

  _sha=$(sha256sum "$_tar" 2>/dev/null | cut -d' ' -f1)
  _sz=$(stat -c%s "$_tar" 2>/dev/null)
  case "$_sz" in ''|*[!0-9]*) ulog "cannot size $_tar"; rm -f "$_tar"; return 1 ;; esac

  _reply=$(send_frame "$_tar" "ARM $_id $_sha $_sz" \
                      "$_addr" "$PC_PORT" "$LINGER_S" "$SEND_TIMEOUT")
  rm -f "$_tar"
  case "$_reply" in
    OK*)
      echo "$_addr" > "$LASTGOOD"
      # Only now is it safe to destroy the device's only copy.
      rm -rf "$_queue/$_id"
      ulog "sent $_id ($_sz bytes) to $_addr"
      return 0 ;;
    ERR*)
      # The PC received it and rejected it. Retrying the same bytes will fail
      # identically, so keep the arm and surface the reason rather than
      # spinning on it forever.
      ulog "REJECTED $_id by $_addr: $_reply"
      return 2 ;;
    *)
      ulog "no reply from $_addr for $_id"
      return 1 ;;
  esac
}

# ------------------------------------------------------------------ eviction

evict_bulk() {
  # Traces are diagnostic. If the PC has been unreachable long enough that
  # they threaten the device's storage, the OLDEST ones go - never the
  # measurements, which live in the other queue and are 1500x smaller.
  _mb=$(dir_mb "$OUTBOX_BULK")
  [ "$_mb" -le "$BULK_CAP_MB" ] && return 0
  ulog "bulk queue at ${_mb}MB (cap ${BULK_CAP_MB}MB) - evicting oldest traces"
  for _d in $(ls -1t "$OUTBOX_BULK" 2>/dev/null | tail -r 2>/dev/null \
              || ls -1t "$OUTBOX_BULK" 2>/dev/null | sed '1!G;h;$!d'); do
    [ "$(dir_mb "$OUTBOX_BULK")" -le "$BULK_CAP_MB" ] && break
    rm -rf "$OUTBOX_BULK/$_d"
    ulog "evicted trace $_d"
    # Record the loss where it will be noticed: the measurement it belonged
    # to is still queued or already delivered, and must say its trace is gone.
    _base=${_d%.trace}
    [ -f "$OUTBOX/$_base/meta.kv" ] && \
      sed -i 's/^trace_evicted=0$/trace_evicted=1/' "$OUTBOX/$_base/meta.kv" \
        2>/dev/null
  done
}

# ----------------------------------------------------------------- heartbeat

heartbeat() {
  # The only visibility that exists when adb has been gone for hours. Sent
  # separately from results because an arm can take 20 minutes, and silence
  # for 20 minutes is indistinguishable from a dead run.
  _st=$(cat "$STATE" 2>/dev/null || echo "arm=? done=? total=?")
  _pending=$(ls -1 "$OUTBOX" 2>/dev/null | grep -cv '^\.staging$')
  _bulk=$(ls -1 "$OUTBOX_BULK" 2>/dev/null | wc -l | tr -d ' ')
  _msg="HB $_st pending=$_pending bulk=$_bulk bulk_mb=$(dir_mb "$OUTBOX_BULK")"
  for _addr in $PC_ADDR; do
    _r=$(send_frame "" "$_msg" "$_addr" "$PC_PORT" 2 30)
    case "$_r" in OK*) return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------------- main

main() {
  mkdir -p "$OUTBOX" "$OUTBOX_BULK"
  [ -f "$LASTGOOD" ] && PC_ADDR="$(cat "$LASTGOOD") $PC_ADDR"
  ulog "=== uploader starting: addr='$PC_ADDR' port=$PC_PORT ==="

  _last_hb=0
  while :; do
    ADDR=$(pick_addr)
    if [ -z "$ADDR" ]; then
      # No path to the PC. This is a normal, expected state - queue and wait.
      # It must never touch the runner.
      sleep "$POLL_S"
      [ -f "$DEV/runner.done" ] || continue
    fi

    # 1. measurements first, always, and completely
    if [ -n "$ADDR" ]; then
    for _d in "$OUTBOX"/*; do
      [ -d "$_d" ] || continue
      case "$(basename "$_d")" in .staging) continue ;; esac
      # A directory without meta.kv is mid-commit; the runner's atomic
      # rename means this should be impossible, but skipping costs nothing.
      [ -f "$_d/meta.kv" ] || continue
      send_one "$_d" "$OUTBOX" "$ADDR"
    done
    fi

    # 2. then traces, and only if storage allows
    evict_bulk
    if [ -n "$ADDR" ]; then
    for _d in "$OUTBOX_BULK"/*; do
      [ -d "$_d" ] || continue
      case "$(basename "$_d")" in .staging) continue ;; esac
      # Re-check the measurement queue between traces: a 16 MB upload must
      # not delay a measurement that appeared while it was in flight.
      if [ "$(ls -1 "$OUTBOX" 2>/dev/null | grep -cv '^\.staging$')" -gt 0 ]; then
        break
      fi
      send_one "$_d" "$OUTBOX_BULK" "$ADDR"
    done
    fi

    _now=$(date +%s)
    if [ $((_now - _last_hb)) -ge "$HEARTBEAT_S" ]; then
      heartbeat && _last_hb=$_now
    fi

    # Stop once the runner is done AND everything has drained.
    if [ -f "$DEV/runner.done" ] && \
       [ "$(ls -1 "$OUTBOX" 2>/dev/null | grep -cv '^\.staging$')" -eq 0 ] && \
       [ "$(ls -1 "$OUTBOX_BULK" 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
      # A final status, so the operator sees "finished" rather than simply
      # silence - which is indistinguishable from a dead uploader.
      heartbeat
      ulog "=== uploader finished: runner done and queues empty ==="
      break
    fi

    sleep "$POLL_S"
  done
}

main "$@"
