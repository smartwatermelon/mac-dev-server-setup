# Keychain-Based Credential Management System

## Overview

The Mac Dev Server Setup framework uses macOS Keychain Services for secure credential storage and transfer. The system replaces plaintext credential files with encrypted keychain storage, transferring credentials from development machine to target server through external keychain files.

## Architecture

### Two-Stage Credential Flow

1. **Development Machine (prep-airdrop.sh)** - Retrieves credentials from 1Password and creates external keychain file
2. **Target Server (first-boot.sh)** - Imports credentials from external keychain to admin keychain

## Credential Services

### Required Credentials

- **`timemachine-{SERVER_NAME_LOWER}`**: Time Machine backup credentials (format: `username:password`)

### Optional Credentials

- **`wifi-{SERVER_NAME_LOWER}`**: WiFi password for network setup

## Implementation

### External Keychain Transfer (prep-airdrop.sh)

Creates temporary keychain with random password, stores credentials from 1Password, verifies storage, locks keychain, and copies to output directory with manifest file.

Service identifiers:

- `KEYCHAIN_TIMEMACHINE_SERVICE="timemachine-${SERVER_NAME_LOWER}"`
- `KEYCHAIN_WIFI_SERVICE="wifi-${SERVER_NAME_LOWER}"`

### Credential Import (first-boot.sh)

Single-phase admin import process:

1. **Admin Import** - Transfers credentials from external keychain to admin's keychain

### Application Usage

Uses `get_keychain_credential()` function to retrieve credentials securely during setup.

## Credential Formats

- **NAS Credentials**: `username:password` format, parsed with bash parameter expansion
- **Simple Credentials**: Plain password strings for network auth

## Security Features

- Encrypted keychain storage eliminates plaintext credential files
- Immediate credential verification prevents corrupt transfers
- Memory cleanup after credential use
- Proper file permissions (600) on keychain files and manifests
- Password masking in logs
- External keychain cleanup after import

## Configuration Files

- **keychain_manifest.conf**: Contains service identifiers and keychain metadata
- **External keychain file**: `mac-server-setup-db` transferred with setup package

## Error Handling

- Graceful handling of missing optional credentials
- Verification of credential storage and retrieval
- Comprehensive error collection and reporting

## Benefits

### Security

- Encrypted storage throughout transfer process
- No plaintext credential files in setup packages
- Proper access controls and memory management

### Operations

- Automatic credential storage in admin keychain during setup
- Simple single-function credential retrieval interface for setup scripts
- Error resilience with graceful degradation

### Development

- Consistent credential handling across all scripts
- Integration with Keychain Access.app for debugging

## Troubleshooting

### Admin Keychain Issues

Common diagnostic approaches for setup-time credential issues:

- Verify keychain file existence and permissions
- Test credential retrieval manually with `security` commands
- Check keychain unlock status and access permissions
- Use Keychain Access.app for GUI credential inspection

The system provides comprehensive logging and error collection to identify credential-related issues during setup.
