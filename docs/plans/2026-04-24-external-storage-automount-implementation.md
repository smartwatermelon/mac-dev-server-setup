# External Storage Automount — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a LaunchDaemon on MIMOLETTE that auto-mounts the Thunderbolt SSD (`/Volumes/extra-vieille`) at system boot, before sshd serves connections — so the dev environment is accessible after reboot without a macOS GUI login.

**Architecture:** One root-owned LaunchDaemon plist (`com.mac-dev-server.automount-external-storage`) loaded at boot. It keys off the APFS volume UUID via IOKit match events (primary trigger) and RunAtLoad (belt-and-suspenders fallback). A small bash helper script mounts the volume via `diskutil` with idempotent checks. Failure paths write to syslog + a tmpfs flag file + a login-banner snippet in `/etc/profile`, so SSH logins visibly surface any boot-time mount failure.

**Tech Stack:** bash, `launchctl`, `diskutil`, `plutil`, `shellcheck`, macOS LaunchDaemon plist format, IOKit matching dictionaries.

**Source spec:** [`docs/specs/2026-04-24-external-storage-automount-design.md`](../specs/2026-04-24-external-storage-automount-design.md)

> **Amendment 2026-04-24 (post-deploy simplification):** First boot on MIMOLETTE exposed a boot-time race between `RunAtLoad` (fires at PID ~349, very early) and Thunderbolt disk enumeration (completes ~12s later). The 10-second wait-loop in the helper script was too short; the mount failed, loud-fail banner fired on next login, uninstall ran clean. Rather than patch the wait-loop, we simplified: the helper script, `automount.conf`, `/etc/profile` banner, and `/var/run` flag are **all deleted**. The plist now calls `/bin/sh -c` directly with an inline 6-attempt `for` loop around `diskutil mount <UUID>`, plus `KeepAlive { SuccessfulExit: false }` and `ThrottleInterval=3600` — launchd handles retry/backoff natively. Goal "Loud on failure" is dropped (broken `~/Developer` symlinks are their own alert). See the top Design Note in the spec for full details. Task 2 (helper-script template), Task 4 (banner template), and most of Tasks 5–9 below describe artifacts that no longer exist; they're preserved as historical record of what was attempted. The post-simplification work is a separate unit of work, not retroactive edits to these tasks.
>
> **Amendment 2026-04-24 (post-Phase-4):** `LaunchEvents → com.apple.iokit.matching` was removed from the plist. On a persistently-present volume it re-fires every ~30 seconds for the session lifetime (~2,880×/day, ~400MB/year of log noise). See the Design Note in the spec. The architecture is now "RunAtLoad only; fires once per boot." Task 3's plist-template snippet below still shows the original `LaunchEvents` block for historical traceability; the committed template reflects the amended design.

**Target machine:** MIMOLETTE (Apple Silicon Mac Mini, macOS 26.4.1). **All test-phase tasks must run on MIMOLETTE itself.** Code-writing tasks can be done anywhere but the branch must be committed and pushed before running on-target if executed from elsewhere.

---

## File Structure

**Files to create:**

| Path | Responsibility |
|---|---|
| `app-setup/templates/com.mac-dev-server.automount-external-storage.plist.template` | LaunchDaemon plist with `{{UUID}}` placeholder |
| `app-setup/templates/mount-external-storage.sh.template` | Boot-time mount helper with `{{UUID}}` / `{{VOLUME}}` placeholders |
| `app-setup/templates/etc-profile-banner.sh.template` | Login-banner snippet appended to `/etc/profile` |
| `app-setup/setup-external-automount.sh` | Setup orchestrator: discover, render, install, bootstrap, uninstall |
| `docs/plans/2026-04-24-external-storage-automount-implementation.md` | This plan (already created) |

**Files to modify:**

| Path | Change |
|---|---|
| `config/config.conf.template` | Add `EXTERNAL_STORAGE_UUID=""` config var |
| `app-setup/run-app-setup.sh` | Call `setup-external-automount.sh` after `storage-setup.sh` |
| `docs/specs/2026-04-24-external-storage-automount-design.md` | Close Open Question #1 (banner path → `/etc/profile`) |

**Files deployed to target system** (by the setup script at runtime, not checked into repo):

| Target path | Owner | Mode |
|---|---|---|
| `/Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist` | `root:wheel` | `0644` |
| `/Library/Application Support/mac-dev-server/mount-external-storage.sh` | `root:wheel` | `0755` |
| `/Library/Application Support/mac-dev-server/automount.conf` | `root:wheel` | `0644` |
| `/etc/profile` | `root:wheel` | `0444` (preserved; append block between markers) |

---

## Conventions for this plan

**Static validation is our "red" step.** Shell scripts don't have a natural TDD cycle, so we substitute static validation (`shellcheck`, `bash -n`, `plutil -lint`) as the failing-test analog: write the code, verify it passes all lints, then integration-test.

**Placeholder syntax in templates:** use `{{UUID}}` and `{{VOLUME}}` (double-braces). The setup script substitutes these with `sed`.

**Every commit uses conventional-commit format matching this repo's style** (`feat:`, `fix:`, `docs:`, `chore:`). Hook runs automatically; no `--no-verify`.

**Working directory for all commands:** the repo root, accessible at either `/Volumes/extra-vieille/Workspaces/mac-dev-server-setup` or `/Users/andrewrich/Developer/mac-dev-server-setup` (symlinked).

**Branch:** `claude/feat-external-storage-automount-spec-20260424` (already created; spec already committed).

---

## Task 1: Add `EXTERNAL_STORAGE_UUID` to config template

**Files:**

- Modify: `config/config.conf.template`

- [ ] **Step 1: Read the existing config template**

```bash
grep -n "EXTERNAL_STORAGE" config/config.conf.template
```

Expected: one line showing `EXTERNAL_STORAGE_VOLUME=""`.

- [ ] **Step 2: Add `EXTERNAL_STORAGE_UUID` below the existing `EXTERNAL_STORAGE_VOLUME` line**

Change the `EXTERNAL_STORAGE_VOLUME=""` line and the line immediately after so the block reads:

```bash
# External storage for dev artifacts (Workspaces, simulators, caches).
# Leave blank to skip storage-setup.sh and external-storage automount.
EXTERNAL_STORAGE_VOLUME=""

# APFS volume UUID for automount. Auto-discovered by
# setup-external-automount.sh if left blank. Find manually with:
#   diskutil info -plist "<volume-name>" | plutil -extract VolumeUUID raw -
EXTERNAL_STORAGE_UUID=""
```

(If the existing `EXTERNAL_STORAGE_VOLUME` line has no preceding comment, leave comments off that variable — match the repo's existing style for that variable.)

- [ ] **Step 3: Verify the template still parses as shell**

```bash
bash -n config/config.conf.template
```

Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add config/config.conf.template
git commit -m "feat(config): add EXTERNAL_STORAGE_UUID to config template

Adds the APFS volume UUID variable consumed by the upcoming
setup-external-automount.sh script. Left blank by default;
setup-external-automount.sh will auto-discover from the mounted
volume at runtime."
```

---

## Task 2: Create the helper-script template

**Files:**

- Create: `app-setup/templates/mount-external-storage.sh.template`

- [ ] **Step 1: Write the template**

Create `app-setup/templates/mount-external-storage.sh.template` with exactly this content:

```bash
#!/bin/bash
#
# mount-external-storage.sh - Boot-time automount for external dev SSD.
#
# Installed by setup-external-automount.sh (part of mac-dev-server-setup).
# Invoked by /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist
# at RunAtLoad and on IOKit match events for the APFS volume UUID.
#
# Exit codes:
#   0 - mounted OK, or already mounted (idempotent)
#   1 - UUID not discoverable after wait-loop
#   2 - diskutil mount failed
#   3 - mount reported success but /Volumes/<label> missing
#   4 - config file missing or unreadable

set -uo pipefail

readonly CONF='/Library/Application Support/mac-dev-server/automount.conf'
readonly LOG='/var/log/mount-external-storage.log'
readonly FLAG='/var/run/mount-external-storage.FAILED'
readonly WAIT_SECS=10

log() {
  printf '%s [%d] %s\n' "$(date -u +%FT%TZ)" "$$" "$*" >>"${LOG}"
}

loud_fail() {
  local exit_code="$1"
  local reason="$2"
  log "FAIL (exit ${exit_code}): ${reason}"
  logger -p daemon.crit -t mac-dev-server-automount \
    "MOUNT FAILED: ${reason} (exit ${exit_code})"
  printf '%s FAIL exit=%d uuid=%s reason=%s\n' \
    "$(date -u +%FT%TZ)" "${exit_code}" "${EXTERNAL_STORAGE_UUID:-unknown}" "${reason}" \
    >"${FLAG}"
  exit "${exit_code}"
}

clear_flag() {
  [[ -f "${FLAG}" ]] && rm -f "${FLAG}"
}

# --- main ---

log "--- invocation: argv=[$*] caller=launchd ---"

if [[ ! -r "${CONF}" ]]; then
  logger -p daemon.crit -t mac-dev-server-automount \
    "config missing: ${CONF}"
  # Cannot use loud_fail (needs config) — emit minimal flag directly.
  printf '%s FAIL exit=4 reason=config-missing path=%s\n' \
    "$(date -u +%FT%TZ)" "${CONF}" >"${FLAG}"
  exit 4
fi

# shellcheck source=/dev/null
source "${CONF}"

: "${EXTERNAL_STORAGE_UUID:?EXTERNAL_STORAGE_UUID not set in ${CONF}}"
: "${EXTERNAL_STORAGE_VOLUME:?EXTERNAL_STORAGE_VOLUME not set in ${CONF}}"

log "config loaded: volume=${EXTERNAL_STORAGE_VOLUME} uuid=${EXTERNAL_STORAGE_UUID}"

# Already mounted? Idempotent early-exit.
if diskutil info "${EXTERNAL_STORAGE_UUID}" 2>/dev/null |
    grep -qE '^ *Mounted: +Yes'; then
  log "already mounted; exit 0 (idempotent)"
  clear_flag
  exit 0
fi

# Wait for the UUID to appear (guards against IOKit match arriving
# before APFS parse completes).
for ((i = 0; i < WAIT_SECS; i++)); do
  if diskutil info "${EXTERNAL_STORAGE_UUID}" >/dev/null 2>&1; then
    log "UUID visible after ${i}s"
    break
  fi
  sleep 1
done

if ! diskutil info "${EXTERNAL_STORAGE_UUID}" >/dev/null 2>&1; then
  loud_fail 1 "UUID ${EXTERNAL_STORAGE_UUID} not discoverable after ${WAIT_SECS}s"
fi

# Mount.
if ! mount_output="$(diskutil mount "${EXTERNAL_STORAGE_UUID}" 2>&1)"; then
  loud_fail 2 "diskutil mount failed: ${mount_output}"
fi
log "diskutil mount OK: ${mount_output}"

# Post-check: expected mount point exists.
mount_point="/Volumes/${EXTERNAL_STORAGE_VOLUME}"
if [[ ! -d "${mount_point}" ]]; then
  loud_fail 3 "mount reported success but ${mount_point} missing"
fi

log "mounted OK at ${mount_point}"
clear_flag
exit 0
```

- [ ] **Step 2: Static-validate the template as bash**

Template substitution uses plain values (a UUID and a volume name), so the template is already syntactically valid bash. Verify:

```bash
bash -n app-setup/templates/mount-external-storage.sh.template
```

Expected: no output (exit 0).

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck -S info app-setup/templates/mount-external-storage.sh.template
```

Expected: no output (exit 0). If SC2016 (single-quoted `$$` in `log()`) or similar informational flags fire, they indicate real issues and must be fixed — the repo policy is "all info/warning/error resolved, no `shellcheck disable` directives."

- [ ] **Step 4: Render a test copy and re-validate**

```bash
mkdir -p /tmp/automount-test
sed -e "s|{{UUID}}|0AE8C5DE-4380-4942-AE72-D8784B57CA8E|g" \
    -e "s|{{VOLUME}}|extra-vieille|g" \
    app-setup/templates/mount-external-storage.sh.template \
    >/tmp/automount-test/mount-external-storage.sh
bash -n /tmp/automount-test/mount-external-storage.sh
shellcheck -S info /tmp/automount-test/mount-external-storage.sh
rm -rf /tmp/automount-test
```

(The current template doesn't actually embed `{{UUID}}` or `{{VOLUME}}` — those values come from `automount.conf` at runtime. This render+validate is still useful as a harness for future changes that might add placeholders.)

Expected: no output from any command.

- [ ] **Step 5: Commit**

```bash
git add app-setup/templates/mount-external-storage.sh.template
git commit -m "feat(automount): add mount-external-storage.sh template

Helper script invoked by the LaunchDaemon to mount the APFS volume
identified by UUID at boot. Idempotent; loud-fails via syslog + tmpfs
flag file on any error path with distinct exit codes (1=UUID missing,
2=mount failed, 3=mount-point missing, 4=config missing)."
```

---

## Task 3: Create the LaunchDaemon plist template

**Files:**

- Create: `app-setup/templates/com.mac-dev-server.automount-external-storage.plist.template`

- [ ] **Step 1: Write the template**

Create `app-setup/templates/com.mac-dev-server.automount-external-storage.plist.template` with exactly this content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.mac-dev-server.automount-external-storage</string>

  <key>ProgramArguments</key>
  <array>
    <string>/Library/Application Support/mac-dev-server/mount-external-storage.sh</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>LaunchEvents</key>
  <dict>
    <key>com.apple.iokit.matching</key>
    <dict>
      <key>com.mac-dev-server.external-storage-appeared</key>
      <dict>
        <key>IOProviderClass</key>
        <string>AppleAPFSVolume</string>
        <key>UUID</key>
        <string>{{UUID}}</string>
      </dict>
    </dict>
  </dict>

  <key>StandardOutPath</key>
  <string>/var/log/mount-external-storage.log</string>

  <key>StandardErrorPath</key>
  <string>/var/log/mount-external-storage.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Render a test copy with a real UUID**

```bash
mkdir -p /tmp/automount-test
sed "s|{{UUID}}|0AE8C5DE-4380-4942-AE72-D8784B57CA8E|g" \
    app-setup/templates/com.mac-dev-server.automount-external-storage.plist.template \
    >/tmp/automount-test/rendered.plist
```

- [ ] **Step 3: Lint the rendered plist**

```bash
plutil -lint /tmp/automount-test/rendered.plist
```

Expected: `/tmp/automount-test/rendered.plist: OK`

- [ ] **Step 4: Verify the expected keys are present**

```bash
plutil -extract Label raw /tmp/automount-test/rendered.plist
plutil -extract RunAtLoad raw /tmp/automount-test/rendered.plist
plutil -extract 'LaunchEvents."com.apple.iokit.matching"."com.mac-dev-server.external-storage-appeared".UUID' raw /tmp/automount-test/rendered.plist
```

Expected output (one line each):

```
com.mac-dev-server.automount-external-storage
true
0AE8C5DE-4380-4942-AE72-D8784B57CA8E
```

- [ ] **Step 5: Clean up and commit**

```bash
rm -rf /tmp/automount-test
git add app-setup/templates/com.mac-dev-server.automount-external-storage.plist.template
git commit -m "feat(automount): add LaunchDaemon plist template

Declares com.mac-dev-server.automount-external-storage, invoked at
RunAtLoad and on IOKit match events for the APFS volume UUID. The
{{UUID}} placeholder is substituted at install time by
setup-external-automount.sh."
```

---

## Task 4: Create the `/etc/profile` banner template

**Files:**

- Create: `app-setup/templates/etc-profile-banner.sh.template`

- [ ] **Step 1: Write the template**

Create `app-setup/templates/etc-profile-banner.sh.template` with exactly this content:

```bash
# BEGIN mac-dev-server-automount-banner
# Alerts interactive logins if the boot-time SSD mount failed.
# Installed by setup-external-automount.sh (mac-dev-server-setup).
if [[ $- == *i* ]] && [[ -f /var/run/mount-external-storage.FAILED ]]; then
  printf '\033[1;31m⚠️  EXTERNAL STORAGE MOUNT FAILED AT BOOT\033[0m\n'
  printf '   Reason: %s\n' "$(cat /var/run/mount-external-storage.FAILED 2>/dev/null)"
  printf '   Log:    /var/log/mount-external-storage.log\n\n'
fi
# END mac-dev-server-automount-banner
```

The `BEGIN`/`END` marker lines let the setup script idempotently insert or remove the block from `/etc/profile` using `sed`.

- [ ] **Step 2: Static-validate**

```bash
bash -n app-setup/templates/etc-profile-banner.sh.template
shellcheck -S info app-setup/templates/etc-profile-banner.sh.template
```

Expected: no output from either.

- [ ] **Step 3: Smoke-test the banner logic**

```bash
# Simulate failure flag
echo "2026-04-24T00:00:00Z FAIL exit=1 reason=test" >/tmp/fake-FAILED
# Temporarily symlink the flag path for the test (requires sudo to touch /var/run)
# Instead, inline-test with a variable substitution:
FLAG_CONTENT="2026-04-24T00:00:00Z FAIL exit=1 reason=test"
bash -c "$(sed "s|/var/run/mount-external-storage.FAILED|/tmp/fake-FAILED|g" app-setup/templates/etc-profile-banner.sh.template)" -i
# Expected: red banner text printed to stdout
rm -f /tmp/fake-FAILED
# Run again with flag absent:
bash -c "$(sed "s|/var/run/mount-external-storage.FAILED|/tmp/fake-FAILED|g" app-setup/templates/etc-profile-banner.sh.template)" -i
# Expected: no output
```

(`-i` makes bash treat the shell as interactive so `[[ $- == *i* ]]` is true.)

Expected: first invocation prints a red-colored banner with "EXTERNAL STORAGE MOUNT FAILED" visible; second invocation prints nothing.

- [ ] **Step 4: Commit**

```bash
git add app-setup/templates/etc-profile-banner.sh.template
git commit -m "feat(automount): add /etc/profile login-banner template

Block with BEGIN/END markers appended to /etc/profile by
setup-external-automount.sh. Fires for interactive shells only
(SSH logins), no-op for non-interactive shells (cron, scripts).
Surfaces boot-time mount failures so a human SSH-ing in cannot
miss them."
```

---

## Task 5: Setup script — skeleton, flags, UUID discovery

**Files:**

- Create: `app-setup/setup-external-automount.sh`

- [ ] **Step 1: Write the initial script skeleton**

Create `app-setup/setup-external-automount.sh` with exactly this content:

```bash
#!/usr/bin/env bash
#
# setup-external-automount.sh - Install boot-time SSD automount on target.
#
# Creates a LaunchDaemon that mounts the external APFS volume at boot so
# the dev environment is SSH-accessible without a macOS GUI login.
#
# Flags:
#   --dry-run       Show what would change; no writes to /Library/ or /etc/
#   --install-only  Install files but do not launchctl bootstrap
#   --uninstall     Remove the daemon and all installed files
#
# Part of mac-dev-server-setup. See:
#   docs/specs/2026-04-24-external-storage-automount-design.md
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-04-24

set -euo pipefail

# --- paths ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Target install paths
readonly TARGET_PLIST='/Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist'
readonly TARGET_SUPPORT_DIR='/Library/Application Support/mac-dev-server'
readonly TARGET_HELPER="${TARGET_SUPPORT_DIR}/mount-external-storage.sh"
readonly TARGET_CONF="${TARGET_SUPPORT_DIR}/automount.conf"
readonly TARGET_PROFILE='/etc/profile'
readonly LAUNCHD_LABEL='com.mac-dev-server.automount-external-storage'

# Template paths
readonly TMPL_PLIST="${TEMPLATES_DIR}/com.mac-dev-server.automount-external-storage.plist.template"
readonly TMPL_HELPER="${TEMPLATES_DIR}/mount-external-storage.sh.template"
readonly TMPL_BANNER="${TEMPLATES_DIR}/etc-profile-banner.sh.template"

# Marker strings for /etc/profile idempotent insert
readonly PROFILE_BEGIN='# BEGIN mac-dev-server-automount-banner'
readonly PROFILE_END='# END mac-dev-server-automount-banner'

# --- arg parsing ---
MODE='install'  # install | dry-run | install-only | uninstall
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      MODE='dry-run' ;;
    --install-only) MODE='install-only' ;;
    --uninstall)    MODE='uninstall' ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
  shift
done

# --- logging helpers ---
show_log()  { printf '%s [setup-automount] %s\n' "$(date +%H:%M:%S)" "$*"; }
show_err()  { printf '%s [setup-automount] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
show_plan() { printf '   [plan] %s\n' "$*"; }

# --- config loading ---
load_config() {
  local conf="${REPO_ROOT}/config/config.conf"
  if [[ ! -f "${conf}" ]]; then
    show_err "config not found: ${conf}"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${conf}"
  : "${SERVER_NAME:?SERVER_NAME not set in ${conf}}"
  : "${EXTERNAL_STORAGE_VOLUME:?EXTERNAL_STORAGE_VOLUME not set in ${conf}}"
}

# --- hostname guard ---
verify_on_target() {
  local this_host
  this_host="$(hostname -s)"
  if [[ "${this_host}" != "${SERVER_NAME}" ]]; then
    show_err "this script must run on ${SERVER_NAME}, got: ${this_host}"
    show_err "refusing to install a LaunchDaemon on a non-target machine"
    exit 1
  fi
  show_log "hostname check OK: ${this_host}"
}

# --- UUID discovery ---
discover_uuid() {
  local volume="$1"
  local uuid

  if [[ ! -d "/Volumes/${volume}" ]]; then
    show_err "volume /Volumes/${volume} not mounted; cannot discover UUID"
    show_err "plug in and mount the drive, then re-run this script"
    exit 1
  fi

  uuid="$(diskutil info -plist "${volume}" \
    | plutil -extract VolumeUUID raw - 2>/dev/null)" || {
    show_err "failed to read VolumeUUID for /Volumes/${volume}"
    exit 1
  }

  if [[ -z "${uuid}" || "${uuid}" == "null" ]]; then
    show_err "empty VolumeUUID for /Volumes/${volume}"
    exit 1
  fi

  printf '%s' "${uuid}"
}

# --- template rendering ---
render_template() {
  local tmpl="$1"
  local uuid="$2"
  local volume="$3"
  sed -e "s|{{UUID}}|${uuid}|g" \
      -e "s|{{VOLUME}}|${volume}|g" \
      "${tmpl}"
}

# --- static validation ---
validate_plist() {
  local file="$1"
  if ! plutil -lint "${file}" >/dev/null; then
    show_err "plutil -lint failed: ${file}"
    return 1
  fi
}

validate_script() {
  local file="$1"
  if ! bash -n "${file}"; then
    show_err "bash -n failed: ${file}"
    return 1
  fi
  if ! shellcheck -S info "${file}"; then
    show_err "shellcheck failed: ${file}"
    return 1
  fi
}

# --- dispatch (placeholder; expanded in Task 6/7/8/9) ---
main() {
  load_config
  verify_on_target

  local uuid
  uuid="$(discover_uuid "${EXTERNAL_STORAGE_VOLUME}")"
  show_log "discovered UUID: ${uuid}"

  case "${MODE}" in
    dry-run)       show_log "dry-run mode (not yet implemented; see Task 6)" ;;
    install-only)  show_log "install-only mode (not yet implemented; see Task 7)" ;;
    install)       show_log "install mode (not yet implemented; see Task 8)" ;;
    uninstall)     show_log "uninstall mode (not yet implemented; see Task 9)" ;;
  esac
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x app-setup/setup-external-automount.sh
```

- [ ] **Step 3: Static-validate**

```bash
bash -n app-setup/setup-external-automount.sh
shellcheck -S info app-setup/setup-external-automount.sh
```

Expected: both exit 0 with no output.

- [ ] **Step 4: Smoke-test hostname guard on target**

Must run on MIMOLETTE. Requires `config/config.conf` to exist with `SERVER_NAME=MIMOLETTE` and `EXTERNAL_STORAGE_VOLUME=extra-vieille`.

```bash
# First, verify the config has the right values (do not print tokens)
grep -E '^(SERVER_NAME|EXTERNAL_STORAGE_VOLUME)=' config/config.conf
```

Expected: two lines with the right values. If `config/config.conf` does not exist, copy from template and populate before proceeding:

```bash
test -f config/config.conf || cp config/config.conf.template config/config.conf
# Then edit config/config.conf to set SERVER_NAME=MIMOLETTE and EXTERNAL_STORAGE_VOLUME=extra-vieille
```

Run the script in the default install mode:

```bash
./app-setup/setup-external-automount.sh
```

Expected: logs show `hostname check OK: MIMOLETTE`, `discovered UUID: 0AE8C5DE-4380-4942-AE72-D8784B57CA8E`, and `install mode (not yet implemented; see Task 8)`. Exit 0.

- [ ] **Step 5: Commit**

```bash
git add app-setup/setup-external-automount.sh
git commit -m "feat(automount): add setup script skeleton

Argument parsing, config loading, hostname guard against running on
dev machines, UUID auto-discovery, and shared rendering + validation
helpers. Mode dispatch is stubbed; subsequent tasks implement
dry-run, install-only, install, and uninstall flows."
```

---

## Task 6: Setup script — `--dry-run` mode

**Files:**

- Modify: `app-setup/setup-external-automount.sh`

- [ ] **Step 1: Replace the `main()` function and add a `do_dry_run()` function**

Find the `main()` function in `app-setup/setup-external-automount.sh` and replace it, and add the new function above it:

```bash
# --- dry-run ---
do_dry_run() {
  local uuid="$1"
  local volume="$2"
  local tmpdir
  tmpdir="$(mktemp -d -t automount-dryrun)"
  trap 'rm -rf "${tmpdir}"' RETURN

  render_template "${TMPL_PLIST}"  "${uuid}" "${volume}" >"${tmpdir}/rendered.plist"
  render_template "${TMPL_HELPER}" "${uuid}" "${volume}" >"${tmpdir}/rendered.sh"
  cp "${TMPL_BANNER}" "${tmpdir}/rendered-banner.sh"

  validate_plist  "${tmpdir}/rendered.plist"
  validate_script "${tmpdir}/rendered.sh"
  validate_script "${tmpdir}/rendered-banner.sh"

  show_log "dry-run: all renders pass static validation"
  echo
  show_plan "would install (root:wheel 0644):"
  show_plan "   ${TARGET_PLIST}"
  show_plan "would install (root:wheel 0755):"
  show_plan "   ${TARGET_HELPER}"
  show_plan "would install (root:wheel 0644):"
  show_plan "   ${TARGET_CONF}"
  show_plan "would append BEGIN/END block to ${TARGET_PROFILE}"
  show_plan "would run: sudo launchctl bootstrap system ${TARGET_PLIST}"
  echo
  show_plan "rendered plist:"
  sed 's/^/      /' "${tmpdir}/rendered.plist"
  echo
  show_plan "rendered automount.conf contents:"
  printf '      EXTERNAL_STORAGE_VOLUME=%s\n' "${volume}"
  printf '      EXTERNAL_STORAGE_UUID=%s\n'   "${uuid}"
}

# --- dispatch ---
main() {
  load_config
  verify_on_target

  local uuid
  uuid="$(discover_uuid "${EXTERNAL_STORAGE_VOLUME}")"
  show_log "discovered UUID: ${uuid}"

  case "${MODE}" in
    dry-run)       do_dry_run "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
    install-only)  show_log "install-only mode (not yet implemented; see Task 7)" ;;
    install)       show_log "install mode (not yet implemented; see Task 8)" ;;
    uninstall)     show_log "uninstall mode (not yet implemented; see Task 9)" ;;
  esac
}

main "$@"
```

- [ ] **Step 2: Static-validate**

```bash
bash -n app-setup/setup-external-automount.sh
shellcheck -S info app-setup/setup-external-automount.sh
```

Expected: both exit 0 with no output.

- [ ] **Step 3: Run `--dry-run` on target**

```bash
./app-setup/setup-external-automount.sh --dry-run
```

Expected: successful hostname check, UUID discovery, static validation passes on all three rendered files, printed plan lists exactly 4 install targets + the launchctl command, full rendered plist XML printed, automount.conf contents printed. Nothing under `/Library/` or `/etc/` touched (verify in next step).

- [ ] **Step 4: Verify nothing was installed**

```bash
ls /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist 2>/dev/null \
  && echo "FAIL: plist should not exist" || echo "OK: plist not installed"

ls "/Library/Application Support/mac-dev-server/" 2>/dev/null \
  && echo "FAIL: support dir should not exist" || echo "OK: support dir not present"

grep -c "mac-dev-server-automount-banner" /etc/profile \
  && echo "FAIL: banner should not be in /etc/profile" || echo "OK: /etc/profile unchanged"
```

Expected: all three checks print OK.

- [ ] **Step 5: Commit**

```bash
git add app-setup/setup-external-automount.sh
git commit -m "feat(automount): implement --dry-run mode

Renders all three templates to a tempdir, runs plutil -lint and
shellcheck against the rendered output, and prints a plan of the
install actions without touching /Library/ or /etc/. Maps to Phase
1 of the test plan."
```

---

## Task 7: Setup script — `--install-only` mode

**Files:**

- Modify: `app-setup/setup-external-automount.sh`

- [ ] **Step 1: Add `do_install_only()` and update dispatch**

Insert the following function above `main()`:

```bash
# --- file install (no launchctl) ---
do_install_only() {
  local uuid="$1"
  local volume="$2"
  local tmpdir
  tmpdir="$(mktemp -d -t automount-install)"
  trap 'rm -rf "${tmpdir}"' RETURN

  # Render + validate before any write under /Library/ or /etc/.
  render_template "${TMPL_PLIST}"  "${uuid}" "${volume}" >"${tmpdir}/rendered.plist"
  render_template "${TMPL_HELPER}" "${uuid}" "${volume}" >"${tmpdir}/rendered.sh"
  cp "${TMPL_BANNER}" "${tmpdir}/rendered-banner.sh"
  validate_plist  "${tmpdir}/rendered.plist"
  validate_script "${tmpdir}/rendered.sh"
  validate_script "${tmpdir}/rendered-banner.sh"

  show_log "all renders pass static validation; installing"

  # Support directory
  sudo /bin/mkdir -p "${TARGET_SUPPORT_DIR}"
  sudo /usr/sbin/chown root:wheel "${TARGET_SUPPORT_DIR}"
  sudo /bin/chmod 0755 "${TARGET_SUPPORT_DIR}"

  # Helper script
  sudo /usr/bin/install -o root -g wheel -m 0755 \
    "${tmpdir}/rendered.sh" "${TARGET_HELPER}"
  show_log "installed ${TARGET_HELPER}"

  # automount.conf
  local conf_tmp="${tmpdir}/automount.conf"
  {
    printf 'EXTERNAL_STORAGE_VOLUME=%s\n' "${volume}"
    printf 'EXTERNAL_STORAGE_UUID=%s\n'   "${uuid}"
  } >"${conf_tmp}"
  sudo /usr/bin/install -o root -g wheel -m 0644 \
    "${conf_tmp}" "${TARGET_CONF}"
  show_log "installed ${TARGET_CONF}"

  # LaunchDaemon plist
  sudo /usr/bin/install -o root -g wheel -m 0644 \
    "${tmpdir}/rendered.plist" "${TARGET_PLIST}"
  show_log "installed ${TARGET_PLIST}"

  # /etc/profile banner block (idempotent insert)
  if grep -qF "${PROFILE_BEGIN}" "${TARGET_PROFILE}"; then
    show_log "/etc/profile banner block already present; leaving unchanged"
  else
    local profile_new="${tmpdir}/profile.new"
    sudo /bin/cat "${TARGET_PROFILE}" >"${profile_new}"
    echo >>"${profile_new}"
    cat "${tmpdir}/rendered-banner.sh" >>"${profile_new}"
    sudo /usr/bin/install -o root -g wheel -m 0444 \
      "${profile_new}" "${TARGET_PROFILE}"
    show_log "appended banner block to ${TARGET_PROFILE}"
  fi
}
```

Update the `main()` case statement's `install-only` branch:

```bash
    install-only)  do_install_only "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
```

- [ ] **Step 2: Static-validate**

```bash
bash -n app-setup/setup-external-automount.sh
shellcheck -S info app-setup/setup-external-automount.sh
```

Expected: both exit 0 with no output.

- [ ] **Step 3: Run `--install-only` on target**

```bash
./app-setup/setup-external-automount.sh --install-only
```

Expected: logs show validation passing, four files installed, banner appended to `/etc/profile`.

- [ ] **Step 4: Verify installed artifacts**

```bash
ls -la /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist
ls -la "/Library/Application Support/mac-dev-server/"
sudo plutil -lint /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist
sudo bash -n /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
grep -c "mac-dev-server-automount-banner" /etc/profile
sudo launchctl list | grep automount-external-storage || echo "OK: not loaded yet"
```

Expected:

- plist: `root wheel 0644`, plutil OK
- support dir: plist, helper (0755), conf (0644), all root-owned
- `/etc/profile`: grep count = 2 (BEGIN and END markers)
- launchctl: "OK: not loaded yet"

- [ ] **Step 5: Test idempotency**

```bash
./app-setup/setup-external-automount.sh --install-only
grep -c "mac-dev-server-automount-banner" /etc/profile
```

Expected: no failures, logs mention "banner block already present; leaving unchanged", grep count still = 2.

- [ ] **Step 6: Commit**

```bash
git add app-setup/setup-external-automount.sh
git commit -m "feat(automount): implement --install-only mode

Renders + validates templates, then installs four target files with
correct owner/mode (plist, helper script, automount.conf) and
appends a BEGIN/END-tagged banner block to /etc/profile. Idempotent:
re-running leaves /etc/profile unchanged on the second pass. Does
not invoke launchctl bootstrap. Maps to Phase 2 of the test plan."
```

---

## Task 8: Setup script — main `install` mode (launchctl bootstrap + rollback)

**Files:**

- Modify: `app-setup/setup-external-automount.sh`

- [ ] **Step 1: Add `do_install()` and update dispatch**

Insert the following function above `main()`:

```bash
# --- rollback on bootstrap failure ---
rollback_plist() {
  if [[ -f "${TARGET_PLIST}" ]]; then
    show_err "rolling back: removing ${TARGET_PLIST}"
    sudo /bin/rm -f "${TARGET_PLIST}" || true
  fi
}

# --- full install: file copy + launchctl bootstrap ---
do_install() {
  local uuid="$1"
  local volume="$2"

  do_install_only "${uuid}" "${volume}"

  show_log "loading LaunchDaemon"
  if ! sudo /bin/launchctl bootstrap system "${TARGET_PLIST}" 2>/tmp/bootstrap.err; then
    show_err "launchctl bootstrap failed:"
    cat /tmp/bootstrap.err >&2
    rm -f /tmp/bootstrap.err
    rollback_plist
    exit 1
  fi
  rm -f /tmp/bootstrap.err

  # Verify loaded
  if ! sudo /bin/launchctl list | grep -q "${LAUNCHD_LABEL}"; then
    show_err "daemon did not appear in launchctl list after bootstrap"
    rollback_plist
    exit 1
  fi
  show_log "daemon loaded: ${LAUNCHD_LABEL}"

  show_log "install complete"
  show_log "next: run Phase 5 of the test plan (fdesetup authrestart) to verify boot behavior"
}
```

Update the `main()` case statement's `install` branch:

```bash
    install)       do_install "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
```

- [ ] **Step 2: Static-validate**

```bash
bash -n app-setup/setup-external-automount.sh
shellcheck -S info app-setup/setup-external-automount.sh
```

Expected: both exit 0 with no output.

- [ ] **Step 3: If a daemon is already loaded from Task 7's leftovers, bootout first**

```bash
sudo launchctl list | grep automount-external-storage \
  && sudo launchctl bootout system /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist \
  || echo "no daemon loaded; proceed"
```

- [ ] **Step 4: Run full install on target**

```bash
./app-setup/setup-external-automount.sh
```

Expected: install-only actions succeed, `daemon loaded: com.mac-dev-server.automount-external-storage`, closing hint printed.

- [ ] **Step 5: Verify daemon loaded**

```bash
sudo launchctl list | grep automount-external-storage
sudo launchctl print system/com.mac-dev-server.automount-external-storage | head -20
```

Expected: daemon appears in `launchctl list`; `launchctl print` shows `state = running` or `state = not running` with `last exit code = 0` (depending on when it last fired).

- [ ] **Step 6: Verify the helper script has already run at least once**

```bash
sudo cat /var/log/mount-external-storage.log | tail -20
ls /Volumes/extra-vieille >/dev/null && echo "OK: mount present"
```

Expected: log entries from the daemon firing at `launchctl bootstrap` time; mount present.

- [ ] **Step 7: Commit**

```bash
git add app-setup/setup-external-automount.sh
git commit -m "feat(automount): implement full install with rollback

Wraps do_install_only, then launchctl bootstraps the daemon and
verifies it appears in launchctl list. If bootstrap fails or the
daemon is missing after, removes the plist from /Library/LaunchDaemons/
so a subsequent reboot does not try to load a known-broken daemon.
Maps to Phase 3 of the test plan."
```

---

## Task 9: Setup script — `--uninstall` mode

**Files:**

- Modify: `app-setup/setup-external-automount.sh`

- [ ] **Step 1: Add `do_uninstall()` and update dispatch**

Insert above `main()`:

```bash
# --- uninstall ---
do_uninstall() {
  show_log "uninstalling"

  # Bootout (tolerate not-loaded)
  if sudo /bin/launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then
    show_log "booting out ${LAUNCHD_LABEL}"
    sudo /bin/launchctl bootout system "${TARGET_PLIST}" || {
      show_err "bootout failed; continuing to remove files"
    }
  else
    show_log "daemon not loaded; skipping bootout"
  fi

  # Remove target files
  if [[ -f "${TARGET_PLIST}" ]]; then
    sudo /bin/rm -f "${TARGET_PLIST}"
    show_log "removed ${TARGET_PLIST}"
  fi
  if [[ -d "${TARGET_SUPPORT_DIR}" ]]; then
    sudo /bin/rm -rf "${TARGET_SUPPORT_DIR}"
    show_log "removed ${TARGET_SUPPORT_DIR}"
  fi

  # Strip banner block from /etc/profile
  if grep -qF "${PROFILE_BEGIN}" "${TARGET_PROFILE}"; then
    local tmpfile
    tmpfile="$(mktemp -t profile-new)"
    sudo /usr/bin/sed \
      -e "\\|${PROFILE_BEGIN}|,\\|${PROFILE_END}|d" \
      "${TARGET_PROFILE}" >"${tmpfile}"
    sudo /usr/bin/install -o root -g wheel -m 0444 \
      "${tmpfile}" "${TARGET_PROFILE}"
    rm -f "${tmpfile}"
    show_log "removed banner block from ${TARGET_PROFILE}"
  fi

  # Clear runtime flag, just in case
  sudo /bin/rm -f /var/run/mount-external-storage.FAILED

  show_log "uninstall complete"
}
```

Update the `main()` dispatch: since uninstall doesn't need UUID discovery or the volume to be mounted, short-circuit before those steps when in uninstall mode. Replace `main()` with:

```bash
main() {
  load_config
  verify_on_target

  if [[ "${MODE}" == 'uninstall' ]]; then
    do_uninstall
    return 0
  fi

  local uuid
  uuid="$(discover_uuid "${EXTERNAL_STORAGE_VOLUME}")"
  show_log "discovered UUID: ${uuid}"

  case "${MODE}" in
    dry-run)       do_dry_run      "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
    install-only)  do_install_only "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
    install)       do_install      "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
  esac
}
```

- [ ] **Step 2: Static-validate**

```bash
bash -n app-setup/setup-external-automount.sh
shellcheck -S info app-setup/setup-external-automount.sh
```

Expected: both exit 0 with no output.

- [ ] **Step 3: Smoke-test uninstall on target** (this WILL tear down what Task 8 built)

```bash
./app-setup/setup-external-automount.sh --uninstall
```

Expected: bootout logged, three removal log lines, banner-removal log line, "uninstall complete".

- [ ] **Step 4: Verify clean state**

```bash
ls /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist 2>/dev/null \
  && echo "FAIL" || echo "OK: plist gone"
ls "/Library/Application Support/mac-dev-server/" 2>/dev/null \
  && echo "FAIL" || echo "OK: support dir gone"
grep -c "mac-dev-server-automount-banner" /etc/profile \
  && echo "FAIL: banner still in /etc/profile" || echo "OK: /etc/profile cleaned"
sudo launchctl list | grep automount-external-storage \
  && echo "FAIL: still loaded" || echo "OK: not loaded"
```

Expected: all four checks print OK.

- [ ] **Step 5: Test idempotent uninstall (nothing installed)**

```bash
./app-setup/setup-external-automount.sh --uninstall
```

Expected: no errors; log lines say "daemon not loaded; skipping bootout" and nothing to remove.

- [ ] **Step 6: Re-install to restore daemon (so later tasks can proceed)**

```bash
./app-setup/setup-external-automount.sh
```

Expected: successful full install per Task 8.

- [ ] **Step 7: Commit**

```bash
git add app-setup/setup-external-automount.sh
git commit -m "feat(automount): implement --uninstall mode

Boots out the LaunchDaemon, removes the plist, support dir, and
banner block from /etc/profile. Idempotent (safe to re-run).
Clears any lingering /var/run flag. Maps to Phase 7 of the test
plan."
```

---

## Task 10: Integrate with `run-app-setup.sh`

**Files:**

- Modify: `app-setup/run-app-setup.sh`

- [ ] **Step 1: Read the existing script to find the storage-setup invocation**

```bash
grep -n "storage-setup" app-setup/run-app-setup.sh
```

Expected: one or more lines showing how `storage-setup.sh` is currently invoked.

- [ ] **Step 2: Add `setup-external-automount.sh` immediately after the storage-setup invocation**

Match the style of the existing invocation. If it currently looks like:

```bash
"${SCRIPT_DIR}/storage-setup.sh"
```

Add directly below:

```bash
"${SCRIPT_DIR}/setup-external-automount.sh"
```

If `storage-setup.sh` is gated behind `if [[ -n "${EXTERNAL_STORAGE_VOLUME}" ]]`, wrap the automount call in the same guard.

- [ ] **Step 3: Static-validate**

```bash
bash -n app-setup/run-app-setup.sh
shellcheck -S info app-setup/run-app-setup.sh
```

Expected: both exit 0.

- [ ] **Step 4: Dry-run the orchestrator if it supports that flag**

If `run-app-setup.sh` supports a `--dry-run` or similar, invoke it here. If not, skip.

- [ ] **Step 5: Commit**

```bash
git add app-setup/run-app-setup.sh
git commit -m "feat(automount): wire setup-external-automount.sh into run-app-setup.sh

Runs immediately after storage-setup.sh so the LaunchDaemon is
installed once storage symlinks are in place. Gated on the same
EXTERNAL_STORAGE_VOLUME config as storage-setup."
```

---

## Task 11: Close Open Question #1 in the spec

**Files:**

- Modify: `docs/specs/2026-04-24-external-storage-automount-design.md`

- [ ] **Step 1: Update the "Open Questions" section to reflect the resolution**

Find the "Open Questions" section. Replace the first bullet:

```markdown
- **Correct path for login-banner snippet.** `/etc/bashrc.d/` vs
  `/etc/profile.d/` vs `/etc/profile` append vs `/etc/zshenv` — confirm
  during implementation. [...]
```

With:

```markdown
- ~~**Correct path for login-banner snippet.**~~ **Resolved 2026-04-24:**
  Append a BEGIN/END-tagged block to `/etc/profile`. On this Mac,
  `/etc/profile` already sources `/etc/bashrc` for bash shells and fires
  for all SSH login shells. The snippet guards with `[[ $- == *i* ]]` so
  non-interactive shells (scripts, cron) see no output.
```

- [ ] **Step 2: Commit**

```bash
git add docs/specs/2026-04-24-external-storage-automount-design.md
git commit -m "docs: resolve open question on login-banner path

Picked /etc/profile append over /etc/bashrc.d/ because /etc/profile
already sources /etc/bashrc for bash and fires for all SSH login
shells. Block uses BEGIN/END markers for idempotent
install/uninstall."
```

---

## Task 12: Test Phase 0 — Static validation (already covered)

Phase 0 was executed implicitly by Tasks 2, 3, 4, 5, 6, 7, 8, 9, 10's static-validation steps. No additional action.

- [ ] **Step 1: Confirm all template files pass final lints**

```bash
shellcheck -S info app-setup/*.sh app-setup/templates/*.sh.template
bash -n app-setup/*.sh app-setup/templates/*.sh.template
plutil -lint app-setup/templates/*.plist.template 2>&1 || true
# plist template has {{UUID}} placeholder, so plutil -lint alone will fail.
# Render + lint:
mkdir -p /tmp/automount-test
sed "s|{{UUID}}|0AE8C5DE-4380-4942-AE72-D8784B57CA8E|g" \
    app-setup/templates/com.mac-dev-server.automount-external-storage.plist.template \
    >/tmp/automount-test/rendered.plist
plutil -lint /tmp/automount-test/rendered.plist
rm -rf /tmp/automount-test
```

Expected: all lints pass, the rendered plist passes `plutil -lint`.

---

## Task 13: Test Phase 1 — Dry-run install on target

- [ ] **Step 1: Confirm the target is in a clean state first**

```bash
./app-setup/setup-external-automount.sh --uninstall
```

Expected: reports clean state or successfully removes anything present.

- [ ] **Step 2: Run `--dry-run`**

```bash
./app-setup/setup-external-automount.sh --dry-run
```

Expected: passes lints, prints planned changes, nothing written.

- [ ] **Step 3: Confirm zero filesystem changes**

```bash
ls /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist 2>/dev/null \
  && echo "FAIL" || echo "OK: plist not installed"
ls "/Library/Application Support/mac-dev-server/" 2>/dev/null \
  && echo "FAIL" || echo "OK: support dir not present"
grep -c "mac-dev-server-automount-banner" /etc/profile \
  && echo "FAIL" || echo "OK: /etc/profile unchanged"
```

Expected: all three checks print OK.

- [ ] **Step 4: Commit a marker log (no code change; this is an acceptance record)**

```bash
# No commit needed — this phase is execution-only. Note completion in the PR description.
echo "Phase 1 passed: $(date -u +%FT%TZ)" >>/tmp/automount-test-log
```

---

## Task 14: Test Phase 2 — Real install, daemon not yet loaded

- [ ] **Step 1: Run `--install-only`**

```bash
./app-setup/setup-external-automount.sh --install-only
```

Expected: all four target files installed, banner appended to `/etc/profile`, no launchctl invocation.

- [ ] **Step 2: Validate installed artifacts**

```bash
sudo plutil -lint /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist
sudo bash -n /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
sudo shellcheck -S info /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
cat "/Library/Application Support/mac-dev-server/automount.conf"
```

Expected: plist OK, shell script lints clean, automount.conf has the correct UUID and volume.

- [ ] **Step 3: Confirm daemon not loaded**

```bash
sudo launchctl list | grep automount-external-storage && echo "FAIL" || echo "OK: not loaded"
```

Expected: OK.

- [ ] **Step 4: Test idempotency**

```bash
./app-setup/setup-external-automount.sh --install-only
grep -c "mac-dev-server-automount-banner" /etc/profile
```

Expected: no errors; grep count still 2.

---

## Task 15: Test Phase 3 — Load daemon, happy-path runtime

- [ ] **Step 1: Load the daemon**

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist
sudo launchctl list | grep automount-external-storage
```

Expected: daemon listed with PID or recent exit status.

- [ ] **Step 2: Run the helper manually while SSD is mounted**

```bash
sudo /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
echo "exit: $?"
sudo tail -5 /var/log/mount-external-storage.log
```

Expected: exit 0; log tail includes "already mounted; exit 0 (idempotent)".

- [ ] **Step 3: Unmount and re-run the helper**

```bash
sudo diskutil unmount /Volumes/extra-vieille
sudo /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
echo "exit: $?"
sudo tail -5 /var/log/mount-external-storage.log
ls /Volumes/extra-vieille >/dev/null && echo "OK: remounted"
```

Expected: exit 0; log shows "diskutil mount OK" and "mounted OK at /Volumes/extra-vieille"; remount confirmed.

---

## Task 16: Test Phase 4 — Loud-fail validation (no reboot)

- [ ] **Step 1: Back up `automount.conf`**

```bash
sudo cp "/Library/Application Support/mac-dev-server/automount.conf" \
        "/Library/Application Support/mac-dev-server/automount.conf.bak"
```

- [ ] **Step 2: Inject a bogus UUID**

```bash
sudo tee "/Library/Application Support/mac-dev-server/automount.conf" <<'EOF'
EXTERNAL_STORAGE_VOLUME=extra-vieille
EXTERNAL_STORAGE_UUID=00000000-0000-0000-0000-000000000000
EOF
```

- [ ] **Step 3: Run the helper and expect failure**

```bash
sudo /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
echo "exit: $?"
```

Expected: exit 1, helper script printed no output (it writes to log), and the failure cascade below fires.

- [ ] **Step 4: Verify all three loud-fail layers**

```bash
# Layer 1 — syslog
log show --last 5m --predicate 'process == "logger"' --info | grep mac-dev-server-automount | head -3

# Layer 2 — flag file
ls -la /var/run/mount-external-storage.FAILED
cat /var/run/mount-external-storage.FAILED

# Layer 3 — login banner (open a fresh SSH session and observe)
# From a DIFFERENT machine:
#   ssh MIMOLETTE.local true
# On the target, the banner is set up in /etc/profile; to test locally:
bash -l -c 'true'
```

Expected:

- Layer 1: syslog entry `MOUNT FAILED: UUID ... not discoverable after 10s (exit 1)`
- Layer 2: flag file exists with `exit=1 reason=UUID ... not discoverable`
- Layer 3: opening a fresh interactive shell prints the red banner

- [ ] **Step 5: Restore config and verify recovery**

```bash
sudo mv "/Library/Application Support/mac-dev-server/automount.conf.bak" \
        "/Library/Application Support/mac-dev-server/automount.conf"
sudo /Library/Application\ Support/mac-dev-server/mount-external-storage.sh
echo "exit: $?"
ls /var/run/mount-external-storage.FAILED 2>/dev/null && echo "FAIL" || echo "OK: flag cleared"
bash -l -c 'true'
```

Expected: exit 0; flag file gone; new shell prints no banner.

---

## Task 17: Test Phase 5 — Reboot with preauth (first time trusting boot firing)

This is the first task where we trust the daemon to fire at boot.

- [ ] **Step 1: Confirm clean state**

```bash
ls /var/run/mount-external-storage.FAILED 2>/dev/null && echo "FAIL" || echo "OK"
sudo tail -1 /var/log/mount-external-storage.log
```

Expected: OK; last log entry is the Task 15/16 idempotent success.

- [ ] **Step 2: Preauthed reboot**

From the dev machine (or on-target but the SSH session will disconnect):

```bash
ssh MIMOLETTE.local 'sudo fdesetup authrestart'
```

Expected: SSH disconnects; Mini reboots; comes back up without needing manual FileVault entry.

- [ ] **Step 3: Poll for SSH readiness**

From the dev machine:

```bash
until ssh -o ConnectTimeout=3 MIMOLETTE.local true 2>/dev/null; do
  sleep 2
done
echo "SSH ready at $(date -u +%FT%TZ)"
```

- [ ] **Step 4: Verify SSD mounted at boot**

```bash
ssh MIMOLETTE.local 'ls /Volumes/extra-vieille >/dev/null && echo MOUNTED || echo UNMOUNTED'
ssh MIMOLETTE.local 'sudo tail -20 /var/log/mount-external-storage.log'
ssh MIMOLETTE.local 'ls /var/run/mount-external-storage.FAILED 2>/dev/null && echo FAIL-PRESENT || echo FAIL-ABSENT'
```

Expected: `MOUNTED`; log tail shows RunAtLoad and/or IOKit-match invocation with successful mount; `FAIL-ABSENT`.

- [ ] **Step 5: Verify the dev environment works**

```bash
ssh MIMOLETTE.local 'ls ~/Developer/dotfiles && echo OK'
ssh MIMOLETTE.local 'which claude && claude --version'
```

Expected: dotfiles visible; claude command resolves (assumes claude-wrapper on SSD is in PATH via dotfiles).

---

## Task 18: Test Phase 6 — Simulated missing-SSD reboot

- [ ] **Step 1: Inject bogus UUID into automount.conf**

```bash
ssh MIMOLETTE.local 'sudo cp "/Library/Application Support/mac-dev-server/automount.conf" "/Library/Application Support/mac-dev-server/automount.conf.real"'
ssh MIMOLETTE.local 'sudo tee "/Library/Application Support/mac-dev-server/automount.conf"' <<'EOF'
EXTERNAL_STORAGE_VOLUME=extra-vieille
EXTERNAL_STORAGE_UUID=00000000-0000-0000-0000-000000000000
EOF
```

- [ ] **Step 2: Preauthed reboot**

```bash
ssh MIMOLETTE.local 'sudo fdesetup authrestart'
```

- [ ] **Step 3: Poll for SSH readiness**

```bash
until ssh -o ConnectTimeout=3 MIMOLETTE.local true 2>/dev/null; do sleep 2; done
```

- [ ] **Step 4: Verify loud-fail triggered at boot**

```bash
ssh -t MIMOLETTE.local 'echo ready'  # -t forces interactive; banner should fire
ssh MIMOLETTE.local 'cat /var/run/mount-external-storage.FAILED'
ssh MIMOLETTE.local 'sudo log show --last 10m --predicate "process == \"logger\""' | grep mac-dev-server-automount
ssh MIMOLETTE.local 'ls /Volumes/extra-vieille 2>/dev/null && echo UNEXPECTED-MOUNT || echo EXPECTED-UNMOUNTED'
```

Expected: red banner visible on interactive SSH; flag file has `exit=1 reason=UUID ... not discoverable`; syslog entry present; volume NOT mounted (since UUID was wrong).

- [ ] **Step 5: Restore config, reboot, verify clean state**

```bash
ssh MIMOLETTE.local 'sudo mv "/Library/Application Support/mac-dev-server/automount.conf.real" "/Library/Application Support/mac-dev-server/automount.conf"'
ssh MIMOLETTE.local 'sudo fdesetup authrestart'
until ssh -o ConnectTimeout=3 MIMOLETTE.local true 2>/dev/null; do sleep 2; done
ssh MIMOLETTE.local 'ls /Volumes/extra-vieille >/dev/null && echo OK: MOUNTED'
ssh MIMOLETTE.local 'ls /var/run/mount-external-storage.FAILED 2>/dev/null && echo FAIL || echo OK: FLAG-CLEAR'
ssh -t MIMOLETTE.local 'echo ready'  # -t for interactive; no banner should fire
```

Expected: mounted; no flag file; no banner.

---

## Task 19: Test Phase 7 — Uninstall / rollback

- [ ] **Step 1: Run uninstall**

```bash
./app-setup/setup-external-automount.sh --uninstall
```

Expected: all four pieces removed; banner block stripped from `/etc/profile`.

- [ ] **Step 2: Verify clean state**

```bash
ls /Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist 2>/dev/null \
  && echo "FAIL" || echo "OK: plist gone"
ls "/Library/Application Support/mac-dev-server/" 2>/dev/null \
  && echo "FAIL" || echo "OK: support dir gone"
grep -c "mac-dev-server-automount-banner" /etc/profile \
  && echo "FAIL" || echo "OK: /etc/profile cleaned"
sudo launchctl list | grep automount-external-storage \
  && echo "FAIL" || echo "OK: not loaded"
```

Expected: all four checks print OK.

- [ ] **Step 3: Reboot and verify pre-spec behavior**

```bash
sudo fdesetup authrestart
# After reboot (from dev machine):
until ssh -o ConnectTimeout=3 MIMOLETTE.local true 2>/dev/null; do sleep 2; done
ssh MIMOLETTE.local 'ls /Volumes/extra-vieille 2>/dev/null && echo MOUNTED || echo UNMOUNTED'
```

Expected: `UNMOUNTED` immediately after reboot (pre-spec behavior restored — SSD only mounts on GUI login).

- [ ] **Step 4: Re-install for production use**

```bash
ssh MIMOLETTE.local 'cd ~/Developer/mac-dev-server-setup && ./app-setup/setup-external-automount.sh'
ssh MIMOLETTE.local 'sudo fdesetup authrestart'
until ssh -o ConnectTimeout=3 MIMOLETTE.local true 2>/dev/null; do sleep 2; done
ssh MIMOLETTE.local 'ls /Volumes/extra-vieille >/dev/null && echo OK: PRODUCTION-READY'
```

Expected: SSD mounted post-reboot without GUI login — success.

---

## Task 20: Create PR

- [ ] **Step 1: Verify branch is clean and all work is committed**

```bash
git status
git log --oneline origin/main..HEAD
```

Expected: clean working tree; ~12 commits on the branch (one per Task 1-10 plus Task 11's spec fix, plus any fixup commits).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin claude/feat-external-storage-automount-spec-20260424
```

- [ ] **Step 3: Create the PR**

```bash
gh pr create --title "feat: boot-time automount for external dev SSD" --body "$(cat <<'EOF'
## Summary

Adds a LaunchDaemon that mounts the external Thunderbolt SSD
(`/Volumes/extra-vieille`) at system boot, before sshd serves
connections. This makes the dev environment SSH-accessible after
reboot without requiring a macOS GUI login — removing a long-standing
friction point with headless-ish FileVault-protected Mac Minis.

## Design

- Spec: `docs/specs/2026-04-24-external-storage-automount-design.md`
- Plan: `docs/plans/2026-04-24-external-storage-automount-implementation.md`

Key choices: APFS volume UUID (stable) over BSD name (drifts); IOKit
match events (primary trigger) + RunAtLoad (belt-and-suspenders);
three-layer loud-fail (syslog + tmpfs flag + `/etc/profile` banner)
so SSH users see any boot-time mount failure.

## Test plan

All seven phases from the spec executed on MIMOLETTE:

- [x] Phase 0 - Static validation (shellcheck, plutil -lint, bash -n)
- [x] Phase 1 - Dry-run install (no filesystem changes)
- [x] Phase 2 - Install-only (files present, daemon not loaded)
- [x] Phase 3 - Load daemon, manual mount/remount tests
- [x] Phase 4 - Loud-fail validation (all three layers fire)
- [x] Phase 5 - Preauthed reboot, SSD mounted before SSH serves
- [x] Phase 6 - Simulated missing-SSD reboot, loud-fail at boot
- [x] Phase 7 - Uninstall rolls back to pre-spec state
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 4: STOP**

Per Protocol 6 in the user's global CLAUDE.md, creating a PR and merging are two separate turns. Report the PR URL and stop. Do NOT merge without explicit authorization.

---

## Self-Review Notes

Reviewed against the spec:

- **Architecture (1 LaunchDaemon + 1 helper + 1 setup + config + banner + run-app integration + config template):** all covered by Tasks 1–4 (templates + config) and Tasks 5–10 (setup script + integration).
- **Data flow (happy path / missing SSD / cable re-seat / races):** validated across Tasks 15, 17, 18 (happy path, real-boot, and simulated-missing-SSD reboots).
- **Error handling (three loud-fail layers, exit codes, setup-time safety, un-brickability):** implemented in Task 2 (helper script), validated in Task 16 (loud-fail exercise), rollback implemented in Task 8 (bootstrap failure).
- **Testing (seven phases):** Tasks 12–19 map 1:1 to Phases 0–7.
- **Open Question #1 (banner path):** closed in Task 11.
- **Open Question #2 (uninstall-should-rollback-symlinks):** deferred; not material to this plan. Can be revisited in a follow-up PR.

Placeholder scan: no TBD/TODO/FIXME/XXX. All code blocks contain actual content.

Type consistency: target paths (`TARGET_PLIST`, `TARGET_HELPER`, `TARGET_CONF`, `TARGET_SUPPORT_DIR`, `TARGET_PROFILE`), label (`LAUNCHD_LABEL`), and marker strings (`PROFILE_BEGIN`, `PROFILE_END`) are declared once in Task 5 and referenced consistently through Tasks 6–9.
