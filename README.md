# Mac Dev Server Setup

Automated setup for an Apple Silicon Mac Mini as a mobile development build server. Xcode, Android SDK, Node.js, dotfiles -- the whole toolchain.

> Forked from [mac-server-setup](https://github.com/smartwatermelon/mac-server-setup), stripped of media server components, refocused on developer tooling. See [SPEC.md](SPEC.md) for full roadmap.

## TL;DR

**What this does**: Takes a fresh Mac Mini and turns it into a development build server with Xcode tooling, Android SDK, Node.js, and your dotfiles.

**Prerequisites** (5 minutes):

1. Install 1Password CLI: `brew install 1password-cli && op signin`
2. Generate SSH keys: `ssh-keygen -t ed25519`
3. Copy `config/config.conf.template` to `config/config.conf` and set your `SERVER_NAME`
4. Create these 1Password items: "TimeMachine", "Apple"

**Setup** (15-30 minutes):

1. **On dev Mac**: `./prep-airdrop.sh` (builds deployment package)
2. **AirDrop** the generated folder to your Mac Mini
3. **On Mac Mini desktop** (not SSH): `cd ~/Downloads/macmini-setup && ./first-boot.sh`
4. **On Mac Mini**: `cd ~/app-setup && ./run-app-setup.sh` (installs dev tools)

**Post-setup** (manual):

1. `claude auth login` (enables cloud-synced MCPs: Sentry, Gmail, Calendar)
2. `gh auth login` (enables `/post-push-loop` CI monitoring)

**Result**: Dev server at `your-server-name.local`, ready for builds.

More detail in [Prerequisites](docs/prerequisites.md) and [Environment Variables](docs/environment-variables.md).

## How it works

Three phases, two machines.

**Phase 1** (`prep-airdrop.sh`, on your dev Mac): Pulls credentials from 1Password, creates a hardware-locked keychain, copies SSH keys and configs, packages it all into a folder.

**Phase 2** (`first-boot.sh`, on the Mac Mini): Validates the hardware fingerprint, imports the keychain, runs 15+ setup modules (SSH, Homebrew, FileVault, Time Machine, etc). Has to be run from the local desktop, not SSH.

**Phase 3** (`run-app-setup.sh`, on the Mac Mini): Discovers and runs
all `*-setup.sh` scripts in dependency order -- Xcode, Node.js,
Android SDK, dotfiles, Claude Code (CLI + plugins + MCPs), and storage.

### Configuration flow

One config file runs the show:

```text
config/config.conf
  ├── prep-airdrop.sh reads it     (Phase 1)
  ├── first-boot.sh sources it     (Phase 2)
  └── run-app-setup.sh sources it  (Phase 3)
```

Key variables: `SERVER_NAME`, `ONEPASSWORD_VAULT`, `DOTFILES_REPO`, `ANDROID_SDK_VERSION`, `NODE_VERSION`.

### Credentials

No plaintext secrets in the deployment package:

```text
1Password (dev Mac)
  -> prep-airdrop.sh retrieves via `op` CLI
  -> Stored in external keychain (password = hardware UUID)
  -> AirDropped as .keychain-db file

first-boot.sh (Mac Mini)
  -> Imports external keychain
  -> Extracts credentials to system/login keychain
  -> Scripts read via `security find-generic-password`
```

1Password is dev-machine only. The server never needs it.

## Current status

All implementation phases are complete. The project is ready to deploy on a fresh Mac Mini.

See [SPEC.md](SPEC.md) for the original roadmap.

## Prerequisites

- Apple Silicon Mac Mini with a fresh macOS install
- Development Mac with:
  - 1Password CLI (`brew install 1password-cli && op signin`)
  - SSH keys (`~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`)
  - 1Password vault items: TimeMachine, Apple ID
  - `jq` and `openssl` (both pre-installed on macOS)
  - `config/config.conf` created from the template

See [Prerequisites Guide](docs/prerequisites.md) for validation commands.

> Tested on macOS 15.x, Apple Silicon only. Might work on Intel or older macOS but I haven't tried.

## Setup

1. **Build the deployment package** on your dev Mac:

   ```bash
   ./prep-airdrop.sh
   ```

   Pulls credentials from 1Password, builds a hardware-locked keychain, processes config, generates a deployment manifest.

2. **AirDrop the folder** to your Mac Mini.

   > [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) lets you do this from the terminal:
   > `brew install --HEAD vldmrkl/formulae/airdrop-cli`

3. **Run first-boot** on the Mac Mini (local desktop session, not SSH):

   ```bash
   cd ~/Downloads/macmini-setup  # default name
   ./first-boot.sh
   ```

   > This needs the local desktop for System Settings dialogs and FileVault management. It will not work over SSH.

4. **Run app-setup** on the Mac Mini (new Terminal window opens automatically after first-boot):

   ```bash
   cd ~/app-setup
   ./run-app-setup.sh
   ```

   This installs Xcode (via App Store), configures Node.js globals, sets up the Android SDK, and clones your dotfiles. Scripts run in dependency order and can be re-run safely.

## File structure

```plaintext
.
├── prep-airdrop.sh                # Entry point: builds deployment package
├── app-setup/                     # Application setup scripts
│   ├── run-app-setup.sh          # Orchestrator (runs scripts in dependency order)
│   ├── xcode-setup.sh            # Xcode via mas, license, simulators
│   ├── node-setup.sh             # npm global config, eas-cli
│   ├── android-setup.sh          # SDK components, licenses, ANDROID_HOME
│   ├── dotfiles-setup.sh         # Clone repo, run install script
│   ├── claude-setup.sh           # CLI, plugins, MCP servers, post-push-loop
│   └── storage-setup.sh          # External storage configuration
├── scripts/
│   └── server/
│       ├── first-boot.sh          # Main provisioning script (15+ modules)
│       ├── setup-apple-id.sh
│       ├── setup-application-preparation.sh
│       ├── setup-auto-updates.sh
│       ├── setup-bash-configuration.sh
│       ├── setup-command-line-tools.sh
│       ├── setup-dock-configuration.sh
│       ├── setup-firewall.sh
│       ├── setup-hostname-volume.sh
│       ├── setup-log-rotation.sh
│       ├── setup-package-installation.sh
│       ├── setup-power-management.sh
│       ├── setup-remote-desktop.sh
│       ├── setup-shell-configuration.sh
│       ├── setup-ssh-access.sh
│       ├── setup-system-preferences.sh
│       ├── setup-terminal-profiles.sh
│       ├── setup-timemachine.sh
│       ├── setup-touchid-sudo.sh
│       └── setup-wifi-network.sh
├── config/
│   ├── config.conf.template      # Configuration template
│   ├── formulae.txt              # Homebrew CLI packages
│   ├── casks.txt                 # Homebrew GUI applications
│   └── logrotate.conf            # Log rotation rules
└── docs/
    ├── prerequisites.md
    ├── environment-variables.md
    ├── configuration.md
    ├── keychain-credential-management.md
    └── setup/
        ├── prep-airdrop.md
        ├── first-boot.md
        ├── firstboot-README.md
        └── apple-first-boot-dialogs.md
```

## Design choices

Every script is idempotent (safe to re-run). Errors display immediately during setup and again in a summary at the end, so nothing gets buried in scroll.

## Security

SSH is key-only (password login disabled). The admin account gets TouchID sudo. Firewall is on with an SSH allowlist. Credentials travel in a hardware-locked keychain, not plaintext. The setup script checks the hardware fingerprint and refuses to run on the wrong machine. The Mac restarts automatically after power failure.

## Error handling

Errors show up immediately during setup and again in a summary at the end:

```bash
====== SETUP SUMMARY ======
Setup completed, but 1 error and 2 warnings occurred:

ERRORS:
  x Installing Homebrew Packages: Formula installation failed: some-package

WARNINGS:
  ! Copying SSH Keys: SSH private key not found at ~/.ssh/id_ed25519
  ! WiFi Network Configuration: Could not detect current WiFi network

Review the full log for details: ~/.local/state/macmini-setup.log
```

Errors block setup. Warnings are optional stuff that wasn't available. Each message tags which setup section it came from.

## Logs

| Script             | Log location                              |
| ------------------ | ----------------------------------------- |
| `prep-airdrop.sh`  | Console output only                       |
| `first-boot.sh`    | `~/.local/state/<hostname>-setup.log`     |
| App setup scripts  | `~/.local/state/<hostname>-app-setup.log` |

## Troubleshooting

**"GUI session required"**: You're running over SSH. `first-boot.sh` needs the local desktop. Check: `launchctl managername` should say `Aqua`, not `Background`.

**SSH access denied**: SSH keys didn't make it into the deployment package, or SSH isn't enabled on the target.

**Homebrew not found**: Restart Terminal or `source ~/.bash_profile`.

**1Password items not found**: Vault name and item titles in `config.conf` have to match exactly.

## Docs

| Topic | Link |
| --- | --- |
| What you need before starting | [Prerequisites](docs/prerequisites.md) |
| Configuration options | [Environment Variables](docs/environment-variables.md) |
| Customizing parameters | [Configuration Reference](docs/configuration.md) |
| Building the deployment package | [Prep-AirDrop](docs/setup/prep-airdrop.md) |
| Running system provisioning | [First Boot](docs/setup/first-boot.md) |
| How credentials move between machines | [Keychain Management](docs/keychain-credential-management.md) |
| Full project roadmap | [SPEC](SPEC.md) |

## Contributing

Scripts must be idempotent (re-runnable without breaking things). Use `log()`/`show_log()` for output. Use `collect_error()` for blockers, `collect_warning()` for optional stuff, `set_section()` so errors have context. Update docs when you change config. `shellcheck` must pass clean, no exceptions.

## License

MIT; see [LICENSE](license.md)
