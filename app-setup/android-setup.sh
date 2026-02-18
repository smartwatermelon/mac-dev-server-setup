#!/usr/bin/env bash
#
# android-setup.sh - Android SDK configuration
#
# This script configures the Android SDK environment including license
# acceptance, SDK component installation, and shell environment setup.
# Android command line tools are installed via Homebrew (casks.txt).
#
# Prerequisites:
# - android-commandlinetools installed via Homebrew
# - Java (temurin) installed via Homebrew
#
# Usage: ./android-setup.sh [--force]
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

# SDK version from config with default
SDK_VERSION="${ANDROID_SDK_VERSION:-34}"

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
CURRENT_SECTION="Android SDK Setup"

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

# Determine ANDROID_HOME from Homebrew cask location
determine_android_home() {
  # Homebrew installs android-commandlinetools to this location
  local homebrew_prefix
  homebrew_prefix="$(brew --prefix 2>/dev/null || echo "/opt/homebrew")"
  local android_home="${homebrew_prefix}/share/android-commandlinetools"

  if [[ -d "${android_home}" ]]; then
    echo "${android_home}"
    return 0
  fi

  # Fallback: check standard locations
  if [[ -d "${HOME}/Library/Android/sdk" ]]; then
    echo "${HOME}/Library/Android/sdk"
    return 0
  fi

  # Return the Homebrew path even if it doesn't exist yet
  echo "${android_home}"
  return 1
}

# Main execution
main() {
  section "Android SDK Configuration"
  show_log "Starting Android SDK setup..."
  show_log "Target SDK version: ${SDK_VERSION}"

  # Verify Java is available
  section "Verifying Java Installation"
  if ! command -v java &>/dev/null; then
    collect_error "Java not found - install temurin via Homebrew first (check formulae.txt)"
    exit 1
  fi

  local java_version
  java_version="$(java -version 2>&1 | head -n 1)"
  show_log "Java: ${java_version}"

  # Determine ANDROID_HOME
  section "Configuring ANDROID_HOME"
  local android_home
  android_home="$(determine_android_home)" || true

  if [[ ! -d "${android_home}" ]]; then
    collect_error "Android command line tools directory not found: ${android_home}"
    show_log "Install android-commandlinetools via Homebrew first (check casks.txt)"
    exit 1
  fi

  show_log "ANDROID_HOME: ${android_home}"
  export ANDROID_HOME="${android_home}"

  # Set up environment variables in shell profiles
  section "Configuring Shell Environment"

  local env_block
  env_block=$(
    cat <<'ENVEOF'

# Android SDK
export ANDROID_HOME="ANDROID_HOME_PLACEHOLDER"
export PATH="${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"
ENVEOF
  )
  env_block="${env_block//ANDROID_HOME_PLACEHOLDER/${android_home}}"

  for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
    if [[ -f "${profile}" ]]; then
      if ! grep -q "ANDROID_HOME" "${profile}"; then
        show_log "Adding ANDROID_HOME to ${profile}"
        echo "${env_block}" >>"${profile}"
        log "Updated ${profile} with ANDROID_HOME"
      else
        log "ANDROID_HOME already in ${profile}"
      fi
    fi
  done

  # Add to current session
  export PATH="${android_home}/platform-tools:${android_home}/emulator:${PATH}"

  # Find sdkmanager
  local sdkmanager=""
  if command -v sdkmanager &>/dev/null; then
    sdkmanager="sdkmanager"
  elif [[ -x "${android_home}/cmdline-tools/latest/bin/sdkmanager" ]]; then
    sdkmanager="${android_home}/cmdline-tools/latest/bin/sdkmanager"
  elif [[ -x "${android_home}/bin/sdkmanager" ]]; then
    sdkmanager="${android_home}/bin/sdkmanager"
  else
    collect_error "sdkmanager not found in PATH or Android SDK directory"
    exit 1
  fi

  show_log "Using sdkmanager: ${sdkmanager}"

  # Accept SDK licenses
  section "Accepting Android SDK Licenses"
  show_log "Accepting all Android SDK licenses..."

  local license_exit=0
  yes | "${sdkmanager}" --licenses &>/dev/null || license_exit=$?

  # Exit 141 = SIGPIPE from yes; other non-zero exits may also be non-fatal
  if [[ ${license_exit} -ne 0 ]] && [[ ${license_exit} -ne 141 ]]; then
    log "sdkmanager --licenses exited with ${license_exit} (may be non-fatal)"
  fi
  show_log "OK: SDK license acceptance"

  # Install SDK components
  section "Installing Android SDK Components"

  local -a sdk_packages=(
    "platform-tools"
    "platforms;android-${SDK_VERSION}"
    "build-tools;${SDK_VERSION}.0.0"
    "emulator"
  )

  if [[ "${FORCE}" != true ]]; then
    show_log ""
    show_log "The following SDK components will be installed:"
    for pkg in "${sdk_packages[@]}"; do
      show_log "  - ${pkg}"
    done
    show_log ""

    read -r -n 1 -p "Proceed with SDK component installation? (Y/n): " response
    echo
    case "${response}" in
      [nN])
        show_log "SDK component installation cancelled by user"
        exit 0
        ;;
      *)
        show_log "Proceeding with SDK component installation..."
        ;;
    esac
  fi

  local install_exit pkg_dir
  for pkg in "${sdk_packages[@]}"; do
    # Check if already installed by looking for the package directory
    # Convert package name to directory path (e.g., "platforms;android-34" -> "platforms/android-34")
    pkg_dir="${pkg//;/\/}"
    if [[ -d "${android_home}/${pkg_dir}" ]]; then
      show_log "Already installed: ${pkg}"
      continue
    fi

    show_log "Installing: ${pkg}..."
    install_exit=0
    yes | "${sdkmanager}" "${pkg}" >>"${LOG_FILE}" 2>&1 || install_exit=$?
    # Exit 141 = SIGPIPE from yes when sdkmanager closes stdin — not an error
    if [[ ${install_exit} -eq 141 ]]; then
      install_exit=0
    fi
    check_success "${install_exit}" "SDK component: ${pkg}" || true
  done

  # Verification
  section "Verifying Android SDK Setup"
  show_log "ANDROID_HOME: ${ANDROID_HOME}"

  if command -v adb &>/dev/null || [[ -x "${android_home}/platform-tools/adb" ]]; then
    local adb_cmd="adb"
    if ! command -v adb &>/dev/null; then
      adb_cmd="${android_home}/platform-tools/adb"
    fi
    local adb_version
    adb_version="$("${adb_cmd}" --version 2>/dev/null | head -n 1 || echo "unknown")"
    show_log "adb: ${adb_version}"
  else
    collect_error "adb not found after SDK installation"
  fi

  show_log ""
  show_log "Installed SDK packages:"
  "${sdkmanager}" --list 2>/dev/null | tee -a "${LOG_FILE}" || true

  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
    show_log ""
    show_log "Android SDK setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
    exit 1
  fi

  show_log "Android SDK setup completed successfully"
}

main "$@"
