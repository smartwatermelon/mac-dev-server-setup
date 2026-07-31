# CLAUDE.md

## ENVIRONMENT VERIFICATION — REQUIRED BEFORE ANY ACTION

**This repo may be checked out on the development Mac OR on a target Mac Mini build server. You MUST verify which machine you are on before running any command.**

```bash
# Run this FIRST every session:
hostname
sw_vers
```

- If hostname is **NOT** a known server name (listed in your `config.conf` as `SERVER_NAME`): you are on the **development Mac**
  - Safe: shellcheck, linting, editing scripts, `prep-airdrop.sh`
  - FORBIDDEN: running setup scripts (`first-boot.sh`, `setup-*.sh`), testing system services
- If hostname **IS** a known server name: you are on the **target build server**
  - Safe: running setup scripts, checking service status, system configuration
  - FORBIDDEN: `prep-airdrop.sh`, 1Password CLI (`op`)

**When in doubt, ask. Running the wrong script on the wrong machine can damage the environment.**

## Overview

Automated setup for Apple Silicon Mac Minis as mobile development build servers. Installs Xcode, Android SDK, Node.js, and developer tooling.

Forked from [mac-server-setup](https://github.com/smartwatermelon/mac-server-setup), stripped of media server components, refocused on developer tooling. See [SPEC.md](SPEC.md) for the full roadmap.

## Dev Commands

```bash
# Lint all shell scripts
shellcheck *.sh setup-*.sh scripts/*.sh

# Verify 1Password connectivity (dev machine only — verify hostname first!)
op vault list      # service account — Automation vault only, non-interactive
opp vault list     # interactive auth — Personal vault access (prep-airdrop.sh requires this)
# `opp` is a local shell function from ~/.config/bash/1password.sh (dotfiles)
# that runs `op` in a subshell with OP_SERVICE_ACCOUNT_TOKEN unset, forcing
# interactive Personal-vault auth. Not a standard macOS/Homebrew tool.
```

### 1Password Credential Flow to Target

The target Mac Mini does NOT store the 1Password service account token in its
Keychain. Instead:

1. Dev machine's ssh wrapper (`~/Developer/scripts/ssh`) reads a
   `# op: OP_SERVICE_ACCOUNT_TOKEN=…` annotation in `~/.ssh/config` and
   resolves it interactively via `op read` before exec'ing real ssh.
2. Wrapper exports the token; ssh forwards it via `SendEnv OP_SERVICE_ACCOUNT_TOKEN`.
3. Target sshd accepts it via `AcceptEnv OP_SERVICE_ACCOUNT_TOKEN` (written to
   `/etc/ssh/sshd_config.d/200-claude-env.conf` by `setup-ssh-access.sh`).
4. `claude-wrapper/lib/credentials.sh` sees the token already in env and skips
   the Keychain lookup.

Consequence: non-ssh sessions on the target (console login, LaunchAgents) do
not get the token. That is intentional — there is no current use case for it.
