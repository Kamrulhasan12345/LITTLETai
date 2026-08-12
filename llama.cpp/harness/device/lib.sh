# lib.sh - shared helpers for the on-device harness. POSIX sh (toybox).
#
# Sourced by runner.sh, uploader.sh and preflight.sh. No bashisms: Android's
# /system/bin/sh is toybox, so no arrays, no [[ ]], no $RANDOM, no local -n.
#
# Everything here must work as shell uid from /data/local/tmp. Notably NOT
# available on this device, all verified rather than assumed:
#   - curl, wget, busybox          (only toybox nc)
#   - /sys/power/wake_lock         (denied; suspend can only be detected)
#   - /sys/class/thermal/*/temp    (SELinux-gated; see temp_mC fallback)
#   - python                       (hence all result parsing happens on the PC)

DEV="${DEV:-/data/local/tmp}"
TRACE_DIR="${TRACE_DIR:-/data/misc/perfetto-traces}"
CFG_DIR="${CFG_DIR:-/data/misc/perfetto-configs}"

OUTBOX="$DEV/outbox"
OUTBOX_BULK="$DEV/outbox_bulk"
STAGING="$DEV/outbox/.staging"
LEDGER="$DEV/done.ledger"
LOCKDIR="$DEV/lbench.lock"
RUNLOG="$DEV/runner.log"
STATE="$DEV/runner.state"

# NC is overridable so the stub tree can substitute a fake for testing.
NC="${NC:-nc}"

# ------------------------------------------------------------------ logging

log() {
  # Timestamped, line-buffered, appended. The log is pulled over adb when
  # available; it is never required for correctness.
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$RUNLOG"
  echo "$(date '+%H:%M:%S') $*"
}

die() { log "FATAL: $*"; exit 1; }

# --------------------------------------------------------------------- time

boottime() {
  # CLOCK_BOOTTIME seconds - the same clock ftrace and sampler.sh use.
  # Includes time spent suspended, which is exactly why a suspend shows up
  # as a hole in the sampler's cadence rather than as missing time here.
  read -r up _ < /proc/uptime 2>/dev/null || up=0
  echo "$up"
}

boot_id() {
  # Changes on every reboot. boottime values are only comparable within one
  # boot_id, so every arm carries it and ingest refuses to mix them.
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown
}

new_id() {
  # Unique per PHYSICAL benchmark execution. A re-queued arm gets a fresh id
  # and the displaced attempt is preserved by the PC's merge step.
  tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null \
    || echo "$(date +%s)$$"
}

# -------------------------------------------------------------- temperature

# Parameterised for the same reason as BAT_DIR: the test tree drives the
# thermal gate deterministically, and a laptop's real zones would otherwise
# leak in and hold the gate shut forever.
THERMAL_DIR="${THERMAL_DIR:-/sys/class/thermal}"

temp_mC() {
  # Best-available device temperature in milli-degC, readable as shell uid.
  #
  # sysfs thermal zones are the first choice, but this MTK kernel SELinux-
  # gates every thermal_zone*/temp for shell, so fall back to the ThermalHAL
  # via dumpsys. Two traps, both previously hit and both handled here:
  #   1. split on "Current temperatures from HAL" - the "Cached temperatures"
  #      block above it holds stale values that would poison the max
  #   2. mValue is in 0.1 degC, so multiply by 1000 to reach milli-degC
  _max=""
  for z in "$THERMAL_DIR"/thermal_zone*; do
    _v=$(cat "$z/temp" 2>/dev/null) || continue
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    # normalise degC / deci-degC / milli-degC to milli-degC
    if [ "$_v" -lt 200 ]; then _v=$((_v * 1000))
    elif [ "$_v" -lt 2000 ]; then _v=$((_v * 100)); fi
    # written out longhand on purpose: `[ a ] || [ b ] && c` parses as
    # `([ a ] || [ b ]) && c` in sh, which is a trap waiting to be edited into
    if [ -z "$_max" ]; then
      _max="$_v"
    elif [ "$_v" -gt "$_max" ]; then
      _max="$_v"
    fi
  done
  if [ -n "$_max" ]; then echo "$_max"; return 0; fi

  dumpsys thermalservice 2>/dev/null \
    | sed -n '/Current temperatures from HAL/,$p' \
    | grep -oE 'mValue=[0-9.]+, mType=[0-9]+, mName=(SOC|CPU|GPU|SKIN)' \
    | grep -oE 'mValue=[0-9.]+' | cut -d= -f2 \
    | awk 'BEGIN{m=""} {v=$1*1000; if(m==""||v>m) m=v} END{if(m!="") printf "%d\n", m}'
}

# ------------------------------------------------------------------ battery

# Parameterised because the node name is not universal across vendors, and
# because it lets the test tree drive battery state deterministically.
BAT_DIR="${BAT_DIR:-/sys/class/power_supply/battery}"

bat() { cat "$BAT_DIR/$1" 2>/dev/null | tr -d '\r'; }
bat_status()   { bat status; }
bat_capacity() { c=$(bat capacity); case "$c" in ''|*[!0-9]*) echo -1 ;; *) echo "$c" ;; esac; }

# ------------------------------------------------------------------ storage

free_mb() {
  # Free megabytes on the filesystem holding DEV.
  df -k "$DEV" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

dir_mb() {
  [ -d "$1" ] || { echo 0; return; }
  du -sk "$1" 2>/dev/null | awk '{print int($1/1024)}'
}

# --------------------------------------------------------------------- lock

acquire_lock() {
  # mkdir is atomic on every POSIX filesystem, which is why it is the lock
  # rather than a pidfile: two runners benchmarking at once would silently
  # contend for the CPU and corrupt every measurement in both runs.
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ > "$LOCKDIR/pid"
    return 0
  fi
  _old=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "$_old" ] && [ -d "/proc/$_old" ]; then
    return 1                      # a live runner already owns it
  fi
  # stale lock from a killed runner: reclaim it
  log "reclaiming stale lock (pid $_old is gone)"
  echo $$ > "$LOCKDIR/pid"
  return 0
}

release_lock() { rm -rf "$LOCKDIR"; }

# ------------------------------------------------------------------- ledger

ledger_has() {
  [ -f "$LEDGER" ] || return 1
  grep -qxF "$1" "$LEDGER"
}

ledger_add() { echo "$1" >> "$LEDGER"; }

# ------------------------------------------------------------- orphan reaping

PIDFILE="$DEV/.pids"

track_pid() { [ -n "${1:-}" ] && echo "$1" >> "$PIDFILE"; return 0; }

reap_orphans() {
  # A previous runner may have been killed mid-arm, leaving a sampler, a
  # perfetto daemon or a benchmark behind. Any of those contaminates the next
  # measurement, so they are reaped before every arm - not only at startup.
  #
  # This kills only PIDs WE recorded. It deliberately does not use
  # `pkill -f <pattern>`: that matches any process whose command line merely
  # mentions the string - an editor with the file open, a log tail, the test
  # harness driving this script - and kills it without warning. That is not a
  # hypothetical; it killed the harness during development.
  [ -f "$PIDFILE" ] || return 0
  while read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ "$p" = "$$" ] && continue
    if [ -d "/proc/$p" ]; then
      kill -TERM "$p" 2>/dev/null
      _n=0
      while [ -d "/proc/$p" ] && [ "$_n" -lt 5 ]; do sleep 1; _n=$((_n + 1)); done
      [ -d "/proc/$p" ] && kill -KILL "$p" 2>/dev/null
    fi
  done < "$PIDFILE"
  : > "$PIDFILE"
  return 0
}

# ------------------------------------------------------------ atomic commit

stage_dir() { echo "$STAGING/$1"; }

commit_arm() {
  # Move a fully-written arm from staging into the outbox in one atomic
  # rename. The uploader only ever scans the outbox, so it can never observe
  # a half-written arm - and it never needs to coordinate with the runner.
  _id="$1"; _dest="$2"
  mkdir -p "$_dest"
  mv "$STAGING/$_id" "$_dest/$_id" 2>/dev/null
}

# ------------------------------------------------------------------ wakelock

wakelock_state() {
  # Reports how (or whether) suspend is being prevented. /sys/power/wake_lock
  # is denied to shell uid on this device - verified, not assumed - so the
  # only available mechanism is a Termux-held partial wakelock, which this
  # cannot acquire but can observe.
  if [ -w /sys/power/wake_lock ] 2>/dev/null; then
    echo "sysfs_writable"
  elif dumpsys power 2>/dev/null | grep -qiE 'PARTIAL_WAKE_LOCK.*termux'; then
    echo "termux_held"
  else
    echo "none"
  fi
}

# ------------------------------------------------------------------- upload

send_frame() {
  # Send one framed payload and return the peer's reply on stdout.
  #
  # The trailing `sleep` is load-bearing and must not be "optimised" away:
  # toybox nc exits the instant stdin reaches EOF and discards whatever the
  # peer was about to say, so without it the ack is never seen and the
  # outbox grows forever while every arm is in fact delivered. Measured on
  # toybox 0.8.12-android; the documented -q flag does NOT do this.
  #
  # The timeout wraps nc HERE rather than wrapping this function at the call
  # site: `timeout N send_frame ...` cannot work, because timeout execs a
  # binary and a shell function is not one. That failure is silent - timeout
  # exits non-zero, the caller sees empty output, and every upload looks like
  # "no reply from the PC".
  _file="$1"; _hdr="$2"; _addr="$3"; _port="$4"
  _linger="${5:-5}"; _timeout="${6:-600}"
  { printf '%s\n' "$_hdr"; [ -n "$_file" ] && cat "$_file"; sleep "$_linger"; } \
    | timeout "$_timeout" $NC "$_addr" "$_port" 2>/dev/null
}
