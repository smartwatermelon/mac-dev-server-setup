#!/usr/bin/env bash
#
# xcode-setup.sh - Xcode installation and configuration
#
# This script handles full Xcode installation via the Mac App Store,
# license acceptance, developer path configuration, first launch setup,
# and iOS simulator installation.
#
# Prerequisites:
# - Apple ID must be signed into the App Store
# - Command Line Tools already installed (handled by setup-command-line-tools.sh)
# - mas (Mac App Store CLI) installed via Homebrew
#
# Usage: ./xcode-setup.sh [--force]
#   --force: Skip confirmation prompts
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
CURRENT_SECTION="Xcode Setup"

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

# Xcode App Store ID
readonly XCODE_APP_ID="497799835"

# Check if full Xcode is already installed
is_xcode_installed() {
  if [[ -d "/Applications/Xcode.app" ]]; then
    local xcode_path
    xcode_path="$(xcode-select -p 2>/dev/null || true)"
    if [[ "${xcode_path}" == "/Applications/Xcode.app/Contents/Developer" ]]; then
      return 0
    fi
  fi
  return 1
}

# Main execution
main() {
  section "Xcode Installation and Configuration"
  show_log "Starting Xcode setup..."
  log "XCODE_VERSION config: ${XCODE_VERSION:-latest}"

  # Check if Xcode is already installed and configured
  if is_xcode_installed; then
    local installed_version
    installed_version="$(xcodebuild -version 2>/dev/null | head -n 1 || echo "unknown")"
    show_log "Xcode already installed: ${installed_version}"
    show_log "Skipping installation"
  else
    # Verify mas is available
    if ! command -v mas &>/dev/null; then
      collect_error "mas (Mac App Store CLI) not found - install via Homebrew first"
      exit 1
    fi

    # Warn about Apple ID requirement
    show_log ""
    show_log "IMPORTANT: Apple ID must be signed into the App Store for Xcode download."
    show_log "Xcode is approximately 7GB and may take 30+ minutes to download."
    show_log ""

    if [[ "${FORCE}" != true ]]; then
      read -r -n 1 -p "Proceed with Xcode installation? (Y/n): " response
      echo
      case "${response}" in
        [nN])
          show_log "Xcode installation cancelled by user"
          exit 0
          ;;
        *)
          show_log "Proceeding with Xcode installation..."
          ;;
      esac
    fi

    # Install Xcode via Mac App Store
    section "Installing Xcode from App Store"
    show_log "Installing Xcode via mas (this will take a while)..."

    local install_exit=0
    mas install "${XCODE_APP_ID}" || install_exit=$?

    if [[ ${install_exit} -ne 0 ]]; then
      collect_error "Xcode installation via mas failed (exit code: ${install_exit})"
      show_log "Ensure you are signed into the App Store with an Apple ID"
      exit 1
    fi

    show_log "OK: Xcode downloaded and installed from App Store"
  fi

  # Verify Xcode.app exists before proceeding
  if [[ ! -d "/Applications/Xcode.app" ]]; then
    collect_error "Xcode.app not found in /Applications after installation"
    exit 1
  fi

  # Accept Xcode license
  section "Accepting Xcode License"
  show_log "Accepting Xcode license agreement..."

  local license_exit=0
  sudo xcodebuild -license accept 2>/dev/null || license_exit=$?
  check_success "${license_exit}" "Xcode license acceptance" || true

  # Set Xcode developer path
  section "Configuring Xcode Developer Path"
  show_log "Setting Xcode developer path..."

  local path_exit=0
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer || path_exit=$?
  check_success "${path_exit}" "Xcode developer path configuration" || true

  # Run first launch setup
  section "Running Xcode First Launch Setup"
  show_log "Running first launch setup (installing system components)..."

  local firstlaunch_exit=0
  xcodebuild -runFirstLaunch 2>/dev/null || firstlaunch_exit=$?
  check_success "${firstlaunch_exit}" "Xcode first launch setup" || true

  # Install iOS simulator
  section "Installing iOS Simulator"
  show_log "Downloading latest iOS simulator platform..."
  show_log "This may take several minutes depending on connection speed."

  local sim_exit=0
  xcodebuild -downloadPlatform iOS 2>/dev/null || sim_exit=$?
  check_success "${sim_exit}" "iOS simulator platform download" || true

  # Verification
  section "Verifying Xcode Installation"

  local xcode_version
  xcode_version="$(xcodebuild -version 2>/dev/null || echo "verification failed")"
  show_log "Xcode version: ${xcode_version}"

  local xcode_path
  xcode_path="$(xcode-select -p 2>/dev/null || echo "not set")"
  show_log "Developer path: ${xcode_path}"

  # List available simulators
  local sim_count
  sim_count="$(xcrun simctl list devices available 2>/dev/null | grep -c "iPhone\|iPad" || echo "0")"
  show_log "Available iOS simulators: ${sim_count}"

  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
    show_log ""
    show_log "Xcode setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
    exit 1
  fi

  show_log "Xcode setup completed successfully"
}

main "$@"
