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

# Headroom removed 2026-07-28 — see issue #55.
# Teardown is idempotent and safe on machines that never had it.
remove_headroom() {
  local claude_cmd="$1"
  local plist_label="com.headroom.proxy"

  # System-domain LaunchDaemon (current layout)
  if [[ -f "/Library/LaunchDaemons/${plist_label}.plist" ]]; then
    if sudo /bin/launchctl bootout "system/${plist_label}" 2>>"${LOG_FILE}"; then
      show_log "Removed headroom proxy LaunchDaemon"
    else
      show_log "WARNING: failed to bootout headroom proxy LaunchDaemon (may already be stopped)"
    fi
    if sudo rm -f "/Library/LaunchDaemons/${plist_label}.plist" 2>>"${LOG_FILE}"; then
      show_log "Removed headroom proxy LaunchDaemon plist"
    else
      show_log "WARNING: failed to remove /Library/LaunchDaemons/${plist_label}.plist (sudo required)"
    fi
  fi

  # User-domain LaunchAgent (legacy layout)
  local legacy_agent="${HOME}/Library/LaunchAgents/${plist_label}.plist"
  if [[ -f "${legacy_agent}" ]]; then
    launchctl bootout "user/$(id -u)/${plist_label}" 2>/dev/null || true
    rm -f "${legacy_agent}"
    show_log "Removed legacy headroom proxy LaunchAgent"
  fi

  if command -v "${claude_cmd}" &>/dev/null || [[ -x "${claude_cmd}" ]]; then
    "${claude_cmd}" mcp remove headroom -s user >>"${LOG_FILE}" 2>&1 || true
  fi

  if command -v pipx &>/dev/null && pipx list 2>/dev/null | grep -q headroom-ai; then
    pipx uninstall headroom-ai >>"${LOG_FILE}" 2>&1 || true
    show_log "Uninstalled headroom-ai"
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

    # Remove headroom (context compression MCP) — removed 2026-07-28, see issue #55.
    remove_headroom "${claude_cmd}"

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

    # Install Claude Code plugin marketplaces and plugins
    CURRENT_SECTION="Plugins"
    section "Claude Code Plugins"

    # Marketplaces as ordered name:repo pairs
    local marketplaces=(
      "superpowers-marketplace:obra/superpowers-marketplace"
      "claude-code-workflows:wshobson/agents"
      "smartwatermelon-marketplace:smartwatermelon/smartwatermelon-marketplace"
    )

    for entry in "${marketplaces[@]}"; do
      local mp_name="${entry%%:*}"
      local mp_repo="${entry#*:}"
      if "${claude_cmd}" plugins marketplace list 2>/dev/null | grep -q "${mp_name}"; then
        show_log "OK: ${mp_name} marketplace registered"
      else
        local mp_exit=0
        show_log "Adding ${mp_name} marketplace..."
        "${claude_cmd}" plugins marketplace add "${mp_repo}" >>"${LOG_FILE}" 2>&1 || mp_exit=$?
        check_success "${mp_exit}" "Add ${mp_name}" || true
      fi
    done

    # Enabled plugins (plugin@marketplace)
    local enabled_plugins=(
      "superpowers@superpowers-marketplace"
      "comprehensive-review@claude-code-workflows"
      "code-critic@smartwatermelon-marketplace"
      "ci-workflows@smartwatermelon-marketplace"
    )

    for plugin in "${enabled_plugins[@]}"; do
      if "${claude_cmd}" plugins list 2>/dev/null | grep -q "${plugin}"; then
        show_log "OK: ${plugin} installed"
      else
        local pl_exit=0
        show_log "Installing ${plugin}..."
        "${claude_cmd}" plugins install "${plugin}" --scope user >>"${LOG_FILE}" 2>&1 || pl_exit=$?
        check_success "${pl_exit}" "Install ${plugin}" || true
      fi
    done
  else
    show_log "Claude Code not installed — skipping MCP setup"
  fi

  # Verify GitHub CLI authentication (required for post-push-loop)
  CURRENT_SECTION="GitHub CLI Auth"
  section "GitHub CLI Authentication"

  if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      show_log "OK: gh CLI authenticated"
    else
      show_log "WARNING: gh CLI not authenticated"
      show_log "Run 'gh auth login' to enable post-push-loop CI monitoring"
      show_log "(Required for: /post-push-loop, PR review iteration, CI status checks)"
    fi
  else
    show_log "WARNING: gh CLI not installed — install via 'brew install gh'"
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

  # Verify post-push-loop dependencies
  CURRENT_SECTION="Post-Push Loop"
  section "Post-Push Loop Readiness"

  local ppl_ready=true

  if [[ -x "${HOME}/.claude/scripts/post-push-status.sh" ]]; then
    show_log "OK: post-push-status.sh"
  else
    show_log "MISSING: ~/.claude/scripts/post-push-status.sh"
    ppl_ready=false
  fi

  if [[ -f "${HOME}/.config/git/hooks/pre-push" ]]; then
    if grep -q "POSTPUSH_LOOP" "${HOME}/.config/git/hooks/pre-push" 2>/dev/null; then
      show_log "OK: pre-push hook (POSTPUSH_LOOP support)"
    else
      show_log "WARNING: pre-push hook exists but lacks POSTPUSH_LOOP support"
      ppl_ready=false
    fi
  else
    show_log "MISSING: ~/.config/git/hooks/pre-push"
    ppl_ready=false
  fi

  for dep in gh jq python3; do
    if command -v "${dep}" &>/dev/null; then
      show_log "OK: ${dep}"
    else
      show_log "MISSING: ${dep}"
      ppl_ready=false
    fi
  done

  if ! gh auth status &>/dev/null; then
    ppl_ready=false
  fi

  if [[ "${ppl_ready}" == true ]]; then
    show_log "/post-push-loop: READY"
  else
    show_log "/post-push-loop: NOT READY (see warnings above)"
  fi

  # Summary
  section "Claude Setup Summary"

  if command -v claude &>/dev/null; then
    local claude_version
    claude_version="$(claude --version 2>/dev/null)" || claude_version="installed"
    show_log "Claude Code: ${claude_version}"
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
