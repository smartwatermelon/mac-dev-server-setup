#!/bin/bash
# Tests app-setup/templates/ssd-mount-notify.sh with stubbed binaries.
# Run: /bin/bash tests/test-ssd-mount-notify.sh (exit 0 = all pass)

# diskutil, osascript and sleep are stubs; files go only under a mktemp dir.
# plutil is the real one: it only parses the stub's plist on stdin.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${TESTS_DIR}/../app-setup/templates/ssd-mount-notify.sh"
UUID='0AE8C5DE-4380-4942-AE72-D8784B57CA8E'
VOLUME='extra-vieille'
TITLE='MIMOLETTE'
EXPECTED_MSG="SSD ${VOLUME} is not mounted. ~/Developer is unavailable."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ssd-notify-test.XXXXXX")"
trap '/bin/rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

# --- stubs ---

# diskutil: from check STUB_MOUNT_AT (0 = never) report STUB_MOUNTPOINT.
# Before that: STUB_MISSING=1 exits 1 like a missing disk.
cat >"${WORK}/diskutil" <<'STUB'
#!/bin/bash
n=$(($(cat "${STUB_DIR}/diskutil.calls" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${STUB_DIR}/diskutil.calls"
mp=''
if [[ "${STUB_MOUNT_AT}" -gt 0 && "${n}" -ge "${STUB_MOUNT_AT}" ]]; then
  mp="${STUB_MOUNTPOINT}"
elif [[ "${STUB_MISSING}" == 1 ]]; then
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>Error</key><true/>' \
    "<key>ErrorMessage</key><string>Could not find disk: $3</string>" \
    '<key>ExitCode</key><integer>1</integer></dict></plist>'
  exit 1
fi
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict>' \
  "<key>MountPoint</key><string>${mp}</string>" \
  "<key>VolumeUUID</key><string>$3</string>" \
  '</dict></plist>'
STUB

cat >"${WORK}/osascript" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >>"${STUB_DIR}/osascript.args"
echo x >>"${STUB_DIR}/osascript.calls"
exit "${STUB_OSASCRIPT_RC:-0}"
STUB

cat >"${WORK}/sleep" <<'STUB'
#!/bin/bash
echo "$1" >>"${STUB_DIR}/sleep.calls"
STUB

/bin/chmod +x "${WORK}/diskutil" "${WORK}/osascript" "${WORK}/sleep"

count_lines() { if [[ -f "$1" ]]; then /usr/bin/wc -l <"$1" | /usr/bin/tr -d ' '; else echo 0; fi; }

# run_case <name> <mount_at> <missing> <mountpoint> <grace> [uuid]
# Sets RC, NOTIFS, SLEEPS, ARGS_FILE for assertions.
run_case() {
  local name="$1"
  STUB_DIR="${WORK}/${name}"
  /bin/mkdir -p "${STUB_DIR}"
  STUB_DIR="${STUB_DIR}" STUB_MOUNT_AT="$2" STUB_MISSING="$3" \
    STUB_MOUNTPOINT="$4" STUB_OSASCRIPT_RC="${STUB_OSASCRIPT_RC:-0}" \
    DISKUTIL_BIN="${WORK}/diskutil" OSASCRIPT_BIN="${WORK}/osascript" \
    SLEEP_BIN="${WORK}/sleep" POLL_INTERVAL=10 \
    /bin/bash "${SUT}" "${6:-${UUID}}" "${VOLUME}" "$5" "${TITLE}" \
    >"${STUB_DIR}/out.log" 2>&1
  RC=$?
  NOTIFS="$(count_lines "${STUB_DIR}/osascript.calls")"
  SLEEPS="$(count_lines "${STUB_DIR}/sleep.calls")"
  ARGS_FILE="${STUB_DIR}/osascript.args"
}

check() {
  local desc="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc}: got '${got}', want '${want}'"
  fi
}

# --- cases (grace 30 s, poll 10 s => 4 checks, 3 sleeps) ---
run_case mounted-at-start 1 1 /Volumes/extra-vieille 30
check "mounted at start: rc" "${RC}" 0
check "mounted at start: notifications" "${NOTIFS}" 0
check "mounted at start: sleeps" "${SLEEPS}" 0

run_case never-mounted 0 1 '' 30
check "never mounted: rc" "${RC}" 0
check "never mounted: notifications" "${NOTIFS}" 1
check "never mounted: sleeps" "${SLEEPS}" 3
msg_hits="$(/usr/bin/grep -cxF "${EXPECTED_MSG}" "${ARGS_FILE}")"
title_hits="$(/usr/bin/grep -cxF "${TITLE}" "${ARGS_FILE}")"
check "never mounted: message arg" "${msg_hits}" 1
check "never mounted: title arg" "${title_hits}" 1

run_case mounted-late 3 1 /Volumes/extra-vieille 30
check "mounted late: rc" "${RC}" 0
check "mounted late: notifications" "${NOTIFS}" 0
check "mounted late: sleeps" "${SLEEPS}" 2

run_case mounted-on-last-check 4 1 /Volumes/extra-vieille 30
check "mounted on last check: notifications" "${NOTIFS}" 0
check "mounted on last check: sleeps" "${SLEEPS}" 3

run_case mounted-after-grace 5 1 /Volumes/extra-vieille 30
check "mounted after grace: notifications" "${NOTIFS}" 1

run_case known-but-unmounted 0 0 '' 30
check "known but unmounted: notifications" "${NOTIFS}" 1

run_case wrong-mountpoint 1 1 '/Volumes/extra-vieille 1' 30
check "mounted at '<name> 1': notifications" "${NOTIFS}" 1

STUB_OSASCRIPT_RC=1 run_case osascript-fails 0 1 '' 30
check "osascript fails: rc" "${RC}" 0
check "osascript fails: notifications attempted" "${NOTIFS}" 1

run_case bad-uuid 0 1 '' 30 'not-a-uuid'
check "bad uuid: rc" "${RC}" 2
check "bad uuid: notifications" "${NOTIFS}" 0

run_case zero-grace 0 1 '' 0
check "zero grace: notifications" "${NOTIFS}" 1
check "zero grace: sleeps" "${SLEEPS}" 0

# 08 is invalid octal; it must still be read as 8 seconds and alert.
run_case leading-zero-grace 0 1 '' 08
check "leading-zero grace: rc" "${RC}" 0
check "leading-zero grace: notifications" "${NOTIFS}" 1

echo "ssd-mount-notify: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
