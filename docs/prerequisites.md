# Prerequisites - Mac Mini Dev Server Setup

Critical requirements for successful Mac Mini dev server setup

## Development Machine Requirements

### Essential Software

- **1Password CLI**: Install via `brew install 1password-cli`
  - Must be authenticated: `op signin`
  - Requires access to configured vault with server credentials
- **Core command-line tools**: `jq`, `openssl` (pre-installed on macOS)
- **SSH keys**: Must exist at `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`
  - Generate if missing: `ssh-keygen -t ed25519 -C "your_email@example.com"`

### 1Password Vault Configuration

Required 1Password login items in your configured vault:

1. **TimeMachine** (item name configurable via `ONEPASSWORD_TIMEMACHINE_ITEM`)
   - Username: NAS username for Time Machine backups
   - Password: NAS password
   - URL field: NAS hostname or SMB URL

2. **Apple ID** (item name configurable via `ONEPASSWORD_APPLEID_ITEM`)
   - Username: Apple ID email
   - Password: Apple ID password

3. **SSH Keys** (item name configurable via `SSH_KEY_ITEM`)
   - SSH key material for deployment to the server

### Configuration File

- Copy `config/config.conf.template` to `config/config.conf`
- Customize `SERVER_NAME`, `ONEPASSWORD_VAULT`, and other settings
- All 1Password item names are configurable via this file

### Permissions

- Administrator privileges required for:
  - WiFi keychain access during prep-airdrop.sh
  - External keychain creation and management

## Target Mac Mini Requirements

### macOS Setup

- **Fresh macOS installation** (macOS 15.x recommended)
- **Complete Setup Assistant** with administrator account created
- **FileVault disabled** (will be disabled during setup if enabled)

### Critical Session Requirements

- **MUST run from local GUI session** (Terminal.app on the Mac Mini)
- **CANNOT run via SSH** - many operations require GUI access
- Session type must be `Aqua` (verified automatically)

### Hardware/Network

- **Apple Silicon Mac Mini** (Intel may work but untested)
- **Network connectivity** for package downloads
- **Sufficient disk space** for applications and packages

## Pre-Setup Checklist

### On Development Machine

- [ ] 1Password CLI installed and authenticated (`op whoami` succeeds)
- [ ] All required 1Password vault items exist and accessible
- [ ] SSH keys exist at `~/.ssh/id_ed25519*`
- [ ] `config/config.conf` file created and customized
- [ ] Sufficient disk space for deployment package creation

### On Target Mac Mini

- [ ] Fresh macOS installation completed
- [ ] Setup Assistant completed with admin account
- [ ] Connected to network with internet access
- [ ] Logged in to local GUI session (not SSH)
- [ ] FileVault disabled (or willing to disable during setup)

## Validation Commands

Run these commands on your development machine before starting:

```bash
# Verify 1Password CLI authentication
op whoami

# Verify vault access
op vault get "${ONEPASSWORD_VAULT}"

# Check for required 1Password items
op item list --vault "${ONEPASSWORD_VAULT}" | grep -E "TimeMachine|Apple|SSH"

# Verify SSH keys
ls -la ~/.ssh/id_ed25519*

# Check configuration file
test -f config/config.conf && echo "Config file exists" || echo "Create config/config.conf from template"
```

## Troubleshooting Common Issues

### 1Password Authentication

- Ensure you're signed in: `op signin`
- Check vault name in config.conf matches actual vault
- Verify you have access to all required items

### SSH Key Issues

- Generate keys if missing: `ssh-keygen -t ed25519`
- Ensure both public and private keys exist
- Keys will be deployed to the admin account on the server

### FileVault Problems

- first-boot.sh will detect FileVault and offer to disable it
- Can be disabled manually: `sudo fdesetup disable`

### GUI Session Requirements

- first-boot.sh checks session type automatically
- Must be run from Terminal.app on the Mac Mini desktop
- SSH sessions will be rejected with clear error message

## Security Considerations

### Credential Management

- Credentials transferred via encrypted external keychain
- Hardware UUID used as keychain password
- Temporary credential files automatically cleaned up
- All sensitive variables cleared from memory

### Network Security

- SSH keys deployed for secure remote access
- Firewall configured with SSH allowlist
- Password authentication disabled for SSH
- TouchID sudo configured for local administration
