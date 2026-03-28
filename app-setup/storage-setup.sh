#!/usr/bin/env bash
#
# storage-setup.sh - External storage configuration for development
#
# Configures an external drive for large development artifacts:
# - Workspaces (project checkouts)
# - iOS Simulator runtimes and devices
# - Android AVD images
# - Package manager caches (CocoaPods, Homebrew downloads)
#
# Creates symlinks from standard macOS locations to the external volume
# so tools find their data where they expect it.
#
# Prerequisites:
# - External volume mounted (configured via EXTERNAL_STORAGE_VOLUME)
#
# Usage: ./storage-setup.sh [--force]
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
CURRENT_SECTION="Storage Setup"

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

# Ensure a symlink exists from source to target.
# If source is a real directory, moves its contents to target first.
ensure_symlink() {
  local link_path="$1"
  local target_path="$2"
  local description="$3"

  # Target directory must exist
  if [[ ! -d "${target_path}" ]]; then
    mkdir -p "${target_path}"
    log "Created directory: ${target_path}"
  fi

  if [[ -L "${link_path}" ]]; then
    local existing_target
    existing_target="$(readlink "${link_path}")"
    if [[ "${existing_target}" == "${target_path}" ]]; then
      show_log "OK: ${description} symlink already correct"
      return 0
    else
      show_log "Updating ${description} symlink: ${existing_target} -> ${target_path}"
      rm "${link_path}"
    fi
  elif [[ -d "${link_path}" ]]; then
    # Real directory exists — migrate contents
    show_log "Migrating existing ${description} to external storage..."
    local file_count
    file_count="$(find "${link_path}" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')"
    if [[ "${file_count}" -gt 0 ]]; then
      rsync -a "${link_path}/" "${target_path}/" >>"${LOG_FILE}" 2>&1
      log "Migrated ${file_count} items from ${link_path} to ${target_path}"
    fi
    rm -rf "${link_path}"
  fi

  # Create parent directory if needed
  local parent_dir
  parent_dir="$(dirname "${link_path}")"
  if [[ ! -d "${parent_dir}" ]]; then
    mkdir -p "${parent_dir}"
  fi

  ln -s "${target_path}" "${link_path}"
  show_log "OK: ${description} -> ${target_path}"
}

# Main execution
main() {
  section "External Storage Configuration"

  # Validate external storage volume
  local volume="${EXTERNAL_STORAGE_VOLUME:-}"
  if [[ -z "${volume}" ]]; then
    show_log "EXTERNAL_STORAGE_VOLUME not configured — skipping storage setup"
    show_log "Set EXTERNAL_STORAGE_VOLUME in config.conf to enable"
    exit 0
  fi

  if [[ ! -d "${volume}" ]]; then
    collect_error "External volume not mounted: ${volume}"
    show_log "Ensure the drive is connected and mounted before running storage setup"
    exit 1
  fi

  # Check volume is writable
  if [[ ! -w "${volume}" ]]; then
    collect_error "External volume not writable: ${volume}"
    exit 1
  fi

  local volume_info
  volume_info="$(df -h "${volume}" 2>/dev/null | tail -1)"
  show_log "External volume: ${volume}"
  show_log "Volume info: ${volume_info}"

  if [[ "${FORCE}" != true ]]; then
    show_log ""
    show_log "This will configure external storage at ${volume} for:"
    show_log "  - Workspaces (~/Developer)"
    show_log "  - iOS Simulator runtimes"
    show_log "  - Android AVD images"
    show_log "  - Package caches"
    show_log ""
    show_log "Existing data in these locations will be migrated."
    show_log ""

    read -r -n 1 -p "Proceed with storage configuration? (Y/n): " response
    echo
    case "${response}" in
      [nN])
        show_log "Storage configuration cancelled by user"
        exit 0
        ;;
      *)
        show_log "Proceeding with storage configuration..."
        ;;
    esac
  fi

  # Create top-level directories on external volume
  CURRENT_SECTION="Directory Creation"
  section "Creating directory structure on ${volume}"

  local -a STORAGE_DIRS=(
    "${volume}/Workspaces"
    "${volume}/Simulators"
    "${volume}/Android/avd"
    "${volume}/Caches/CocoaPods"
    "${volume}/Caches/Homebrew"
  )

  for dir in "${STORAGE_DIRS[@]}"; do
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}"
      show_log "Created: ${dir}"
    else
      show_log "OK: ${dir} exists"
    fi
  done

  # Set up symlinks
  CURRENT_SECTION="Symlink Configuration"
  section "Configuring symlinks"

  # ~/Developer -> external Workspaces
  ensure_symlink \
    "${HOME}/Developer" \
    "${volume}/Workspaces" \
    "Developer workspace"

  # iOS Simulator devices -> external storage
  # CoreSimulator stores device data here (runtimes are managed separately)
  ensure_symlink \
    "${HOME}/Library/Developer/CoreSimulator/Devices" \
    "${volume}/Simulators/Devices" \
    "iOS Simulator devices"

  # Xcode derived data (build caches, can be very large)
  ensure_symlink \
    "${HOME}/Library/Developer/Xcode/DerivedData" \
    "${volume}/Caches/DerivedData" \
    "Xcode DerivedData"

  # Android AVD images
  ensure_symlink \
    "${HOME}/.android/avd" \
    "${volume}/Android/avd" \
    "Android AVD images"

  # CocoaPods cache
  ensure_symlink \
    "${HOME}/Library/Caches/CocoaPods" \
    "${volume}/Caches/CocoaPods" \
    "CocoaPods cache"

  # Homebrew download cache
  ensure_symlink \
    "${HOME}/Library/Caches/Homebrew" \
    "${volume}/Caches/Homebrew" \
    "Homebrew download cache"

  # Verification
  CURRENT_SECTION="Verification"
  section "Verifying storage configuration"

  for dir in "${HOME}/Developer" \
    "${HOME}/Library/Developer/CoreSimulator/Devices" \
    "${HOME}/Library/Developer/Xcode/DerivedData" \
    "${HOME}/.android/avd" \
    "${HOME}/Library/Caches/CocoaPods" \
    "${HOME}/Library/Caches/Homebrew"; do
    if [[ -L "${dir}" ]]; then
      local target
      target="$(readlink "${dir}")"
      if [[ -d "${target}" ]]; then
        show_log "OK: ${dir} -> ${target}"
      else
        collect_error "Symlink target missing: ${dir} -> ${target}"
      fi
    else
      collect_error "Expected symlink not found: ${dir}"
    fi
  done

  # Report disk usage
  show_log ""
  show_log "External storage usage:"
  du -sh "${volume}"/* 2>/dev/null | while IFS= read -r line; do
    show_log "  ${line}"
  done

  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
    show_log ""
    show_log "Storage setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
    exit 1
  fi

  show_log "Storage setup completed successfully"
}

main "$@"
