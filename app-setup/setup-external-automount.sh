#!/usr/bin/env bash
#
# setup-external-automount.sh - Install boot-time SSD automount on target.
#
# Creates a LaunchDaemon that mounts the external APFS volume at boot so
# the dev environment is SSH-accessible without a macOS GUI login.
#
# Flags:
#   --dry-run       Show what would change; no writes to /Library/
#   --install-only  Install files but do not launchctl bootstrap
#   --uninstall     Remove the daemon and installed files (incl. legacy)
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

# Target install paths (current design)
readonly TARGET_PLIST='/Library/LaunchDaemons/com.mac-dev-server.automount-external-storage.plist'
readonly LAUNCHD_LABEL='com.mac-dev-server.automount-external-storage'

# Template path
readonly TMPL_PLIST="${TEMPLATES_DIR}/com.mac-dev-server.automount-external-storage.plist.template"

# Legacy install paths (previous design — kept only for defensive uninstall cleanup)
readonly LEGACY_SUPPORT_DIR='/Library/Application Support/mac-dev-server'
readonly LEGACY_PROFILE='/etc/profile'
readonly LEGACY_PROFILE_BEGIN='# BEGIN mac-dev-server-automount-banner'
readonly LEGACY_PROFILE_END='# END mac-dev-server-automount-banner'
readonly LEGACY_FAILED_FLAG='/var/run/mount-external-storage.FAILED'

# --- arg parsing ---
MODE='install' # install | dry-run | install-only | uninstall
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE='dry-run' ;;
    --install-only) MODE='install-only' ;;
    --uninstall) MODE='uninstall' ;;
    -h | --help)
      sed -n '2,17p' "$0"
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
check_prerequisites() {
  if [[ ! -f "${TMPL_PLIST}" ]]; then
    show_err "template not found: ${TMPL_PLIST}"
    exit 1
  fi
  show_log "target plist:  ${TARGET_PLIST}"
  show_log "launchd label: ${LAUNCHD_LABEL}"
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

  # Defense-in-depth: the UUID is substituted verbatim into the plist's
  # <string> value, which /bin/sh then word-splits. Reject anything that
  # isn't a bog-standard APFS UUID.
  if [[ ! "${uuid}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    show_err "VolumeUUID does not match expected format: ${uuid}"
    exit 1
  fi

  printf '%s' "${uuid}"
}

# --- template rendering ---
render_plist() {
  local uuid="$1"
  sed -e "s|{{UUID}}|${uuid}|g" "${TMPL_PLIST}"
}

# --- static validation ---
validate_plist() {
  local file="$1"
  if ! plutil -lint "${file}" >/dev/null; then
    show_err "plutil -lint failed: ${file}"
    return 1
  fi
}

# --- dry-run ---
_DRY_RUN_TMPDIR=''
_cleanup_dry_run() { [[ -n "${_DRY_RUN_TMPDIR}" ]] && rm -rf "${_DRY_RUN_TMPDIR}"; }

do_dry_run() {
  local uuid="$1"

  _DRY_RUN_TMPDIR="$(mktemp -d -t automount-dryrun)"
  trap '_cleanup_dry_run' RETURN

  render_plist "${uuid}" >"${_DRY_RUN_TMPDIR}/rendered.plist"
  validate_plist "${_DRY_RUN_TMPDIR}/rendered.plist"

  show_log "dry-run: rendered plist passes plutil -lint"
  echo
  show_plan "would install (root:wheel 0644):"
  show_plan "   ${TARGET_PLIST}"
  show_plan "would run: sudo launchctl bootstrap system ${TARGET_PLIST}"
  echo
  show_plan "rendered plist:"
  sed 's/^/      /' "${_DRY_RUN_TMPDIR}/rendered.plist"
}

# --- install-only (files, no launchctl) ---
_INSTALL_TMPDIR=''
_cleanup_install() { [[ -n "${_INSTALL_TMPDIR}" ]] && rm -rf "${_INSTALL_TMPDIR}"; }

do_install_only() {
  local uuid="$1"

  _INSTALL_TMPDIR="$(mktemp -d -t automount-install)"
  trap '_cleanup_install' RETURN

  render_plist "${uuid}" >"${_INSTALL_TMPDIR}/rendered.plist"
  validate_plist "${_INSTALL_TMPDIR}/rendered.plist"
  show_log "rendered plist passes plutil -lint; installing"

  sudo /usr/bin/install -o root -g wheel -m 0644 \
    "${_INSTALL_TMPDIR}/rendered.plist" "${TARGET_PLIST}"
  show_log "installed ${TARGET_PLIST}"
}

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

  do_install_only "${uuid}"

  # If already loaded (from a prior run), bootout first to pick up new plist.
  if sudo /bin/launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then
    show_log "daemon already loaded; booting out before re-bootstrap"
    sudo /bin/launchctl bootout system "${TARGET_PLIST}" || {
      show_err "bootout of existing daemon failed; aborting"
      exit 1
    }
  fi

  show_log "loading LaunchDaemon"
  local bootstrap_err
  bootstrap_err="$(mktemp -t automount-bootstrap-err)"
  if ! sudo /bin/launchctl bootstrap system "${TARGET_PLIST}" 2>"${bootstrap_err}"; then
    show_err "launchctl bootstrap failed:"
    cat "${bootstrap_err}" >&2
    rm -f "${bootstrap_err}"
    rollback_plist
    exit 1
  fi
  rm -f "${bootstrap_err}"

  if ! sudo /bin/launchctl list | grep -q "${LAUNCHD_LABEL}"; then
    show_err "daemon did not appear in launchctl list after bootstrap"
    rollback_plist
    exit 1
  fi
  show_log "daemon loaded: ${LAUNCHD_LABEL}"
  show_log "install complete"
}

# --- uninstall (removes current and any legacy artifacts) ---
do_uninstall() {
  show_log "uninstalling"

  # Bootout current daemon (tolerate not-loaded).
  if sudo /bin/launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then
    show_log "booting out ${LAUNCHD_LABEL}"
    sudo /bin/launchctl bootout system "${TARGET_PLIST}" || {
      show_err "bootout failed; continuing to remove files"
    }
  else
    show_log "daemon not loaded; skipping bootout"
  fi

  # Remove current plist.
  if [[ -f "${TARGET_PLIST}" ]]; then
    sudo /bin/rm -f "${TARGET_PLIST}"
    show_log "removed ${TARGET_PLIST}"
  fi

  # Legacy cleanup: previous design installed a helper script, conf file,
  # /etc/profile banner block, and a /var/run flag. Clear any stragglers.
  if [[ -d "${LEGACY_SUPPORT_DIR}" ]]; then
    sudo /bin/rm -rf "${LEGACY_SUPPORT_DIR}"
    show_log "removed legacy ${LEGACY_SUPPORT_DIR}"
  fi

  if [[ -f "${LEGACY_PROFILE}" ]] \
    && grep -qF "${LEGACY_PROFILE_BEGIN}" "${LEGACY_PROFILE}"; then
    if ! grep -qF "${LEGACY_PROFILE_END}" "${LEGACY_PROFILE}"; then
      show_err "${LEGACY_PROFILE} contains BEGIN marker but no END marker;"
      show_err "refusing to sed — BSD sed would delete BEGIN-to-EOF."
      show_err "inspect and clean ${LEGACY_PROFILE} by hand."
    else
      local tmpfile backup orig_bytes new_bytes
      tmpfile="$(mktemp -t profile-new)"
      backup="${LEGACY_PROFILE}.automount-uninstall.bak.$(date +%Y%m%d-%H%M%S)"
      orig_bytes="$(wc -c <"${LEGACY_PROFILE}")"
      sudo /bin/cp -p "${LEGACY_PROFILE}" "${backup}"
      sudo /usr/bin/sed \
        -e "\\|${LEGACY_PROFILE_BEGIN}|,\\|${LEGACY_PROFILE_END}|d" \
        "${LEGACY_PROFILE}" | tee "${tmpfile}" >/dev/null
      new_bytes="$(wc -c <"${tmpfile}")"
      # Banner block is ~600 bytes; anything shrinking more than 2KB is
      # suspicious and we bail rather than overwrite.
      if ((orig_bytes - new_bytes > 2048)); then
        show_err "sed output shrank by $((orig_bytes - new_bytes)) bytes;"
        show_err "expected ~600. refusing to overwrite ${LEGACY_PROFILE}."
        show_err "backup preserved at ${backup}"
        rm -f "${tmpfile}"
      else
        sudo /usr/bin/install -o root -g wheel -m 0444 \
          "${tmpfile}" "${LEGACY_PROFILE}"
        rm -f "${tmpfile}"
        show_log "removed legacy banner block from ${LEGACY_PROFILE}"
        show_log "backup at ${backup}"
      fi
    fi
  fi

  sudo /bin/rm -f "${LEGACY_FAILED_FLAG}"

  show_log "uninstall complete"
}

# --- dispatch ---
main() {
  load_config
  verify_on_target

  if [[ "${MODE}" == 'uninstall' ]]; then
    do_uninstall
    return 0
  fi

  check_prerequisites

  local uuid
  uuid="$(discover_uuid "${EXTERNAL_STORAGE_VOLUME}")"
  show_log "discovered UUID: ${uuid}"

  case "${MODE}" in
    dry-run) do_dry_run "${uuid}" ;;
    install-only) do_install_only "${uuid}" ;;
    install) do_install "${uuid}" ;;
    *)
      show_err "unexpected MODE: ${MODE}"
      exit 1
      ;;
  esac
}

main "$@"
