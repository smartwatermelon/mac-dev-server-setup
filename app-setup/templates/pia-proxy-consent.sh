#!/usr/bin/env bash
set -euo pipefail

# pia-proxy-consent.sh - PIA Proxy Configuration Consent Auto-Clicker
#
# Auto-clicks "Allow" on the macOS PIA proxy consent dialog.
#
# PIA's NETransparentProxyManager periodically loses its NE consent signature,
# causing macOS to present a "Would Like to Add Proxy Configurations" dialog.
# This can happen at boot OR at any point during uptime. On a headless server,
# this blocks split tunnel activation indefinitely.
#
# Runs as a periodic LaunchAgent (every 60s via StartInterval). Each invocation
# does a single check and exits; launchd handles scheduling.
#
# Prerequisites:
#   Accessibility permission for /bin/bash (or the shell running this script).
#   Grant at: System Settings > Privacy & Security > Accessibility
#
# Usage: Launched automatically by com.<hostname>.pia-proxy-consent LaunchAgent.
#   Not intended for manual execution.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-17

LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/pia-proxy-consent.log"

mkdir -p "${LOG_DIR}"

log_msg() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] $1" >>"${LOG_FILE}"
}

click_allow() {
  # The NE consent dialog can be presented by different system processes
  # depending on macOS version. Try the known candidates in order.
  local candidates=(
    "UserNotificationCenter"
    "CoreServicesUIAgent"
    "SecurityAgent"
  )

  for process_name in "${candidates[@]}"; do
    # Check if the process exists and has the PIA dialog
    local result
    result=$(osascript -e "
            tell application \"System Events\"
                if exists process \"${process_name}\" then
                    tell process \"${process_name}\"
                        repeat with w in windows
                            try
                                -- Look for the dialog by checking static text content
                                set windowText to value of every static text of w
                                repeat with t in windowText
                                    if t contains \"Proxy Configurations\" then
                                        -- Found the dialog, click Allow
                                        click button \"Allow\" of w
                                        return \"clicked\"
                                    end if
                                end repeat
                            end try
                        end repeat
                    end tell
                end if
            end tell
            return \"not_found\"
        " 2>/dev/null) || true

    if [[ "${result}" == "clicked" ]]; then
      log_msg "Clicked Allow on PIA proxy consent dialog (process: ${process_name})"
      return 0
    fi
  done

  # Fallback: check ALL visible processes (slower but catches unknown presenters)
  local result
  result=$(osascript -e "
        tell application \"System Events\"
            repeat with p in (every process whose visible is true)
                set pName to name of p
                try
                    repeat with w in (every window of p)
                        set windowText to value of every static text of w
                        repeat with t in windowText
                            if t contains \"Proxy Configurations\" then
                                click button \"Allow\" of w
                                return \"clicked:\" & pName
                            end if
                        end repeat
                    end repeat
                end try
            end repeat
        end tell
        return \"not_found\"
    " 2>/dev/null) || true

  if [[ "${result}" == clicked:* ]]; then
    local found_process="${result#clicked:}"
    log_msg "Clicked Allow on PIA proxy consent dialog (process: ${found_process} via fallback)"
    return 0
  fi

  return 1
}

# --- Main ---
# Single-pass check. launchd re-runs this every 60s via StartInterval.

if click_allow; then
  log_msg "Auto-clicked Allow. Exiting."
fi

# Exit silently if no dialog found (normal case — no log spam).
exit 0
