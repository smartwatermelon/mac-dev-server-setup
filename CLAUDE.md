# CLAUDE.md

## ENVIRONMENT VERIFICATION — REQUIRED BEFORE ANY ACTION

**This repo may be checked out on the development Mac OR on a target Mac Mini build server. You MUST verify which machine you are on before running any command.**

```bash
# Run this FIRST every session:
hostname
sw_vers
```

- If hostname is **NOT** a known server name (TILSIT, MIMOLETTE): you are on the **development Mac**
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
op vault list
```
