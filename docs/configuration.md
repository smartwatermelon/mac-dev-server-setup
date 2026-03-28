# Configuration Reference

The Mac Mini dev server setup is controlled by the `config.conf` file, which allows customization of server identity, credentials, and behavior without modifying the setup scripts.

## Configuration File Format

The configuration uses simple shell variable syntax:

```bash
# config.conf - Configuration file for Mac Mini dev server setup

# Server identity
SERVER_NAME="macmini"

# 1Password configuration
ONEPASSWORD_VAULT="personal"
ONEPASSWORD_APPLEID_ITEM="Apple"
ONEPASSWORD_TIMEMACHINE_ITEM="Synology NAS - TimeMachine"
SSH_KEY_ITEM="SSH Keys"

# Development configuration
DOTFILES_REPO="git@github.com:smartwatermelon/dotfiles.git"
ANDROID_SDK_VERSION="34"
NODE_VERSION="lts"
XCODE_VERSION=""

# Monitoring
MONITORING_EMAIL="your-email@example.com"

# Optional overrides (leave empty to use defaults)
HOSTNAME_OVERRIDE=""
```

## Core Configuration Parameters

### Server Identity

**SERVER_NAME**: Primary identifier for the server

- **Default**: "macmini"
- **Used for**: Hostname, volume name, network identification
- **Format**: Lowercase or uppercase, no spaces (DNS-safe)
- **Example**: `SERVER_NAME="devbox"`

### 1Password Integration

The system uses 1Password for initial credential retrieval during setup preparation, then transfers credentials securely via macOS Keychain Services. See [Keychain-Based Credential Management](keychain-credential-management.md) for complete details.

**ONEPASSWORD_VAULT**: 1Password vault containing server credentials

- **Default**: "personal"
- **Example**: `ONEPASSWORD_VAULT="Infrastructure"`

**ONEPASSWORD_TIMEMACHINE_ITEM**: Login item for Time Machine backup credentials

- **Default**: "Synology NAS - TimeMachine"
- **Requirements**: Login item with username, password, and URL field

**ONEPASSWORD_APPLEID_ITEM**: Login item for Apple ID credentials

- **Default**: "Apple"
- **Requirements**: Login item with Apple ID email and password

**SSH_KEY_ITEM**: 1Password item containing SSH keys for deployment

- **Default**: "SSH Keys"
- **Requirements**: Item with SSH key material

### Development Configuration

**DOTFILES_REPO**: Git repository URL for dotfiles

- **Default**: (user-specific)
- **Usage**: Cloned to the server for shell/editor configuration
- **Example**: `DOTFILES_REPO="git@github.com:user/dotfiles.git"`

**ANDROID_SDK_VERSION**: Android SDK platform version to install

- **Default**: "34"
- **Usage**: Installed via Android command-line tools
- **Example**: `ANDROID_SDK_VERSION="35"`

**NODE_VERSION**: Node.js version to install via nvm

- **Default**: "lts"
- **Usage**: Installed via nvm during setup
- **Example**: `NODE_VERSION="20"`

**XCODE_VERSION**: Xcode version to install

- **Default**: Empty (installs latest from App Store)
- **Usage**: Specific version can be set if needed
- **Example**: `XCODE_VERSION="15.4"`

### Optional Overrides

**HOSTNAME_OVERRIDE**: Custom hostname different from SERVER_NAME

- **Default**: Empty (uses SERVER_NAME)
- **When to use**: When you want a different network hostname
- **Example**: `HOSTNAME_OVERRIDE="dev-server"`

**MONITORING_EMAIL**: Email address for system notifications

- **Default**: "<your-email@example.com>" (should be customized)
- **Usage**: Future monitoring system integration
- **Example**: `MONITORING_EMAIL="admin@yourdomain.com"`

## Derived Variables

The setup scripts automatically calculate additional variables based on your configuration:

### Computed Names

**HOSTNAME**: Final hostname for the system

```bash
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
```

**HOSTNAME_LOWER**: Lowercase version for file paths and system naming

```bash
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
```

### File Paths

**Setup directory structure** based on SERVER_NAME:

- Setup package: `~/macmini-setup` (for SERVER_NAME="macmini")
- Log files: `~/.local/state/macmini-setup.log`

## Customization Examples

### Multiple Server Setup

For managing multiple Mac Mini servers with different roles:

```bash
# Development server configuration
SERVER_NAME="DEVSERVER"
ONEPASSWORD_TIMEMACHINE_ITEM="DevServer TimeMachine"
DOTFILES_REPO="git@github.com:user/dotfiles.git"
NODE_VERSION="lts"
```

```bash
# CI server configuration
SERVER_NAME="CISERVER"
ONEPASSWORD_TIMEMACHINE_ITEM="CIServer TimeMachine"
NODE_VERSION="20"
ANDROID_SDK_VERSION="35"
```

### Corporate Environment

For business use with organizational 1Password:

```bash
SERVER_NAME="INFRASTRUCTURE"
ONEPASSWORD_VAULT="IT Infrastructure"
ONEPASSWORD_TIMEMACHINE_ITEM="Enterprise Backup - Mac Mini"
ONEPASSWORD_APPLEID_ITEM="Apple ID Corporate"
MONITORING_EMAIL="it-alerts@company.com"
```

### Home Lab Integration

For integration with existing home lab infrastructure:

```bash
SERVER_NAME="HOMELAB"
HOSTNAME_OVERRIDE="mac-mini-01"
MONITORING_EMAIL="homelab@yourdomain.local"
```

## Validation and Testing

### Configuration Validation

Before running `prep-airdrop.sh`, verify your 1Password items exist:

```bash
# Test 1Password connectivity
op whoami

# Verify vault exists
op vault get "${ONEPASSWORD_VAULT}"

# Verify Time Machine item exists
op item get "${ONEPASSWORD_TIMEMACHINE_ITEM}" --vault "${ONEPASSWORD_VAULT}"

# Verify Apple ID item exists
op item get "${ONEPASSWORD_APPLEID_ITEM}" --vault "${ONEPASSWORD_VAULT}"
```

### Network Name Testing

Test that your chosen server name resolves properly on your network:

```bash
# After setup, test resolution
ping "${HOSTNAME_LOWER}.local"

# Test SSH connectivity
ssh admin@"${HOSTNAME_LOWER}.local"
```

## Security Considerations

### Credential Storage

The system uses a secure credential management process via macOS Keychain Services. See [Keychain-Based Credential Management](keychain-credential-management.md) for complete implementation details.

**SSH Keys**: Public keys only are transferred; private keys remain on your development Mac.

### Access Control

**SSH Key Sharing**: SSH keys are deployed for secure remote access.

**Apple ID Sharing**: One-time sharing links expire after first use for security.

## Troubleshooting Configuration Issues

### 1Password Authentication

**Item not found errors**:

```bash
# List all items to verify naming
op item list --vault "${ONEPASSWORD_VAULT}"

# Check exact item title
op item get "exact-item-name" --vault "${ONEPASSWORD_VAULT}"
```

**Vault access denied**:

```bash
# Verify vault permissions
op vault list
op vault get "${ONEPASSWORD_VAULT}"
```

### Network Configuration

**Hostname conflicts**: If your chosen SERVER_NAME conflicts with existing network devices, use HOSTNAME_OVERRIDE:

```bash
HOSTNAME_OVERRIDE="unique-hostname"
```

**DNS resolution issues**: Some networks require manual DNS configuration for .local domains.

### File Permission Issues

**Setup directory access**: Ensure setup files have correct permissions:

```bash
# Fix common permission issues
chmod 755 ~/macmini-setup/scripts/*.sh
chmod 600 ~/macmini-setup/config/mac-server-setup-db
chmod 600 ~/macmini-setup/config/wifi_network.conf
```

## Advanced Configuration

### Custom Package Lists

Modify the package installation by editing these files before running `prep-airdrop.sh`:

**config/formulae.txt**: Command-line tools installed via Homebrew
**config/casks.txt**: GUI applications installed via Homebrew

Example customization:

```bash
# Add to config/formulae.txt
htop
ncdu
tree

# Add to config/casks.txt
visual-studio-code
firefox
```

### Environment-Specific Overrides

Create environment-specific configuration files:

```bash
# config-dev.conf
SERVER_NAME="DEVSERVER"
ONEPASSWORD_VAULT="Development"
MONITORING_EMAIL="dev-alerts@company.com"

# config-ci.conf
SERVER_NAME="CISERVER"
ONEPASSWORD_VAULT="CI Infrastructure"
MONITORING_EMAIL="ci-alerts@company.com"
```

Use with prep-airdrop.sh by copying the appropriate config:

```bash
cp config-dev.conf config/config.conf
./prep-airdrop.sh
```

### Integration Hooks

The configuration system supports future extension points:

**MONITORING_EMAIL**: Reserved for future monitoring system integration
**Custom variables**: Add your own variables to config.conf for use in custom scripts

## Migration and Backup

### Configuration Backup

**Version control**: Store your config.conf in a private Git repository
**1Password backup**: Export your server-related 1Password items periodically
**SSH key backup**: Ensure SSH keys are backed up separately from the server

### Server Migration

To migrate configuration to a new Mac Mini:

1. **Update SERVER_NAME** in config.conf if needed
2. **Run prep-airdrop.sh** with updated configuration
3. **Transfer setup package** to new Mac Mini
4. **Run first-boot.sh** as normal

The new server will inherit all configurations and credentials from 1Password.

### Disaster Recovery

**Complete rebuild**: With config.conf and 1Password items intact, you can rebuild the entire server from scratch
**Credential rotation**: Update 1Password items to rotate credentials without changing scripts
**Network reconfiguration**: Modify HOSTNAME_OVERRIDE to change network identity without affecting other settings

This configuration system provides flexibility for various deployment scenarios while maintaining security and automation principles.
