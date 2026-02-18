#!/usr/bin/env bash
#
# first-boot.sh - Mac Mini Dev Server System Provisioning & Configuration
#
# This script performs comprehensive macOS dev server provisioning including:
# - Hardware fingerprint validation and security checks
# - FileVault compatibility verification with auto-disable option
# - Administrator password collection and validation
# - SSH key deployment for admin account
# - External keychain import and credential extraction
# - Multi-phase system configuration via 15+ specialized modules
# - Comprehensive logging and error collection with end-of-run validation
#
# CRITICAL REQUIREMENTS:
# - MUST be run from local GUI session (Terminal.app) - CANNOT run via SSH
# - Requires administrator account password for system modifications
# - Must be run from deployment package directory (contains config/, scripts/, etc.)
# - Deployment package must contain valid hardware fingerprint and credentials
# - FileVault must be disabled or will be disabled during setup (with user consent)
#
# Usage: ./first-boot.sh [--force] [--skip-update] [--skip-homebrew] [--skip-packages]
#   --force           Skip all confirmation prompts (dangerous - use carefully)
#   --skip-update     Skip macOS software updates (recommended - updates are unreliable during setup)
#   --skip-homebrew   Skip Homebrew installation and configuration
#   --skip-packages   Skip package installation from formulae.txt and casks.txt
#
# SYSTEM MODIFICATIONS PERFORMED:
# - Deploys SSH keys for administrator account
# - Imports credentials from external keychain to system keychain
# - Calls 15+ setup modules: TouchID, WiFi, SSH, Remote Desktop, Apple ID, etc.
# - Configures system preferences, power management, firewall, logging
# - Sets up application preparation and terminal profiles
#
# INTERACTIVE BEHAVIORS:
# - Requests administrator password (validated against directory services)
# - FileVault disable confirmation if FileVault is enabled
# - Setup continuation confirmation after error summary
# - Multiple validation checks with error recovery options
#
# ENVIRONMENT VARIABLES (Advanced):
# - HOSTNAME_OVERRIDE: Custom hostname different from SERVER_NAME
# - RERUN_AFTER_FDA: Set to true when rerunning after Full Disk Access grant
# - All config.conf variables: SERVER_NAME, 1Password items
#
# ERROR HANDLING:
# - Comprehensive error and warning collection across all phases
# - Context-aware error reporting with section and line number information
# - Multi-level verification system for all critical configurations
# - End-of-run validation with detailed success/failure reporting
# - Hardware fingerprint validation prevents execution on wrong machine
#
# LOGGING:
# - Detailed setup log: ~/.local/state/${hostname}-setup.log
# - Automatic log rotation with timestamp preservation
# - Section-based logging for easy troubleshooting
# - Password masking in all log output for security
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2025-05-18

# Exit on any error
set -euo pipefail

# Configuration variables - adjust as needed
ADMIN_USERNAME=$(whoami)                                  # Set this once and use throughout
ADMINISTRATOR_PASSWORD=""                                 # Get it interactively later
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Directory where AirDropped files are located (script now at root)
RERUN_AFTER_FDA=false
NEED_SYSTEMUI_RESTART=false
NEED_CONTROLCENTER_RESTART=false
# Safety: Development machine fingerprint (to prevent accidental execution)
DEV_FINGERPRINT_FILE="${SETUP_DIR}/config/dev_fingerprint.conf"
DEV_MACHINE_FINGERPRINT="" # Default blank - will be populated from file

# Parse command line arguments
FORCE=false
SKIP_UPDATE=true # this is unreliable during setup
SKIP_HOMEBREW=false
SKIP_PACKAGES=false

for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    --skip-update)
      SKIP_UPDATE=true
      shift
      ;;
    --skip-homebrew)
      SKIP_HOMEBREW=true
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Load configuration
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  echo "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Set Homebrew prefix based on architecture for all modules
ARCH="$(arch)"
case "${ARCH}" in
  i386)
    export HOMEBREW_PREFIX="/usr/local"
    ;;
  arm64)
    export HOMEBREW_PREFIX="/opt/homebrew"
    ;;
  *)
    collect_error "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# _timeout function - uses timeout utility if installed, otherwise Perl
# https://gist.github.com/jaytaylor/6527607
function _timeout() {
  if command -v timeout; then
    timeout "$@"
  else
    if ! command -v perl; then
      echo "perl not found 😿"
      exit 1
    else
      perl -e 'alarm shift; exec @ARGV' "$@"
    fi
  fi
}

# log function - only writes to log file
log() {
  mkdir -p "${LOG_DIR}"
  local timestamp no_newline=false
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    shift
  fi

  if [[ "${no_newline}" == true ]]; then
    echo -n "[${timestamp}] $1" >>"${LOG_FILE}"
  else
    echo "[${timestamp}] $1" >>"${LOG_FILE}"
  fi
}

# New wrapper function - shows in main window AND logs
show_log() {
  local no_newline=false

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    echo -n "$2"
    log -n "$2"
  else
    echo "$1"
    log "$1"
  fi
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Error and warning collection system
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

# Function to collect an error (with immediate display)
collect_error() {
  local message="$1"
  local line_number="${2:-}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to collect a warning (with immediate display)
collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to show collected errors and warnings at end
show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    show_log "✅ Setup completed successfully with no errors or warnings!"
    return
  fi

  show_log ""
  show_log "====== SETUP SUMMARY ======"
  show_log "Setup completed, but ${error_count} errors and ${warning_count} warnings occurred:"
  show_log ""

  if [[ ${error_count} -gt 0 ]]; then
    show_log "ERRORS:"
    for error in "${COLLECTED_ERRORS[@]}"; do
      show_log "  ${error}"
    done
    show_log ""
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    show_log "WARNINGS:"
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      show_log "  ${warning}"
    done
    show_log ""
  fi

  show_log "Review the full log for details: ${LOG_FILE}"
}

# Deploy Package Manifest Validation
# Validates that all required files are present in the deployment package
# before beginning system setup operations

validate_deploy_package() {
  local manifest_file="${SETUP_DIR}/DEPLOY_MANIFEST.txt"
  local validation_errors=0
  local validation_warnings=0

  if [[ ! -f "${manifest_file}" ]]; then
    collect_error "Deploy manifest not found: ${manifest_file}"
    show_log "This deployment package was created with an older version of prep-airdrop.sh"
    show_log "Consider regenerating the package for better deployment validation"
    return 1
  fi

  log "Validating deployment package against manifest"

  # Parse manifest and check each file
  while read -r line || [[ -n "${line}" ]]; do
    # Skip comments and empty lines
    [[ "${line}" =~ ^#.*$ ]] || [[ -z "${line}" ]] && continue

    # Skip metadata entries
    [[ "${line}" =~ ^(MANIFEST_VERSION|CREATED_BY|CREATED_AT|PACKAGE_ROOT)= ]] && continue

    # Check if line contains an equals sign
    if [[ ! "${line}" =~ = ]]; then
      collect_warning "Malformed manifest entry (no equals sign): ${line}"
      ((validation_warnings += 1))
      continue
    fi

    # Parse file path and requirement safely
    file_path="${line%%=*}"  # Everything before first =
    requirement="${line#*=}" # Everything after first =

    # Handle edge cases
    if [[ -z "${file_path}" ]]; then
      collect_warning "Malformed manifest entry (empty file path): ${line}"
      ((validation_warnings += 1))
      continue
    fi

    if [[ -z "${requirement}" ]]; then
      collect_warning "Malformed manifest entry (empty requirement): ${line}"
      ((validation_warnings += 1))
      continue
    fi

    local full_path="${SETUP_DIR}/${file_path}"

    if [[ -f "${full_path}" ]]; then
      log "✅ Found: ${file_path}"
    else
      case "${requirement}" in
        "REQUIRED")
          collect_error "Required file missing from deploy package: ${file_path}"
          ((validation_errors += 1))
          ;;
        "OPTIONAL")
          collect_warning "Optional file missing from deploy package: ${file_path}"
          ((validation_warnings += 1))
          ;;
        "MISSING")
          log "📋 Expected missing: ${file_path} (was not available during package creation)"
          ;;
        *)
          collect_warning "Unknown requirement '${requirement}' for file: ${file_path}"
          ((validation_warnings += 1))
          ;;
      esac
    fi
  done <"${manifest_file}"

  if [[ ${validation_errors} -gt 0 ]]; then
    collect_error "Deploy package validation failed: ${validation_errors} required files missing"
    show_log "❌ Cannot proceed with setup - required files are missing from deployment package"
    show_log "Please regenerate the deployment package with prep-airdrop.sh and try again"
    return 1
  fi

  if [[ ${validation_warnings} -gt 0 ]]; then
    show_log "Deploy package validation completed with ${validation_warnings} optional files missing"
    show_log "Setup will continue, but some optional features may not be available"
  else
    show_log "✅ Deploy package validation passed - all files present"
  fi

  return 0
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    collect_error "$1 failed"
    if [[ "${FORCE}" = false ]]; then
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Import credentials from external keychain and populate user keychains
import_external_keychain_credentials() {

  set_section "Importing Credentials from External Keychain"
  # Load keychain manifest
  local manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
  if [[ ! -f "${manifest_file}" ]]; then
    collect_error "Keychain manifest not found: ${manifest_file}"
    return 1
  fi

  # shellcheck source=/dev/null
  source "${manifest_file}"

  # Validate required variables from manifest
  if [[ -z "${KEYCHAIN_PASSWORD:-}" || -z "${EXTERNAL_KEYCHAIN:-}" ]]; then
    collect_error "Required keychain variables not found in manifest"
    return 1
  fi

  # Copy external keychain file to user's keychain directory (preserve original for idempotency)
  local external_keychain_file="${SETUP_DIR}/config/${EXTERNAL_KEYCHAIN}-db"
  local user_keychain_file="${HOME}/Library/Keychains/${EXTERNAL_KEYCHAIN}-db"

  if [[ ! -f "${external_keychain_file}" ]]; then
    if [[ -f "${user_keychain_file}" ]]; then
      log "External keychain file not found in setup package, but located in local keychains."
      cp "${user_keychain_file}" "${external_keychain_file}"
    else
      collect_error "External keychain file not found: ${external_keychain_file}"
      return 1
    fi
  fi

  log "Copying external keychain to user's keychain directory..."
  cp "${external_keychain_file}" "${user_keychain_file}"
  chmod 600 "${user_keychain_file}"
  check_success "External keychain file copied"

  # Unlock external keychain
  log "Unlocking external keychain with dev machine fingerprint..."
  if security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${EXTERNAL_KEYCHAIN}"; then
    show_log "✅ External keychain unlocked successfully"
  else
    collect_error "Failed to unlock external keychain"
    return 1
  fi

  # Import administrator credentials to default keychain
  log "Importing administrator credentials to default keychain..."

  # Unlock admin keychain first
  show_log "Unlocking administrator keychain for credential import..."

  if ! security unlock-keychain -p "${ADMINISTRATOR_PASSWORD}"; then
    collect_error "Failed to unlock administrator keychain"
    return 1
  fi

  # Import TimeMachine credential (optional)
  # shellcheck disable=SC2154 # KEYCHAIN_TIMEMACHINE_SERVICE loaded from sourced manifest
  if timemachine_credential=$(security find-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${timemachine_credential}" -D "Mac Server Setup - TimeMachine Credentials" -A -U; then
      show_log "✅ TimeMachine credential imported to administrator keychain"
    else
      collect_warning "Failed to import TimeMachine credential to administrator keychain"
    fi
    unset timemachine_credential
  else
    show_log "⚠️ TimeMachine credential not found in external keychain (optional)"
  fi

  # Import WiFi credential (optional)
  # shellcheck disable=SC2154 # KEYCHAIN_WIFI_SERVICE loaded from sourced manifest
  if wifi_credential=$(security find-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${wifi_credential}" -D "Mac Server Setup - WiFi Credentials" -A -U; then
      show_log "✅ WiFi credential imported to administrator keychain"
    else
      collect_warning "Failed to import WiFi credential to administrator keychain"
    fi
    unset wifi_credential
  else
    show_log "⚠️ WiFi credential not found in external keychain (optional)"
  fi

  return 0
}

# SAFETY CHECK: Prevent execution on development machine
set_section "Development Machine Safety Check"

# Load development fingerprint if available
if [[ -f "${DEV_FINGERPRINT_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${DEV_FINGERPRINT_FILE}"
  log "Loaded development machine fingerprint for safety check"
else
  echo "❌ SAFETY ABORT: No development fingerprint file found"
  echo "This indicates the setup directory was not properly prepared with prep-airdrop.sh"
  exit 1
fi

# Abort if fingerprint is blank (safety default)
if [[ -z "${DEV_MACHINE_FINGERPRINT}" ]]; then
  echo "❌ SAFETY ABORT: Blank development machine fingerprint"
  echo "Setup directory appears corrupted or improperly prepared"
  exit 1
fi

# Check if running in a GUI session (required for many setup operations)
SESSION_TYPE=$(launchctl managername 2>/dev/null || echo "Unknown")
if [[ "${SESSION_TYPE}" != "Aqua" ]]; then
  echo "❌ ERROR: This script requires a GUI session to run properly"
  echo "Current session type: ${SESSION_TYPE}"
  echo ""
  echo "Mac Mini server setup requires desktop access for:"
  echo "- User account creation and configuration"
  echo "- System Settings modifications"
  echo "- AppleScript dialogs and automation"
  echo "- Application installations and setup"
  echo ""
  echo "Please run this script from the Mac's local desktop session."
  exit 1
fi
show_log "✓ GUI session detected (${SESSION_TYPE}) - setup can proceed"

# Get current machine fingerprint
CURRENT_FINGERPRINT=$(system_profiler SPHardwareDataType | grep "Hardware UUID" | awk '{print $3}')

# Abort if running on development machine
if [[ "${CURRENT_FINGERPRINT}" == "${DEV_MACHINE_FINGERPRINT}" ]]; then
  echo "❌ SAFETY ABORT: This script is running on the development machine"
  echo "Development fingerprint: ${DEV_MACHINE_FINGERPRINT}"
  echo "Current fingerprint: ${CURRENT_FINGERPRINT}"
  echo ""
  echo "This script is only for target Mac Mini server setup"
  exit 1
fi

show_log "✅ Safety check passed - not running on development machine"
log "Current machine: ${CURRENT_FINGERPRINT}"

# Log FileVault status (informational only — auto-login is not used)
set_section "FileVault Status Check"

if command -v fdesetup >/dev/null 2>&1; then
  filevault_status=$(fdesetup status 2>/dev/null || echo "unknown")
  show_log "FileVault status: ${filevault_status}"
else
  log "fdesetup not available, skipping FileVault status check"
fi

# Create log file if it doesn't exist, rotate if it exists
if [[ -f "${LOG_FILE}" ]]; then
  # Rotate existing log file with timestamp
  ROTATED_LOG="${LOG_FILE%.log}-$(date +%Y%m%d-%H%M%S).log"
  mv "${LOG_FILE}" "${ROTATED_LOG}"
  log "Rotated previous log to: ${ROTATED_LOG}"
fi

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

# Print header
set_section "Starting Mac Mini '${SERVER_NAME}' Dev Server Setup"
log "Running as user: ${ADMIN_USERNAME}"
timestamp="$(date)"
log "Date: ${timestamp}"
productversion="$(sw_vers -productVersion)"
log "macOS Version: ${productversion}"
log "Setup directory: ${SETUP_DIR}"
log "HOMEBREW_PREFIX: ${HOMEBREW_PREFIX} (architecture: ${ARCH})"

# Validate deployment package before beginning setup
set_section "Validating Deployment Package"
if ! validate_deploy_package; then
  show_log "❌ Deployment package validation failed - cannot proceed with setup"
  show_collected_issues
  exit 1
fi

# Look for evidence we're being re-run after FDA grant
if [[ -f "/tmp/${HOSTNAME_LOWER}_fda_requested" ]]; then
  RERUN_AFTER_FDA=true
  rm -f "/tmp/${HOSTNAME_LOWER}_fda_requested"
  log "Detected re-run after Full Disk Access grant"
fi

# Confirm operation if not forced
if [[ "${FORCE}" = false ]] && [[ "${RERUN_AFTER_FDA}" = false ]]; then
  read -p "This script will configure your Mac Mini server. Continue? (Y/n) " -n 1 -r
  echo
  # Default to Yes if Enter pressed (empty REPLY)
  if [[ -n "${REPLY}" ]] && [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# Collect administrator password for keychain operations
if [[ "${FORCE}" != "true" ]]; then
  echo
  echo "This script will need your Mac account password for keychain operations."
  read -r -e -p "Enter your Mac ${ADMIN_USERNAME} account password: " -s ADMINISTRATOR_PASSWORD
  echo # Add newline after hidden input

  # Validate password by testing with dscl
  until _timeout 1 dscl /Local/Default -authonly "${USER}" "${ADMINISTRATOR_PASSWORD}" &>/dev/null; do
    echo "Invalid ${ADMIN_USERNAME} account password. Try again or ctrl-C to exit."
    read -r -e -p "Enter your Mac ${ADMIN_USERNAME} account password: " -s ADMINISTRATOR_PASSWORD
    echo # Add newline after hidden input
  done

  show_log "✅ Administrator password validated"
  export ADMINISTRATOR_PASSWORD

  # Prime sudo and start keepalive so modules don't re-prompt
  echo "${ADMINISTRATOR_PASSWORD}" | sudo -S -v 2>/dev/null
  while true; do
    sudo -n -v 2>/dev/null
    sleep 55
  done &
  SUDO_KEEPALIVE_PID=$!
  log "Started sudo keepalive (PID ${SUDO_KEEPALIVE_PID})"
else
  log "🆗 Skipping password prompt (force mode or FDA re-run)"
fi

#
# SYSTEM CONFIGURATION
#

# Import credentials from external keychain
if ! import_external_keychain_credentials; then
  collect_error "External keychain credential import failed"
  exit 1
fi

# TouchID and sudo configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-touchid-sudo.sh" --force
else
  "${SETUP_DIR}/scripts/setup-touchid-sudo.sh"
fi

# WiFi network configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-wifi-network.sh" --force
else
  "${SETUP_DIR}/scripts/setup-wifi-network.sh"
fi

# Hostname and volume configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-hostname-volume.sh" --force
else
  "${SETUP_DIR}/scripts/setup-hostname-volume.sh"
fi

# SSH access - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-ssh-access.sh" --force
else
  "${SETUP_DIR}/scripts/setup-ssh-access.sh"
fi
if [[ -f "/tmp/${HOSTNAME_LOWER}_fda_requested" ]]; then
  # We need to exit here and have the user start the script again in a new window
  exit 0
fi

# Configure Remote Desktop (Screen Sharing and Remote Management)
section "Configuring Remote Desktop"

log "Remote Desktop requires GUI interaction to enable services, then automated permission setup"

# Run the user-guided setup script with proper verification
if [[ "${FORCE}" == "true" ]]; then
  log "Running Remote Desktop setup with --force flag"
  if "${SETUP_DIR}/scripts/setup-remote-desktop.sh" --force; then
    log "✅ Remote Desktop setup completed successfully with verification"
  else
    collect_error "Remote Desktop setup failed verification - Screen Sharing may not be working"
    log "Manual setup required: ${SETUP_DIR}/scripts/setup-remote-desktop.sh"
    log "Check System Settings > General > Sharing to enable Screen Sharing manually"
  fi
else
  log "Remote Desktop setup will automatically configure System Settings"
  if "${SETUP_DIR}/scripts/setup-remote-desktop.sh"; then
    log "✅ Remote Desktop setup completed successfully with verification"
  else
    collect_error "Remote Desktop setup failed verification - Screen Sharing may not be working"
    log "Manual setup required: ${SETUP_DIR}/scripts/setup-remote-desktop.sh"
    log "Check System Settings > General > Sharing to enable Screen Sharing manually"
  fi
fi

# After GUI setup, configure automated permissions for admin user
log "Configuring Remote Management privileges for admin user"
sudo -p "[Remote management] Enter password to configure admin privileges: " /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -users "${ADMIN_USERNAME}" \
  -access -on \
  -privs -all 2>/dev/null || {
  log "Note: Admin Remote Management privileges will be configured after services are enabled"
}
check_success "Admin Remote Management privileges (if services enabled)"

#
# APPLE ID & ICLOUD CONFIGURATION - delegated to module
#

# Apple ID and iCloud configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-apple-id.sh" --force
else
  "${SETUP_DIR}/scripts/setup-apple-id.sh"
fi

# Fix scroll setting - handled by system preferences module

# Power management configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-power-management.sh" --force
else
  "${SETUP_DIR}/scripts/setup-power-management.sh"
fi

# Screen saver and software updates - handled by system preferences module

# Firewall configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-firewall.sh" --force
else
  "${SETUP_DIR}/scripts/setup-firewall.sh"
fi

# Security settings - handled by system preferences module

#
# HOMEBREW & PACKAGE INSTALLATION
#

#
# SYSTEM PREFERENCES CONFIGURATION - delegated to module
#

# System preferences configuration - delegated to module
system_prefs_args=()
if [[ "${FORCE}" == true ]]; then
  system_prefs_args+=(--force)
fi
if [[ "${SKIP_UPDATE}" == true ]]; then
  system_prefs_args+=(--skip-update)
fi

"${SETUP_DIR}/scripts/setup-system-preferences.sh" ${system_prefs_args[@]+"${system_prefs_args[@]}"}

# Install Xcode Command Line Tools using dedicated script
set_section "Installing Xcode Command Line Tools"

# Use the dedicated CLT installation script with enhanced monitoring
clt_script="${SETUP_DIR}/scripts/setup-command-line-tools.sh"

if [[ -f "${clt_script}" ]]; then
  log "Using enhanced Command Line Tools installation script..."

  # Prepare CLT installation arguments
  clt_args=()
  if [[ "${FORCE}" = true ]]; then
    clt_args+=(--force)
  fi

  # Run the dedicated CLT installation script
  if "${clt_script}" ${clt_args[@]+"${clt_args[@]}"}; then
    log "✅ Command Line Tools installation completed successfully"
  else
    collect_error "Command Line Tools installation failed"
    exit 1
  fi
else
  collect_error "CLT installation script not found: ${clt_script}"
  log "Please ensure setup-command-line-tools.sh is present in the scripts directory"
  exit 1
fi

#
# HOMEBREW & PACKAGE INSTALLATION - delegated to module
#

# Package installation - delegated to module
package_args=()
if [[ "${FORCE}" == true ]]; then
  package_args+=(--force)
fi
if [[ "${SKIP_HOMEBREW}" == true ]]; then
  package_args+=(--skip-homebrew)
fi
if [[ "${SKIP_PACKAGES}" == true ]]; then
  package_args+=(--skip-packages)
fi

"${SETUP_DIR}/scripts/setup-package-installation.sh" ${package_args[@]+"${package_args[@]}"}

#
# DOCK CONFIGURATION - delegated to module
#

# Dock configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-dock-configuration.sh" --force
else
  "${SETUP_DIR}/scripts/setup-dock-configuration.sh"
fi

#
# SHELL CONFIGURATION - delegated to module
#

# Shell configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-shell-configuration.sh" --force
else
  "${SETUP_DIR}/scripts/setup-shell-configuration.sh"
fi

#
# TERMINAL PROFILE CONFIGURATION - delegated to module
#

# Terminal profile configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-terminal-profiles.sh" --force
else
  "${SETUP_DIR}/scripts/setup-terminal-profiles.sh"
fi

#
# LOG ROTATION SETUP - delegated to module
#

# Log rotation configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-log-rotation.sh" --force
else
  "${SETUP_DIR}/scripts/setup-log-rotation.sh"
fi

#
# APPLICATION SETUP PREPARATION - delegated to module
#

# Application setup preparation - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-application-preparation.sh" --force
else
  "${SETUP_DIR}/scripts/setup-application-preparation.sh"
fi

# Set APP_SETUP_DIR for completion messages (defined by application setup module)
APP_SETUP_DIR="/Users/${ADMIN_USERNAME}/app-setup"

#
# BASH CONFIGURATION SETUP - delegated to module
#

# Bash configuration setup - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-bash-configuration.sh" --force
else
  "${SETUP_DIR}/scripts/setup-bash-configuration.sh"
fi

#
# TIME MACHINE CONFIGURATION
#

# Time Machine configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-timemachine.sh" --force
else
  "${SETUP_DIR}/scripts/setup-timemachine.sh"
fi

# Apply menu bar changes
if [[ "${NEED_SYSTEMUI_RESTART}" = true ]]; then
  log "Restarting SystemUIServer to apply menu bar changes"
  killall SystemUIServer
  check_success "SystemUIServer restart for menu bar updates"
fi
if [[ "${NEED_CONTROLCENTER_RESTART}" = true ]]; then
  log "Restarting Control Center to apply menu bar changes"
  killall ControlCenter
  check_success "Control Center restart for menu bar updates"
fi

# Setup completed successfully
section "Setup Complete"
show_log "Server setup has been completed successfully"

# Clean up temporary sudo timeout configuration
log "Removing temporary sudo timeout configuration"
sudo rm -f /etc/sudoers.d/10_setup_timeout

# Stop sudo keepalive
if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
  kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
  log "Stopped sudo keepalive (PID ${SUDO_KEEPALIVE_PID})"
fi

# Clean up administrator password from memory
if [[ -n "${ADMINISTRATOR_PASSWORD:-}" ]]; then
  unset ADMINISTRATOR_PASSWORD
  log "✅ Administrator password cleared from memory"
fi

# Show collected errors and warnings
show_collected_issues

# Show completion dialog and open new Terminal window for app setup
osascript <<EOF
tell application "System Events"
  display dialog "Dev Server Setup Complete!" & return & return & "The base system configuration is now finished. Click OK to open a new Terminal window where you can run the application setup script." & return & return & "Next: Run ./run-app-setup.sh to install development tools." buttons {"OK"} default button "OK" with title "Setup Complete"
end tell

tell application "Terminal"
  activate
  do script "cd ${APP_SETUP_DIR}"
end tell
EOF

log "✅ Setup complete! New Terminal window opened for application setup."
log "It's now safe to close this Terminal window."

exit 0
