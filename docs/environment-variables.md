# Environment Variables Reference

Complete guide to customizing Mac Mini dev server setup via environment variables

## Overview

The Mac Mini dev server setup system supports extensive customization through environment variables. These can be set in your shell environment, added to `config/config.conf`, or passed directly to scripts.

## Primary Configuration Variables

### Server Identity

**Location**: `config/config.conf` (required)

```bash
# Primary server identifier (affects hostname, volume names, etc.)
SERVER_NAME="macmini"

# Custom hostname override (optional)
HOSTNAME_OVERRIDE=""
```

### 1Password Integration

**Location**: `config/config.conf` (required)

```bash
# 1Password vault containing server credentials
ONEPASSWORD_VAULT="personal"

# 1Password item names (customizable)
ONEPASSWORD_TIMEMACHINE_ITEM="Synology NAS - TimeMachine"
ONEPASSWORD_APPLEID_ITEM="Apple"
SSH_KEY_ITEM="SSH Keys"
```

### Development Configuration

**Location**: `config/config.conf`

```bash
# Dotfiles repository for shell/editor configuration
DOTFILES_REPO="git@github.com:smartwatermelon/dotfiles.git"

# Android SDK platform version to install
ANDROID_SDK_VERSION="34"

# Node.js version to install via nvm
NODE_VERSION="lts"

# Xcode version (empty = latest from App Store)
XCODE_VERSION=""
```

## Advanced Configuration Variables

### Terminal Configuration

**Location**: `config/config.conf`

```bash
# Enable iTerm2 preference export
USE_ITERM2="false"

# Terminal profile file to include (from config/ directory)
TERMINAL_PROFILE_FILE=""
```

**Usage**: Controls terminal application setup during deployment.

## Runtime Control Variables

### Script Behavior Control

**Location**: Set by scripts during execution

```bash
# Skip confirmation prompts in first-boot.sh
FORCE="true"

# Control software update installation
SKIP_UPDATE="true"     # Recommended - updates unreliable during setup
SKIP_HOMEBREW="false"  # Skip Homebrew installation
SKIP_PACKAGES="false"  # Skip package installation

# Full Disk Access rerun control
RERUN_AFTER_FDA="false"

# Service restart flags
NEED_SYSTEMUI_RESTART="false"
NEED_CONTROLCENTER_RESTART="false"
```

### Administrator Password

**Location**: Runtime collection

```bash
# Administrator password for system modifications
ADMINISTRATOR_PASSWORD=""  # Collected interactively, cleared after use
```

**Security**: Always collected interactively and cleared from memory after use.

## Derived Variables

### Computed Names

Auto-generated based on primary configuration

```bash
# Final hostname (with override support)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"

# Lowercase version for file paths
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Server name in lowercase
SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
```

### File Paths

Auto-generated directory and file locations

```bash
# Deployment package output
OUTPUT_PATH="${HOME}/${SERVER_NAME_LOWER}-setup"

# Setup and configuration directories
SETUP_DIR="$(pwd)"  # Deployment package root
CONFIG_DIR="${SETUP_DIR}/config"
LOG_DIR="${HOME}/.local/state"

# Application-specific paths
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
```

## Security Variables

### Hardware Fingerprinting

**Location**: Auto-generated during prep-airdrop.sh

```bash
# Development machine hardware fingerprint
DEV_FINGERPRINT="$(system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}')"

# External keychain password (uses hardware UUID)
KEYCHAIN_PASSWORD="${DEV_FINGERPRINT}"
EXTERNAL_KEYCHAIN="mac-server-setup"
```

### Keychain Service Identifiers

**Location**: Auto-generated in keychain manifest

```bash
# Service identifiers for credential retrieval
KEYCHAIN_TIMEMACHINE_SERVICE="timemachine-${SERVER_NAME_LOWER}"
KEYCHAIN_WIFI_SERVICE="wifi-${SERVER_NAME_LOWER}"
```

## Error Collection Variables

### Error Tracking System

**Location**: All setup scripts

```bash
# Error and warning collection arrays
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()

# Current section context for error reporting
CURRENT_SCRIPT_SECTION=""
```

## Setting Environment Variables

### In config.conf

```bash
# Edit config/config.conf
SERVER_NAME="MYSERVER"
DOTFILES_REPO="git@github.com:user/dotfiles.git"
NODE_VERSION="20"
```

### In Shell Environment

```bash
# Set before running scripts
export ANDROID_SDK_VERSION="35"
./prep-airdrop.sh
```

### Command Line Override

```bash
# Some variables can be overridden via flags
./first-boot.sh --force  # Sets FORCE=true
```

## Variable Validation

### Required Variables

These must be set in `config/config.conf`:

- `SERVER_NAME`
- `ONEPASSWORD_VAULT`
- `ONEPASSWORD_APPLEID_ITEM`
- `ONEPASSWORD_TIMEMACHINE_ITEM`

### Optional Variables

These have sensible defaults if not set:

- `HOSTNAME_OVERRIDE` (defaults to `SERVER_NAME`)
- `DOTFILES_REPO` (dotfiles clone skipped if empty)
- `ANDROID_SDK_VERSION` (defaults to "34")
- `NODE_VERSION` (defaults to "lts")
- `XCODE_VERSION` (empty = latest from App Store)
- `SSH_KEY_ITEM` (defaults to "SSH Keys")
- Terminal configuration variables

### Auto-Generated Variables

These are computed automatically:

- All `*_LOWER` variables
- All path variables (`*_DIR`, `*_PATH`)
- Hardware fingerprint variables
- Keychain service identifiers

## Troubleshooting

### Common Issues

**Variable Not Taking Effect**:

- Check `config/config.conf` syntax (no spaces around `=`)
- Verify variable is exported in shell environment
- Some variables only work in specific scripts

**Path Variables Incorrect**:

- Ensure `SERVER_NAME` is set correctly
- Check that derived variables are computed properly
- Verify deployment package structure

**1Password Variables**:

- Confirm vault name matches exactly (case-sensitive)
- Verify all required 1Password items exist
- Check `op whoami` authentication status

### Debug Variable Values

```bash
# Check current variable values
echo "SERVER_NAME: ${SERVER_NAME}"
echo "HOSTNAME_LOWER: ${HOSTNAME_LOWER}"
echo "OUTPUT_PATH: ${OUTPUT_PATH}"

# Verify 1Password configuration
echo "Vault: ${ONEPASSWORD_VAULT}"
op item list --vault "${ONEPASSWORD_VAULT}"
```

## Security Considerations

### Sensitive Variables

- `ADMINISTRATOR_PASSWORD`: Never logged, cleared after use
- `*_PASSWORD`: Masked in all log output
- Hardware fingerprints: Used for security validation
- Keychain passwords: Generated from hardware UUID

### Variable Scope

- Configuration variables: Global across all scripts
- Runtime variables: Local to specific script execution
- Derived variables: Computed fresh each time
- Security variables: Auto-generated and protected

This environment variable system provides extensive customization while maintaining security and ease of use.
