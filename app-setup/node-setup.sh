#!/usr/bin/env bash
#
# node-setup.sh - Node.js global package configuration
#
# This script configures npm global directory to avoid permission issues
# and installs required global npm packages. Node.js itself is installed
# via Homebrew (formulae.txt).
#
# Prerequisites:
# - Node.js installed via Homebrew
#
# Usage: ./node-setup.sh [--force]
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
CURRENT_SECTION="Node.js Setup"

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

# Global npm packages to install
readonly -a GLOBAL_PACKAGES=(
  "eas-cli"
  "npm-check-updates"
  "n"
  "netlify-cli"
  "puppeteer"
  "url-decode-encode-cli"
)

# npm global directory
readonly NPM_GLOBAL_DIR="${HOME}/.npm-global"

# Main execution
main() {
  section "Node.js Global Package Configuration"
  show_log "Starting Node.js setup..."
  log "NODE_VERSION config: ${NODE_VERSION:-not set}"

  # Verify Node.js is installed
  if ! command -v node &>/dev/null; then
    collect_error "Node.js not found - install via Homebrew first (check formulae.txt)"
    exit 1
  fi

  local node_version
  node_version="$(node --version)"
  show_log "Node.js version: ${node_version}"

  if ! command -v npm &>/dev/null; then
    collect_error "npm not found - Node.js installation may be incomplete"
    exit 1
  fi

  local npm_version
  npm_version="$(npm --version)"
  show_log "npm version: ${npm_version}"

  # Configure npm global directory
  section "Configuring npm Global Directory"

  if [[ ! -d "${NPM_GLOBAL_DIR}" ]]; then
    show_log "Creating npm global directory: ${NPM_GLOBAL_DIR}"
    mkdir -p "${NPM_GLOBAL_DIR}"
  fi

  show_log "Setting npm prefix to ${NPM_GLOBAL_DIR}"
  npm config set prefix "${NPM_GLOBAL_DIR}"
  log "npm prefix set to ${NPM_GLOBAL_DIR}"

  # Add npm global bin to PATH in shell profiles if not already present
  local npm_bin="${NPM_GLOBAL_DIR}/bin"
  local path_line="export PATH=\"${npm_bin}:\${PATH}\""

  for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
    if [[ -f "${profile}" ]]; then
      if ! grep -q "${npm_bin}" "${profile}"; then
        show_log "Adding npm global bin to PATH in ${profile}"
        {
          echo ""
          echo "# npm global packages"
          echo "${path_line}"
        } >>"${profile}"
        log "Updated ${profile} with npm global bin path"
      else
        log "npm global bin already in ${profile}"
      fi
    fi
  done

  # Add to current session
  export PATH="${npm_bin}:${PATH}"

  # Install global packages
  section "Installing Global npm Packages"

  if [[ "${FORCE}" != true ]]; then
    show_log ""
    show_log "The following global npm packages will be installed:"
    for pkg in "${GLOBAL_PACKAGES[@]}"; do
      show_log "  - ${pkg}"
    done
    show_log ""

    read -r -n 1 -p "Proceed with package installation? (Y/n): " response
    echo
    case "${response}" in
      [nN])
        show_log "Package installation cancelled by user"
        exit 0
        ;;
      *)
        show_log "Proceeding with package installation..."
        ;;
    esac
  fi

  local install_exit
  for pkg in "${GLOBAL_PACKAGES[@]}"; do
    show_log "Installing ${pkg}..."

    install_exit=0
    npm install -g "${pkg}" >>"${LOG_FILE}" 2>&1 || install_exit=$?
    check_success "${install_exit}" "${pkg} installation" || true
  done

  # Verification
  section "Verifying Node.js Setup"
  local verify_node verify_npm verify_prefix
  verify_node="$(node --version)" || true
  verify_npm="$(npm --version)" || true
  verify_prefix="$(npm config get prefix)" || true
  show_log "Node.js: ${verify_node}"
  show_log "npm: ${verify_npm}"
  show_log "npm prefix: ${verify_prefix}"

  # Verify installed packages
  for pkg in "${GLOBAL_PACKAGES[@]}"; do
    # Get the command name (first part before any @version)
    local cmd="${pkg%%@*}"
    # Map package name to installed command name where they differ.
    # puppeteer is a library with no CLI binary; verify via node -e instead.
    case "${cmd}" in
      eas-cli) cmd="eas" ;;
      npm-check-updates) cmd="ncu" ;;
      netlify-cli) cmd="netlify" ;;
      url-decode-encode-cli) cmd="url-encode" ;;
      *) ;;
    esac

    if [[ "${pkg}" == "puppeteer" ]]; then
      if node -e "require('puppeteer')" &>/dev/null; then
        show_log "OK: ${pkg} (installed)"
      else
        collect_error "${pkg} module not found after installation"
      fi
    elif command -v "${cmd}" &>/dev/null; then
      local pkg_version
      pkg_version="$("${cmd}" --version 2>/dev/null || echo "installed")"
      show_log "OK: ${pkg} (${pkg_version})"
    else
      collect_error "${pkg} command '${cmd}' not found after installation"
    fi
  done

  # eas login hint — informational only, must not fail setup
  section "Checking EAS Login Status"
  if command -v eas &>/dev/null; then
    local eas_whoami_output
    eas_whoami_output="$(eas whoami 2>&1 || true)"
    if [[ "${eas_whoami_output}" == *"Not logged in"* ]]; then
      show_log ""
      show_log "NOTE: EAS is not logged in. Post-setup checklist:"
      show_log "  - Run 'eas login' to authenticate with your Expo account"
      show_log ""
    else
      show_log "EAS login: ${eas_whoami_output}"
    fi
  else
    log "eas command not available; skipping EAS login check"
  fi

  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
    show_log ""
    show_log "Node.js setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
    exit 1
  fi

  show_log "Node.js setup completed successfully"
}

main "$@"
