#!/usr/bin/env bash
#
# dotfiles-setup.sh - Dotfiles clone and installation
#
# This script clones the user's dotfiles repository and runs its install
# script if one is found. Supports updating an existing clone.
#
# Prerequisites:
# - SSH key deployed (handled by first-boot.sh)
# - git installed
# - DOTFILES_REPO set in config.conf
#
# Usage: ./dotfiles-setup.sh [--force]
#   --force: Skip confirmation prompts, pass --force to install script
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-17

set -euo pipefail

# Parse command line arguments
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

# Configuration loading
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/config.conf"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"
fi

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Error: Configuration file not found"
  echo "Checked: ${SCRIPT_DIR}/../config/config.conf"
  echo "Checked: ${SCRIPT_DIR}/config/config.conf"
  exit 1
fi

# Derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Logging configuration
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-app-setup.log"
mkdir -p "${LOG_DIR}"

# Logging functions
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" >>"${LOG_FILE}"
}

show_log() {
  echo "$*"
  log "$*"
}

section() {
  log "====== $* ======"
}

# Error collection
COLLECTED_ERRORS=()
CURRENT_SECTION="Dotfiles Setup"

collect_error() {
  local message="$1"
  show_log "ERROR: ${message}"
  COLLECTED_ERRORS+=("[${CURRENT_SECTION}] ${message}")
}

check_success() {
  local exit_code=$1
  local operation="$2"

  if [[ ${exit_code} -eq 0 ]]; then
    show_log "OK: ${operation}"
    return 0
  else
    collect_error "${operation} failed with exit code ${exit_code}"
    return 1
  fi
}

# Dotfiles clone target
readonly DOTFILES_DIR="${HOME}/.dotfiles"

# Known install script names to search for
readonly -a INSTALL_SCRIPTS=(
  "install.sh"
  "setup.sh"
  "bootstrap.sh"
)

# Main execution
main() {
  section "Dotfiles Clone and Installation"
  show_log "Starting dotfiles setup..."

  # Check if DOTFILES_REPO is configured
  if [[ -z "${DOTFILES_REPO:-}" ]]; then
    show_log "DOTFILES_REPO not set in config - skipping dotfiles setup"
    exit 0
  fi

  show_log "Dotfiles repo: ${DOTFILES_REPO}"
  show_log "Clone target: ${DOTFILES_DIR}"

  # Verify git is available
  if ! command -v git &>/dev/null; then
    collect_error "git not found - install via Homebrew first"
    exit 1
  fi

  # Clone or update dotfiles
  if [[ -d "${DOTFILES_DIR}" ]]; then
    section "Updating Existing Dotfiles"
    show_log "Dotfiles directory exists, pulling latest changes..."

    local pull_exit=0
    git -C "${DOTFILES_DIR}" pull >>"${LOG_FILE}" 2>&1 || pull_exit=$?
    check_success "${pull_exit}" "Dotfiles pull" || true
  else
    section "Cloning Dotfiles Repository"

    if [[ "${FORCE}" != true ]]; then
      show_log ""
      show_log "Will clone ${DOTFILES_REPO} to ${DOTFILES_DIR}"
      show_log ""

      read -r -n 1 -p "Proceed with dotfiles clone? (Y/n): " response
      echo
      case "${response}" in
        [nN])
          show_log "Dotfiles clone cancelled by user"
          exit 0
          ;;
        *)
          show_log "Proceeding with clone..."
          ;;
      esac
    fi

    show_log "Cloning dotfiles repository..."

    local clone_exit=0
    git clone "${DOTFILES_REPO}" "${DOTFILES_DIR}" >>"${LOG_FILE}" 2>&1 || clone_exit=$?

    if ! check_success "${clone_exit}" "Dotfiles clone"; then
      show_log "Ensure SSH key is deployed and has access to the repository"
      exit 1
    fi
  fi

  # Look for and run install script
  section "Running Dotfiles Install Script"
  local found_install_script=""

  for script_name in "${INSTALL_SCRIPTS[@]}"; do
    if [[ -f "${DOTFILES_DIR}/${script_name}" ]]; then
      found_install_script="${DOTFILES_DIR}/${script_name}"
      break
    fi
  done

  # Also check for Makefile
  if [[ -z "${found_install_script}" ]] && [[ -f "${DOTFILES_DIR}/Makefile" ]]; then
    show_log "Found Makefile in dotfiles"

    if command -v make &>/dev/null; then
      show_log "Running make install..."
      local make_exit=0
      make -C "${DOTFILES_DIR}" install >>"${LOG_FILE}" 2>&1 || make_exit=$?
      check_success "${make_exit}" "Dotfiles make install" || true
    else
      show_log "make not found - skipping Makefile execution"
      log "Makefile found but make command not available"
    fi
  elif [[ -n "${found_install_script}" ]]; then
    show_log "Found install script: $(basename "${found_install_script}")"

    # Make executable if not already
    chmod +x "${found_install_script}"

    # Build command
    local -a install_cmd=("${found_install_script}")
    if [[ "${FORCE}" == true ]]; then
      install_cmd+=("--force")
    fi

    show_log "Running: ${install_cmd[*]}"
    local install_exit=0
    "${install_cmd[@]}" >>"${LOG_FILE}" 2>&1 || install_exit=$?
    check_success "${install_exit}" "Dotfiles install script" || true
  else
    show_log "No install script found in dotfiles (checked: ${INSTALL_SCRIPTS[*]}, Makefile)"
    log "Dotfiles cloned but no install script to run - manual setup may be needed"
  fi

  # Summary
  section "Dotfiles Setup Summary"
  show_log "Dotfiles directory: ${DOTFILES_DIR}"

  local file_count
  file_count="$(find "${DOTFILES_DIR}" -maxdepth 1 -not -name ".git" -not -name "." | wc -l | tr -d ' ')"
  show_log "Files in dotfiles: ${file_count}"

  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
    show_log ""
    show_log "Dotfiles setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
    exit 1
  fi

  show_log "Dotfiles setup completed successfully"
}

main "$@"
