#!/usr/bin/env bash
#
# claude-setup.sh - Claude Code CLI and wrapper installation
#
# Installs Claude Code CLI via the official installer and optionally
# deploys the claude-wrapper for identity management and secrets.
#
# Prerequisites:
# - curl installed
# - git installed
# - Node.js installed (for npm-based fallback)
#
# Usage: ./claude-setup.sh [--force]
#   --force: Skip confirmation prompts
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-03-27

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
CURRENT_SECTION="Claude Setup"

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

# Main execution
main() {
  section "Claude Code CLI Installation"
  show_log "Starting Claude Code setup..."

  # Install Claude Code CLI
  CURRENT_SECTION="Claude Code CLI"

  if command -v claude &>/dev/null; then
    local current_version
    current_version="$(claude --version 2>/dev/null || echo "unknown")"
    show_log "Claude Code already installed: ${current_version}"

    if [[ "${FORCE}" != true ]]; then
      show_log "Use --force to update to latest version"
    else
      # Update to latest
      show_log "Checking for updates..."
      local update_exit=0
      claude update --yes >>"${LOG_FILE}" 2>&1 || update_exit=$?
      if [[ ${update_exit} -eq 0 ]]; then
        local new_version
        new_version="$(claude --version 2>/dev/null || echo "unknown")"
        show_log "OK: Claude Code updated to ${new_version}"
      else
        show_log "Update check completed (may already be latest)"
      fi
    fi
  else
    show_log "Installing Claude Code CLI..."

    # Ensure ~/.local/bin exists and is in PATH
    mkdir -p "${HOME}/.local/bin"

    # Use npm to install (simplest cross-platform method)
    if command -v npm &>/dev/null; then
      local install_exit=0
      npm install -g @anthropic-ai/claude-code >>"${LOG_FILE}" 2>&1 || install_exit=$?

      if [[ ${install_exit} -ne 0 ]]; then
        show_log "npm install failed, trying curl installer..."
        # Fallback to curl-based installer
        local curl_exit=0
        curl -fsSL https://claude.ai/install.sh | sh >>"${LOG_FILE}" 2>&1 || curl_exit=$?
        check_success "${curl_exit}" "Claude Code installation (curl)"
      else
        check_success 0 "Claude Code installation (npm)"
      fi
    else
      # No npm — use curl installer directly
      local curl_exit=0
      curl -fsSL https://claude.ai/install.sh | sh >>"${LOG_FILE}" 2>&1 || curl_exit=$?
      check_success "${curl_exit}" "Claude Code installation (curl)"
    fi

    # Verify installation
    if command -v claude &>/dev/null; then
      local installed_version
      installed_version="$(claude --version 2>/dev/null || echo "unknown")"
      show_log "OK: Claude Code installed: ${installed_version}"
    else
      # Check if it landed in ~/.local/bin but PATH doesn't include it yet
      if [[ -x "${HOME}/.local/bin/claude" ]]; then
        show_log "OK: Claude Code installed at ~/.local/bin/claude"
        show_log "Note: Add ~/.local/bin to PATH in your shell profile"
      else
        collect_error "Claude Code installation failed — binary not found"
      fi
    fi
  fi

  # Install claude-wrapper
  CURRENT_SECTION="Claude Wrapper"
  section "Claude Wrapper Installation"

  local wrapper_repo="${CLAUDE_WRAPPER_REPO:-}"
  if [[ -z "${wrapper_repo}" ]]; then
    show_log "CLAUDE_WRAPPER_REPO not configured — skipping wrapper installation"
  else
    local wrapper_dir="${HOME}/.claude-wrapper"

    if [[ -d "${wrapper_dir}/.git" ]]; then
      show_log "Updating existing claude-wrapper..."
      local pull_exit=0
      git -C "${wrapper_dir}" pull --ff-only >>"${LOG_FILE}" 2>&1 || pull_exit=$?
      check_success "${pull_exit}" "Claude wrapper update" || true
    else
      show_log "Cloning claude-wrapper..."
      local clone_exit=0

      # Move aside stale directory if exists without .git
      if [[ -d "${wrapper_dir}" ]]; then
        local backup
        backup="${wrapper_dir}.bak.$(date +%Y%m%d%H%M%S)"
        mv "${wrapper_dir}" "${backup}"
        show_log "Moved stale ${wrapper_dir} to ${backup}"
      fi

      git clone "${wrapper_repo}" "${wrapper_dir}" >>"${LOG_FILE}" 2>&1 || clone_exit=$?
      if ! check_success "${clone_exit}" "Claude wrapper clone"; then
        show_log "Ensure SSH key is deployed and has access to the repository"
      fi
    fi

    # Create symlink for the wrapper
    if [[ -f "${wrapper_dir}/bin/claude-wrapper" ]]; then
      mkdir -p "${HOME}/.local/bin"
      local wrapper_link="${HOME}/.local/bin/claude-wrapper"

      if [[ -L "${wrapper_link}" ]] || [[ -f "${wrapper_link}" ]]; then
        rm "${wrapper_link}"
      fi
      ln -s "${wrapper_dir}/bin/claude-wrapper" "${wrapper_link}"
      chmod +x "${wrapper_dir}/bin/claude-wrapper"
      show_log "OK: claude-wrapper symlinked to ${wrapper_link}"
    else
      collect_error "claude-wrapper binary not found at ${wrapper_dir}/bin/claude-wrapper"
    fi
  fi

  # Summary
  section "Claude Setup Summary"

  if command -v claude &>/dev/null; then
    show_log "Claude Code: $(claude --version 2>/dev/null || echo "installed")"
  else
    show_log "Claude Code: not in PATH"
  fi

  if [[ -L "${HOME}/.local/bin/claude-wrapper" ]]; then
    show_log "Claude Wrapper: installed"
  else
    show_log "Claude Wrapper: not installed"
  fi

  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
    show_log ""
    show_log "Claude setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
    exit 1
  fi

  show_log "Claude setup completed successfully"
}

main "$@"
