#!/bin/bash
# ssd-mount-notify.sh <uuid> <volume> <grace-s> <title>
# Notifies once if the SSD is still unmounted after grace.

# Lives on the internal disk, never the SSD it watches.
# Runs under /bin/bash 3.2 from a user LaunchAgent.

set -uo pipefail

# Overridable for tests (tests/test-ssd-mount-notify.sh).

DISKUTIL_BIN="${DISKUTIL_BIN:-/usr/sbin/diskutil}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-/usr/bin/osascript}"
SLEEP_BIN="${SLEEP_BIN:-/bin/sleep}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
VOLUMES_ROOT="${VOLUMES_ROOT:-/Volumes}"

log() {
  local ts
  ts="$(/bin/date '+%Y-%m-%d %H:%M:%S')"
  printf '%s [ssd-mount-notify] %s\n' "${ts}" "$*"
}

# Mounted = UUID known and MountPoint is exactly /Volumes/<name>.
# Any error, empty value or other path counts as missing.
is_mounted() {
  local uuid="$1" expected="$2" mp
  mp="$("${DISKUTIL_BIN}" info -plist "${uuid}" 2>/dev/null \
    | "${PLUTIL_BIN}" -extract MountPoint raw - 2>/dev/null)" || return 1
  [[ -n "${mp}" && "${mp}" == "${expected}" ]]
}

# Message and title go in as argv, never into the AppleScript source.
notify() {
  local title="$1" message="$2"
  "${OSASCRIPT_BIN}" \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' \
    "${message}" "${title}"
}

main() {
  if [[ $# -ne 4 ]]; then
    log "usage: $0 <uuid> <volume-name> <grace-seconds> <title>"
    return 2
  fi
  local uuid="$1" volume="$2" grace="$3" title="$4"
  local uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

  if [[ ! "${uuid}" =~ ${uuid_re} ]]; then
    log "invalid UUID: ${uuid}"
    return 2
  fi
  if [[ ! "${grace}" =~ ^[0-9]+$ || ! "${POLL_INTERVAL}" =~ ^[1-9][0-9]*$ ]]; then
    log "grace (${grace}) and POLL_INTERVAL (${POLL_INTERVAL}) must be integers"
    return 2
  fi
  # Base 10, so a leading zero (08) is not read as invalid octal.
  grace=$((10#${grace}))

  local expected="${VOLUMES_ROOT}/${volume}"
  # Round up so the last check happens at or after the grace deadline.
  local polls=$(((grace + POLL_INTERVAL - 1) / POLL_INTERVAL))
  local i=0

  while true; do
    if is_mounted "${uuid}" "${expected}"; then
      log "${expected} is mounted (check $((i + 1)) of $((polls + 1)))"
      return 0
    fi
    if ((i >= polls)); then
      break
    fi
    "${SLEEP_BIN}" "${POLL_INTERVAL}"
    i=$((i + 1))
  done

  local message="SSD ${volume} is not mounted. ~/Developer is unavailable."
  log "${expected} not mounted after ${grace}s; posting notification"
  if ! notify "${title}" "${message}"; then
    log "osascript failed; notification not shown"
  fi
  return 0
}

main "$@"
