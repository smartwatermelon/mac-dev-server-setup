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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
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
MODE='install' # install | dry-run | install-only | uninstall
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE='dry-run' ;;
    --install-only) MODE='install-only' ;;
    --uninstall) MODE='uninstall' ;;
    -h | --help)
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
show_log() {
  local ts
  ts="$(date +%H:%M:%S)"
  printf '%s [setup-automount] %s\n' "${ts}" "$*"
}
show_err() {
  local ts
  ts="$(date +%H:%M:%S)"
  printf '%s [setup-automount] ERROR: %s\n' "${ts}" "$*" >&2
}
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

# --- prerequisite check ---
# Verifies that all required template files exist and target path constants are
# consistent.  Fails fast before any writes.
check_prerequisites() {
  local missing=0

  for tmpl in "${TMPL_PLIST}" "${TMPL_HELPER}" "${TMPL_BANNER}"; do
    if [[ ! -f "${tmpl}" ]]; then
      show_err "template not found: ${tmpl}"
      missing=1
    fi
  done

  # Log target paths so operators can confirm them at a glance.
  show_log "target plist:      ${TARGET_PLIST}"
  show_log "target helper:     ${TARGET_HELPER}"
  show_log "target conf:       ${TARGET_CONF}"
  show_log "target profile:    ${TARGET_PROFILE}"
  show_log "launchd label:     ${LAUNCHD_LABEL}"
  show_log "profile begin tag: ${PROFILE_BEGIN}"
  show_log "profile end tag:   ${PROFILE_END}"

  if [[ "${missing}" -ne 0 ]]; then
    show_err "one or more templates missing; cannot continue"
    exit 1
  fi
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

# --- dry-run ---
_DRY_RUN_TMPDIR=''

_cleanup_dry_run() { [[ -n "${_DRY_RUN_TMPDIR}" ]] && rm -rf "${_DRY_RUN_TMPDIR}"; }

do_dry_run() {
  local uuid="$1"
  local volume="$2"

  _DRY_RUN_TMPDIR="$(mktemp -d -t automount-dryrun)"
  trap '_cleanup_dry_run' RETURN

  render_template "${TMPL_PLIST}" "${uuid}" "${volume}" >"${_DRY_RUN_TMPDIR}/rendered.plist"
  render_template "${TMPL_HELPER}" "${uuid}" "${volume}" >"${_DRY_RUN_TMPDIR}/rendered.sh"
  cp "${TMPL_BANNER}" "${_DRY_RUN_TMPDIR}/rendered-banner.sh"

  validate_plist "${_DRY_RUN_TMPDIR}/rendered.plist"
  validate_script "${_DRY_RUN_TMPDIR}/rendered.sh"
  validate_script "${_DRY_RUN_TMPDIR}/rendered-banner.sh"

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
  sed 's/^/      /' "${_DRY_RUN_TMPDIR}/rendered.plist"
  echo
  show_plan "rendered automount.conf contents:"
  printf '      EXTERNAL_STORAGE_VOLUME=%s\n' "${volume}"
  printf '      EXTERNAL_STORAGE_UUID=%s\n' "${uuid}"
}

# --- dispatch (expanded in Task 7/8/9) ---
main() {
  load_config
  verify_on_target
  check_prerequisites

  local uuid
  uuid="$(discover_uuid "${EXTERNAL_STORAGE_VOLUME}")"
  show_log "discovered UUID: ${uuid}"

  case "${MODE}" in
    dry-run) do_dry_run "${uuid}" "${EXTERNAL_STORAGE_VOLUME}" ;;
    install-only) show_log "install-only mode (not yet implemented; see Task 7)" ;;
    install) show_log "install mode (not yet implemented; see Task 8)" ;;
    uninstall) show_log "uninstall mode (not yet implemented; see Task 9)" ;;
    *)
      show_err "unexpected MODE: ${MODE}"
      exit 1
      ;;
  esac
}

main "$@"
