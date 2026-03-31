# mac-dev-server-setup

> Automated setup framework for configuring an Apple Silicon Mac Mini as a mobile development build server.

Forked from [mac-server-setup](https://github.com/smartwatermelon/mac-server-setup), stripped of media server components, refocused on developer tooling.

## Goals

1. **Single-command provisioning**: Fresh macOS to fully configured dev environment
2. **Reproducibility**: Nuke and pave without manual configuration
3. **Headless-first**: Primary interaction via SSH; GUI available via Synergy/HDMI when needed
4. **Dotfiles integration**: Pull in existing bash configuration from separate repo
5. **Build server role**: Offload Xcode/Gradle builds from MacBook Air

## Target Configuration

| Component | Specification |
| --- | --- |
| Hardware | M4 Mac Mini, 16GB unified memory, 512GB SSD |
| macOS | 15.x (Sequoia) or later |
| Primary user | `andrewrich` (existing Apple Account, created during macOS setup) |
| Access methods | SSH (primary), Synergy, HDMI/KVM (secondary) |

## Architecture Decisions

### Removed from Original

| Component | Rationale |
| --- | --- |
| `operator` user | Unnecessary for single-user dev server |
| Automatic login | Not needed; machine stays logged in |
| Plex, Transmission, rclone | Media server functionality not required |
| SMB mounting infrastructure | No NAS dependencies |
| LaunchAgent app orchestration | No long-running media services |
| Per-user mount system | No shared storage requirements |

### Retained from Original

| Component | Rationale |
| --- | --- |
| `prep-airdrop.sh` pattern | Proven deployment workflow |
| 1Password CLI integration | Secure credential retrieval |
| Hardware fingerprint validation | Prevents wrong-machine execution |
| Error collection system | Excellent debugging UX |
| SSH key deployment | Required for Git operations |
| Homebrew installation | Package management foundation |
| System hardening | Firewall, power failure recovery |
| Logging infrastructure | Troubleshooting support |

### Added/Modified

| Component | Description |
| --- | --- |
| Xcode CLI tools + full Xcode | iOS/macOS build capability |
| Android SDK + command-line tools | Android build capability |
| Node.js (via nvm or Homebrew) | React Native/Expo toolchain |
| Watchman | Metro bundler file watching |
| CocoaPods | iOS dependency management |
| Java (Azul Zulu or Temurin) | Android/Gradle requirement |
| Dotfiles sync | Clone and link bash configuration repo |
| Claude Code CLI | AI-assisted development |
| Claude Code MCP servers | Context7 (docs), headroom (compression) globally; project-specific MCPs per-repo |
| Post-push loop | CI monitoring via `/post-push-loop` — cross-repo: script in `claude-config`, hook in `dotfiles`, deps in `formulae.txt` |
| GitHub CLI + SSH keys | Repository access (also required for post-push-loop `gh api` calls) |

## User Model Change

**Original**: Creates new `operator` user on fresh macOS install, configures automatic login.

**New**: Assumes `andrewrich` user already exists (created during macOS Setup Assistant with Apple Account). Script configures existing user rather than creating one.

This simplifies the flow:

- No user creation
- No password generation/storage
- No automatic login configuration
- Apple Account already linked (iCloud, App Store access)

## File Structure (Post-Fork)

```text
.
├── README.md                    # Updated for dev server purpose
├── SPEC.md                      # This document
├── prep-airdrop.sh              # Modified: remove media prep, add dev prep
├── app-setup/                   # Renamed purpose: dev tool setup
│   ├── xcode-setup.sh           # NEW: Xcode installation and configuration
│   ├── android-setup.sh         # NEW: Android SDK and emulator setup
│   ├── node-setup.sh            # NEW: Node.js, npm, and related tools
│   ├── dotfiles-setup.sh        # NEW: Clone and link dotfiles repo
│   └── run-app-setup.sh         # Modified: orchestrate dev tools
├── scripts/
│   ├── airdrop/
│   │   └── (gutted - no rclone/media prep)
│   └── server/
│       ├── first-boot.sh        # Modified: configure existing user
│       └── (remove operator-first-login.sh)
├── config/
│   ├── config.conf.template     # Modified: dev-focused variables
│   ├── formulae.txt             # Modified: dev tools
│   └── casks.txt                # Modified: dev applications
└── docs/
    └── (updated documentation)
```

## Configuration Variables

### Retained

```bash
SERVER_NAME="macmini"              # Hostname
ONEPASSWORD_VAULT="personal"       # 1Password vault name
SSH_KEY_ITEM="SSH Keys"            # 1Password item for SSH keys
```

### Removed

```bash
OPERATOR_USERNAME                  # No operator user
ONEPASSWORD_OPERATOR_ITEM          # No operator credentials
ONEPASSWORD_TIMEMACHINE_ITEM       # No Time Machine config
PLEX_*                             # No Plex
TRANSMISSION_*                     # No Transmission
RCLONE_*                           # No rclone
NAS_*                              # No NAS mounting
```

### Added

```bash
DOTFILES_REPO="git@github.com:smartwatermelon/dotfiles.git"
ANDROID_SDK_VERSION="34"           # Target Android SDK
NODE_VERSION="lts"                 # Node.js version (or "20", "22", etc.)
XCODE_VERSION=""                   # Empty = latest from App Store
```

## Homebrew Packages

### formulae.txt

```text
# Core development
git
gh
watchman
cocoapods
fastlane

# Build tools
cmake
ninja

# Shell environment
bash
bash-completion@2
shellcheck
shfmt

# Utilities
jq
yq
tree
ripgrep
fd
bat
eza

# Node.js ecosystem
node
yarn
pnpm

# Java (for Android/Gradle)
temurin

# Python (for various tooling)
python@3.12
pipx
```

### casks.txt

```text
android-studio
android-commandlinetools
iterm2
1password-cli
```

Note: Xcode installed via App Store or mas CLI, not Homebrew cask.

## Implementation Phases

### Phase 1: Fork and Gut

1. Fork repository to `mac-dev-server-setup`
2. Delete `app-setup/` contents (keep directory)
3. Delete `scripts/airdrop/rclone-airdrop-prep.sh`
4. Delete `scripts/server/operator-first-login.sh`
5. Remove operator user creation from `first-boot.sh`
6. Update `config.conf.template` (remove media vars)
7. Replace `formulae.txt` and `casks.txt`

### Phase 2: Core Modifications

1. Modify `first-boot.sh` to configure existing user
2. Modify `prep-airdrop.sh` to remove media prep steps
3. Update SSH key deployment for existing user
4. Test basic provisioning flow

### Phase 3: Dev Tool Setup Scripts

1. Create `app-setup/xcode-setup.sh`
   - Install Xcode CLI tools
   - Accept license
   - Install iOS simulators (selective)
2. Create `app-setup/android-setup.sh`
   - Install SDK via sdkmanager
   - Configure ANDROID_HOME
   - Install target platforms and build-tools
   - Create AVD (optional)
3. Create `app-setup/node-setup.sh`
   - Install Node.js
   - Configure npm global directory
   - Install global packages (expo-cli, eas-cli)
4. Create `app-setup/dotfiles-setup.sh`
   - Clone dotfiles repo
   - Create symlinks
   - Source configuration
5. Create `app-setup/claude-setup.sh`
   - Install Claude Code CLI
   - Clone claude-config repo (`~/.claude`)
   - Register plugin marketplaces (superpowers, claude-code-workflows,
     smartwatermelon, claude-code-plugins, claude-plugins-official)
   - Install plugins (superpowers, ci-workflows, code-critic, etc.)
   - Setup MCP servers (Context7, headroom)
   - Verify GitHub CLI authentication
   - Verify post-push-loop readiness
6. Create `app-setup/storage-setup.sh`
   - Configure external storage volume
   - Set up Time Machine (optional)

### Phase 4: Integration and Testing

1. Update `run-app-setup.sh` to orchestrate new scripts
2. End-to-end test on fresh macOS install
3. Document any manual steps that could not be automated
4. Update README.md

## Known Constraints

### Xcode Installation

Full Xcode must be installed via:

- App Store (requires Apple ID sign-in)
- `mas` CLI tool (can automate App Store installs)
- Direct .xip download from developer.apple.com (requires auth)

Recommend `mas` approach for automation:

```bash
mas install 497799835  # Xcode
```

### First-Boot GUI Requirement

Like the original, `first-boot.sh` requires a local GUI session for:

- System Settings automation (if any)
- Potential Xcode license acceptance dialogs
- Any macOS permission prompts

SSH-only execution is not supported for initial setup.

### Xcode License

```bash
sudo xcodebuild -license accept
```

Must run after Xcode installation, requires sudo.

### Android SDK Licenses

```bash
yes | sdkmanager --licenses
```

Can be automated.

## Post-Setup Validation

Script should verify:

- [ ] SSH access works with deployed keys
- [ ] `git` configured with correct identity
- [ ] `xcodebuild -version` succeeds
- [ ] `xcrun simctl list` shows available simulators
- [ ] `$ANDROID_HOME` set and SDK accessible
- [ ] `adb --version` succeeds
- [ ] `node --version` returns expected version
- [ ] `npm --version` succeeds
- [ ] Dotfiles linked and shell configured
- [ ] Homebrew doctor passes
- [ ] `claude mcp list` shows context7 and headroom connected
- [ ] `claude plugins marketplace list` shows all 5 marketplaces
- [ ] `claude plugins list` shows installed plugins
  (superpowers, ci-workflows, code-critic, etc.)
- [ ] `claude auth login` completed
  (enables cloud-synced MCPs: Sentry, Gmail, Calendar, etc.)
- [ ] `gh auth status` succeeds
  (required for `/post-push-loop` CI monitoring)
- [ ] `~/.claude/scripts/post-push-status.sh` exists and is executable
- [ ] `~/.config/git/hooks/pre-push` contains `POSTPUSH_LOOP` support

## Open Questions

1. **Simulator management**: Install all iOS simulators, or selective? (Storage consideration)
2. **Android emulator images**: Pre-create AVDs, or on-demand?
3. **Xcode installation method**: `mas`, manual App Store, or .xip download?
4. **Time Machine**: Configure backup to NAS, or skip entirely?
5. **FileVault**: Enable disk encryption, or skip for build server?

## References

- Original project: <https://github.com/smartwatermelon/mac-server-setup>
- Dotfiles repo: <https://github.com/smartwatermelon/dotfiles> (assumed)
- Bash config: Project files in current conversation context
