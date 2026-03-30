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

  # Clone Claude configuration repository (~/.claude)
  CURRENT_SECTION="Claude Config Repo"
  section "Claude Configuration Repository"

  local config_repo="${CLAUDE_CONFIG_REPO:-}"
  if [[ -z "${config_repo}" ]]; then
    show_log "CLAUDE_CONFIG_REPO not configured — skipping config repo"
  else
    local claude_dir="${HOME}/.claude"

    if [[ -d "${claude_dir}/.git" ]] && git -C "${claude_dir}" rev-parse --git-dir &>/dev/null; then
      show_log "Updating existing Claude config repo..."
      local pull_exit=0
      git -C "${claude_dir}" pull --ff-only >>"${LOG_FILE}" 2>&1 || pull_exit=$?
      check_success "${pull_exit}" "Claude config repo update" || true
    elif [[ -d "${claude_dir}" ]]; then
      # Directory exists but is not a repo (auto-generated by Claude Code).
      # Overlay the repo onto existing files.  Auto-generated files
      # (.claude.json, backups/, etc.) are covered by the repo's .gitignore.
      # Clean up any leftover .git from a previous failed attempt.
      if [[ -d "${claude_dir}/.git" ]] && ! git -C "${claude_dir}" rev-parse --git-dir &>/dev/null; then
        show_log "Removing leftover .git from previous failed attempt"
        rm -rf "${claude_dir}/.git"
      fi
      show_log "Initialising config repo in existing ${claude_dir}..."
      local init_exit=0
      (
        git -C "${claude_dir}" init \
          && { git -C "${claude_dir}" remote set-url origin "${config_repo}" 2>/dev/null \
            || git -C "${claude_dir}" remote add origin "${config_repo}"; } \
          && git -C "${claude_dir}" fetch origin \
          && git -C "${claude_dir}" checkout -b main origin/main
      ) >>"${LOG_FILE}" 2>&1 || init_exit=$?
      if [[ "${init_exit}" -ne 0 ]]; then
        show_log "Config repo init failed — cleaning up partial .git"
        rm -rf "${claude_dir}/.git"
      fi
      check_success "${init_exit}" "Claude config repo init" || true
    else
      show_log "Cloning Claude config repo..."
      local clone_exit=0
      git clone "${config_repo}" "${claude_dir}" >>"${LOG_FILE}" 2>&1 || clone_exit=$?
      check_success "${clone_exit}" "Claude config repo clone" || true
    fi
  fi

  # Install MCP servers (global, user-scoped)
  CURRENT_SECTION="MCP Servers"
  section "MCP Server Configuration"

  if command -v claude &>/dev/null || [[ -x "${HOME}/.local/bin/claude" ]]; then
    local claude_cmd="claude"
    if ! command -v claude &>/dev/null; then
      claude_cmd="${HOME}/.local/bin/claude"
    fi

    # Install headroom (context compression MCP)
    show_log "Installing headroom (context compression)..."
    if command -v pipx &>/dev/null || [[ -x "/opt/homebrew/bin/pipx" ]]; then
      local pipx_cmd="pipx"
      command -v pipx &>/dev/null || pipx_cmd="/opt/homebrew/bin/pipx"

      local pipx_exit=0
      "${pipx_cmd}" install headroom-ai >>"${LOG_FILE}" 2>&1 || pipx_exit=$?
      if [[ ${pipx_exit} -eq 0 ]]; then
        # headroom needs the mcp SDK to function as a Claude Code MCP server
        local inject_exit=0
        "${pipx_cmd}" inject headroom-ai mcp >>"${LOG_FILE}" 2>&1 || inject_exit=$?
        if [[ ${inject_exit} -ne 0 ]]; then
          collect_error "Failed to inject mcp SDK into headroom-ai (required for MCP server)"
        fi
        # proxy dependencies (fastapi, uvicorn, httpx with h2)
        "${pipx_cmd}" inject headroom-ai fastapi uvicorn >>"${LOG_FILE}" 2>&1 || true
        "${pipx_cmd}" inject headroom-ai "httpx[http2]" --force >>"${LOG_FILE}" 2>&1 || true
        show_log "OK: headroom-ai installed via pipx"

        # Resolve absolute path for MCP config (pipx symlink may not be on PATH)
        local headroom_bin
        headroom_bin="$(command -v headroom 2>/dev/null || echo "${HOME}/.local/bin/headroom")"
        if [[ ! -x "${headroom_bin}" ]]; then
          collect_error "headroom binary not found or not executable at ${headroom_bin}"
        fi

        # Add headroom as Claude Code MCP server
        local add_exit=0
        "${claude_cmd}" mcp add headroom -s user -- "${headroom_bin}" mcp serve >>"${LOG_FILE}" 2>&1 || add_exit=$?
        check_success "${add_exit}" "Add headroom MCP (global)" || true

        # Install headroom proxy LaunchAgent (provides ANTHROPIC_BASE_URL proxy)
        local proxy_port=8787
        if lsof -i ":${proxy_port}" -sTCP:LISTEN &>/dev/null; then
          show_log "WARNING: port ${proxy_port} already in use — skipping headroom proxy LaunchAgent"
        else
          local plist_name="com.headroom.proxy.plist"
          local plist_dest="${HOME}/Library/LaunchAgents/${plist_name}"
          local gui_domain
          gui_domain="gui/$(id -u)"
          mkdir -p "${HOME}/Library/Logs/headroom"
          cat >"${plist_dest}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.headroom.proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>${headroom_bin}</string>
        <string>proxy</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>${proxy_port}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HEADROOM_PROXY_PORT</key>
        <string>${proxy_port}</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>${HOME}</string>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/headroom/proxy.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/headroom/proxy-error.log</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Adaptive</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST
          launchctl bootout "${gui_domain}/com.headroom.proxy" 2>/dev/null || true
          launchctl bootstrap "${gui_domain}" "${plist_dest}" 2>>"${LOG_FILE}"
          show_log "OK: headroom proxy LaunchAgent installed and loaded (port ${proxy_port})"
        fi
      else
        collect_error "headroom-ai installation failed (pipx exit ${pipx_exit})"
      fi
    else
      collect_error "pipx not found — cannot install headroom-ai"
    fi

    # Add Context7 MCP (documentation lookup)
    local context7_key="${CONTEXT7_API_KEY:-}"
    if [[ -n "${context7_key}" ]]; then
      show_log "Adding Context7 MCP..."
      local ctx_exit=0
      "${claude_cmd}" mcp add context7 --transport http -s user \
        "https://mcp.context7.com/mcp" \
        --header "CONTEXT7_API_KEY: ${context7_key}" >>"${LOG_FILE}" 2>&1 || ctx_exit=$?
      check_success "${ctx_exit}" "Add Context7 MCP (global)" || true
    else
      show_log "CONTEXT7_API_KEY not configured — skipping Context7 MCP"
    fi

    # Note: Cloud-synced MCPs (Sentry, Gmail, Google Calendar, Netlify, etc.)
    # are tied to the Claude account and appear automatically after `claude auth login`.
    # Project-specific MCPs (RevenueCat, Brevo, etc.) are configured per-repo
    # in each project's .mcp.json file.
    show_log "Note: Run 'claude auth login' to enable cloud-synced MCPs (Sentry, Gmail, Calendar, etc.)"
  else
    show_log "Claude Code not installed — skipping MCP setup"
  fi

  # Clone user scripts repository
  CURRENT_SECTION="Scripts Repo"
  section "User Scripts Repository"

  local scripts_repo="${SCRIPTS_REPO:-}"
  if [[ -z "${scripts_repo}" ]]; then
    show_log "SCRIPTS_REPO not configured — skipping"
  else
    local scripts_dir="${HOME}/Developer/scripts"
    if [[ -d "${scripts_dir}/.git" ]]; then
      show_log "Updating existing scripts repo..."
      local pull_exit=0
      git -C "${scripts_dir}" pull --ff-only >>"${LOG_FILE}" 2>&1 || pull_exit=$?
      check_success "${pull_exit}" "Scripts repo update" || true
    else
      show_log "Cloning scripts repo..."
      mkdir -p "${HOME}/Developer"
      local clone_exit=0
      git clone "${scripts_repo}" "${scripts_dir}" >>"${LOG_FILE}" 2>&1 || clone_exit=$?
      check_success "${clone_exit}" "Scripts repo clone" || true
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
