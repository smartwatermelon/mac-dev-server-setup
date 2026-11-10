#!/usr/bin/env bash
#
# setup-external-automount.sh - Install boot-time SSD automount on target.
#
# Boot LaunchDaemon mounts the SSD (SSH works without a GUI login); a
# login LaunchAgent alerts if it is missing. Run as the login user.
#
# Flags:
#   --dry-run       Show what would change; no writes outside a temp dir
#   --install-only  Install files but do not launchctl bootstrap
#   --uninstall     Remove the daemon, agent and installed files (incl. legacy)
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

# Missing-SSD notifier: per-user LaunchAgent. All paths are on the
# internal disk, so the agent still runs when the SSD is absent.
readonly AGENT_LABEL='com.mac-dev-server.ssd-mount-notify'
GUI_DOMAIN="gui/$(id -u)"
readonly GUI_DOMAIN
readonly AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
readonly AGENT_SUPPORT_DIR="${HOME}/Library/Application Support/mac-dev-server"
readonly AGENT_SCRIPT="${AGENT_SUPPORT_DIR}/ssd-mount-notify.sh"
readonly AGENT_LOG="${HOME}/Library/Logs/ssd-mount-notify.log"
readonly TMPL_AGENT_PLIST="${TEMPLATES_DIR}/${AGENT_LABEL}.plist.template"
readonly SRC_AGENT_SCRIPT="${TEMPLATES_DIR}/ssd-mount-notify.sh"
readonly DEFAULT_NOTIFY_GRACE_SECONDS=180

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
  # AUTOMOUNT_CONFIG_FILE lets --dry-run be exercised against a temp config.
  local conf="${AUTOMOUNT_CONFIG_FILE:-${REPO_ROOT}/config/config.conf}"
  if [[ ! -f "${conf}" ]]; then
    show_err "config not found: ${conf}"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${conf}"
  : "${SERVER_NAME:?SERVER_NAME not set in ${conf}}"
  # EXTERNAL_STORAGE_VOLUME is optional — empty means "no external storage on
  # this target, skip automount setup entirely." Handled by main() below.
  # Mirrors storage-setup.sh:157-161.
  EXTERNAL_STORAGE_VOLUME="${EXTERNAL_STORAGE_VOLUME:-}"
  EXTERNAL_STORAGE_NOTIFY_GRACE_SECONDS="${EXTERNAL_STORAGE_NOTIFY_GRACE_SECONDS:-${DEFAULT_NOTIFY_GRACE_SECONDS}}"
}

# --- login-user guard (the agent belongs to the GUI user, not root) ---
verify_login_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    show_err "run as the login user, not root/sudo; the script calls sudo itself"
    show_err "the LaunchAgent must go in that user's ~/Library and gui domain"
    exit 1
  fi
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
  local f
  for f in "${TMPL_PLIST}" "${TMPL_AGENT_PLIST}" "${SRC_AGENT_SCRIPT}"; do
    if [[ ! -f "${f}" ]]; then
      show_err "template not found: ${f}"
      exit 1
    fi
  done
  show_log "target plist:  ${TARGET_PLIST}"
  show_log "launchd label: ${LAUNCHD_LABEL}"
  show_log "agent plist:   ${AGENT_PLIST}"
  show_log "agent script:  ${AGENT_SCRIPT}"
}

# --- agent input validation ---

# Values go into XML via sed (| delimiter): reject & < > | and backslash.
validate_agent_inputs() {
  if [[ ! "${EXTERNAL_STORAGE_VOLUME}" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    show_err "EXTERNAL_STORAGE_VOLUME has unsupported characters: ${EXTERNAL_STORAGE_VOLUME}"
    exit 1
  fi
  if [[ ! "${SERVER_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    show_err "SERVER_NAME has unsupported characters: ${SERVER_NAME}"
    exit 1
  fi
  if [[ ! "${EXTERNAL_STORAGE_NOTIFY_GRACE_SECONDS}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    show_err "EXTERNAL_STORAGE_NOTIFY_GRACE_SECONDS must be an integer without leading zeros"
    exit 1
  fi
  if [[ "${HOME}" != /* || "${HOME}" =~ [\&\<\>\|\\] || "${HOME}" == /Volumes/* ]]; then
    show_err "HOME must be an absolute internal-disk path without & < > | \\: ${HOME}"
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

render_agent_plist() {
  local uuid="$1"
  sed -e "s|{{SCRIPT_PATH}}|${AGENT_SCRIPT}|g" \
    -e "s|{{UUID}}|${uuid}|g" \
    -e "s|{{VOLUME}}|${EXTERNAL_STORAGE_VOLUME}|g" \
    -e "s|{{GRACE_SECONDS}}|${EXTERNAL_STORAGE_NOTIFY_GRACE_SECONDS}|g" \
    -e "s|{{TITLE}}|${SERVER_NAME}|g" \
    -e "s|{{LOG_PATH}}|${AGENT_LOG}|g" \
    "${TMPL_AGENT_PLIST}"
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
  render_agent_plist "${uuid}" >"${_DRY_RUN_TMPDIR}/agent.plist"
  validate_plist "${_DRY_RUN_TMPDIR}/agent.plist"
  bash -n "${SRC_AGENT_SCRIPT}"

  show_log "dry-run: rendered plists pass plutil -lint; agent script passes bash -n"
  echo
  show_plan "would install (root:wheel 0644):"
  show_plan "   ${TARGET_PLIST}"
  show_plan "would run: sudo launchctl bootstrap system ${TARGET_PLIST}"
  show_plan "would install (user, 0755): ${AGENT_SCRIPT}"
  show_plan "would install (user, 0644): ${AGENT_PLIST}"
  show_plan "would run: launchctl bootstrap ${GUI_DOMAIN} ${AGENT_PLIST}"
  echo
  show_plan "rendered plist:"
  sed 's/^/      /' "${_DRY_RUN_TMPDIR}/rendered.plist"
  echo
  show_plan "rendered agent plist:"
  sed 's/^/      /' "${_DRY_RUN_TMPDIR}/agent.plist"
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

  render_agent_plist "${uuid}" >"${_INSTALL_TMPDIR}/agent.plist"
  validate_plist "${_INSTALL_TMPDIR}/agent.plist"
  bash -n "${SRC_AGENT_SCRIPT}"
  /bin/mkdir -p "${AGENT_SUPPORT_DIR}" "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
  /usr/bin/install -m 0755 "${SRC_AGENT_SCRIPT}" "${AGENT_SCRIPT}"
  /usr/bin/install -m 0644 "${_INSTALL_TMPDIR}/agent.plist" "${AGENT_PLIST}"
  show_log "installed ${AGENT_SCRIPT}"
  show_log "installed ${AGENT_PLIST}"
}

# --- agent load (user gui domain) ---
agent_loaded() {
  /bin/launchctl print "${GUI_DOMAIN}/${AGENT_LABEL}" >/dev/null 2>&1
}

# Not fatal: the plist in ~/Library/LaunchAgents loads at next GUI login.
load_agent() {
  local domain="${GUI_DOMAIN}"
  if agent_loaded; then
    show_log "agent already loaded; booting out before re-bootstrap"
    /bin/launchctl bootout "${domain}/${AGENT_LABEL}" || true
  fi
  if /bin/launchctl bootstrap "${domain}" "${AGENT_PLIST}"; then
    show_log "agent loaded: ${AGENT_LABEL} (runs now and at each login)"
  else
    show_err "launchctl bootstrap ${domain} failed (no GUI session?);"
    show_err "agent stays installed and loads at next GUI login"
  fi
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
  load_agent
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

  # Missing-SSD notifier agent (user-owned; no sudo).
  if agent_loaded; then
    show_log "booting out ${AGENT_LABEL}"
    /bin/launchctl bootout "${GUI_DOMAIN}/${AGENT_LABEL}" || {
      show_err "agent bootout failed; continuing to remove files"
    }
  fi
  local f
  for f in "${AGENT_PLIST}" "${AGENT_SCRIPT}"; do
    if [[ -f "${f}" ]]; then
      /bin/rm -f "${f}"
      show_log "removed ${f}"
    fi
  done
  /bin/rmdir "${AGENT_SUPPORT_DIR}" 2>/dev/null || true

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

  # Graceful skip when no external volume configured. Run before the hostname
  # guard and uninstall branch so this exits 0 (not 1) on targets that don't
  # use external storage — prevents run-app-setup.sh step 2 from failing on
  # every invocation when the config.conf default (empty) is left in place.
  # Uninstall is exempted so operators can still clean up legacy artifacts
  # even if the config was later blanked out.
  if [[ -z "${EXTERNAL_STORAGE_VOLUME}" && "${MODE}" != 'uninstall' ]]; then
    show_log "EXTERNAL_STORAGE_VOLUME not configured — skipping automount setup"
    show_log "Set EXTERNAL_STORAGE_VOLUME in config.conf to enable"
    return 0
  fi

  verify_on_target
  if [[ "${MODE}" != 'dry-run' ]]; then
    verify_login_user
  fi

  if [[ "${MODE}" == 'uninstall' ]]; then
    do_uninstall
    return 0
  fi

  check_prerequisites
  validate_agent_inputs

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
