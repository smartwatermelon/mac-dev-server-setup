#!/usr/bin/env bash
#
# setup-application-preparation.sh - Application setup directory preparation
#
# This script handles the preparation of application setup directories and files,
# including:
# - Creating and populating application setup directory structure
# - Copying configuration files
# - Setting proper file permissions
#
# Usage: ./setup-application-preparation.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2025-09-05

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false

for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Determine script and setup directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(dirname "${SCRIPT_DIR}")" # Go up one level to reach scripts/
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
fi

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# Local logging functions
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

  show_log "ERROR: ${clean_message}"
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

  show_log "WARNING: ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "OK: $1"
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

#
# APPLICATION SETUP PREPARATION
#

# Create application setup directory
set_section "Preparing Application Setup"
APP_SETUP_DIR="/Users/${ADMIN_USERNAME}/app-setup"

if [[ ! -d "${APP_SETUP_DIR}" ]]; then
  log "Creating application setup directory"
  mkdir -p "${APP_SETUP_DIR}"
  check_success "App setup directory creation"
fi

# Copy application setup directory preserving organized structure
if [[ -d "${SETUP_DIR}/app-setup" ]]; then
  log "Copying application setup directory with organized structure from ${SETUP_DIR}/app-setup"

  # Copy the entire app-setup directory structure
  cp -R "${SETUP_DIR}/app-setup/"* "${APP_SETUP_DIR}/" 2>/dev/null

  # Set proper permissions
  chmod +x "${APP_SETUP_DIR}/"*.sh 2>/dev/null || true
  chmod 600 "${APP_SETUP_DIR}/config/"*.conf 2>/dev/null || true

  check_success "Application directory copy with organized structure"
else
  collect_warning "No application setup directory found in ${SETUP_DIR}/app-setup"
fi

# Copy config.conf for application setup scripts
if [[ -f "${CONFIG_FILE}" ]]; then
  log "Copying config.conf to app-setup config directory"
  mkdir -p "${APP_SETUP_DIR}/config"
  cp "${CONFIG_FILE}" "${APP_SETUP_DIR}/config/config.conf"
  check_success "Config file copy"
else
  collect_warning "No config.conf found - application setup scripts will use defaults"
fi

show_log "Application preparation setup completed successfully"
show_log "Application setup directory: ${APP_SETUP_DIR}"

exit 0
