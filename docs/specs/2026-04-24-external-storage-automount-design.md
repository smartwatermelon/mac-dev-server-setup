# Boot-Time Automount for External Development Storage

**Status:** Design approved, awaiting implementation plan
**Author:** Andrew Rich
**Date:** 2026-04-24
**Target machine:** MIMOLETTE (Apple Silicon Mac Mini, macOS 26.4.1)

## Problem Statement

The development environment on MIMOLETTE — dotfiles, claude-config,
claude-wrapper, and project repos — lives on an external Thunderbolt SSD
mounted at `/Volumes/extra-vieille`. The SSD auto-mounts on macOS desktop GUI
login but does **not** mount at boot. As a result, after a reboot the box is
SSH-reachable but the dev environment is inaccessible until a GUI login
happens.

This is painful because the Mini is headless-ish and FileVault prevents using
"Automatically log in as..." (auto-login is disabled by FileVault on
AppleID-backed accounts). `fdesetup authrestart` works for deliberate,
CLI-triggered reboots (pre-auths FileVault and restores the desktop session),
but unplanned reboots — kernel panics, power events past UPS runtime — still
strand the box at the loginwindow with the SSD unmounted.

## Goals

- **Primary:** `/Volumes/extra-vieille` is mounted automatically at boot,
  before a human SSH-es in, without requiring a GUI login.
- **Robust:** the solution survives cable re-seats, reboots, and the full
  range of disk-enumeration races.
- **Loud on failure:** if the SSD is absent or fails to mount, the operator
  cannot SSH in without being visibly alerted.
- **Unbrickable:** no change to fstab; no change that can prevent boot or
  break sshd. The worst case is "SSD not mounted, I can fix it via SSH."
- **Deployable:** lives in this repo, installed via a new setup script, part
  of future clean-installs on other targets.

## Non-Goals

- Not relocating the dev environment off the SSD. Symlink layout
  (`~/Developer → SSD`, various `~/.claude/*` and `~/.config/*` chains
  through the SSD) stays unchanged.
- Not encrypting the SSD. The SSD is currently unencrypted APFS; this spec
  does not touch that.
- Not gating sshd on the mount. sshd may accept connections during the short
  boot-time mount window; the loud-fail banner handles the persistent-failure
  case.
- Not emailing failure notifications (msmtp exists in this repo's formulae
  but root-owned msmtp config is not set up; deferred).
- Not handling the FileVault preboot screen on unscheduled reboots. That
  remains a "need someone at the keyboard or remote KVM" situation, out of
  scope here.

## Context

### Discovered state

- `/Volumes/extra-vieille` is APFS, 2 TB container, volume UUID
  `0AE8C5DE-4380-4942-AE72-D8784B57CA8E`. **Not** FileVault-encrypted. **Not**
  APFS-encrypted.
- Boot volume (`/System/Volumes/Data`) has FileVault enabled — unchanged by
  this spec.
- `/etc/fstab` does not exist. The only third-party LaunchDaemon present is
  Backblaze's.
- The SSD lives in a UGreen dock permanently wired to the Mini via dual
  Thunderbolt. Physical absence is a failure condition, not an expected
  state.
- Repo already has `app-setup/storage-setup.sh`, which assumes the SSD is
  pre-mounted and creates symlinks into it. This spec provides the
  prerequisite — a mount that's up before any of that logic runs.

### Why the mount doesn't fire at boot today

macOS defers mounting non-internal disks to user-session `diskarbitrationd`
logic. For an unencrypted external APFS volume, the disk is visible in
IORegistry early in boot, but the mount operation does not happen until
DiskArbitration gets a user-space request — typically when loginwindow
completes and Finder starts. sshd, which comes up earlier, sees an unmounted
`/Volumes/extra-vieille`.

The fix is to force the mount during boot, before user-space login.

## Architecture

One root-owned LaunchDaemon, one helper script it invokes, one new setup
script in this repo that installs both plus a small runtime config file and
a login-banner snippet.

```
/Library/LaunchDaemons/
  com.mac-dev-server.automount-external-storage.plist   (root:wheel 0644)

/Library/Application Support/mac-dev-server/
  mount-external-storage.sh                             (root:wheel 0755)
  automount.conf                                        (root:wheel 0644)

/etc/profile.d/ (or equivalent — confirmed during implementation)
  mac-dev-server-mount-check.sh                         (root:wheel 0644)

<repo>/app-setup/
  setup-external-automount.sh                           (new)

<repo>/app-setup/templates/
  com.mac-dev-server.automount-external-storage.plist.template  (new)
  mount-external-storage.sh.template                            (new)
  mac-dev-server-mount-check.sh.template                        (new)

<repo>/config/config.conf.template
  EXTERNAL_STORAGE_VOLUME=""     (existing)
  EXTERNAL_STORAGE_UUID=""       (new; auto-discovered)
```

The plist uses both `RunAtLoad=true` and `LaunchEvents →
com.apple.iokit.matching` keyed on the volume UUID. Helper script is a short
bash file that runs `diskutil mount`, checks the result, logs, and on failure
triggers the loud-failure path. No daemons stay resident.

The label `com.mac-dev-server.automount-external-storage` is namespaced to
this project so the same infrastructure can extend to additional external
volumes later if needed (out of scope for this spec).

### Why `/Library/Application Support/mac-dev-server/` and not `/usr/local/sbin`

`/usr/local/sbin` is the classical Unix location, but on Apple Silicon macOS
it collides with x86_64 Homebrew conventions and is off-pattern for a
project-owned helper. `/Library/Application Support/<vendor>/` is the
canonical location for non-user app support files on macOS — Backblaze
(already present in `/Library/LaunchDaemons/`) uses `/Library/Backblaze.bzpkg/`
analogously. Cleanup is a single `rm -rf`.

## Components

### 1. LaunchDaemon plist

Root-owned, loaded by launchd at boot.

- `Label`: `com.mac-dev-server.automount-external-storage`
- `ProgramArguments`: `[/Library/Application Support/mac-dev-server/mount-external-storage.sh]`
- `RunAtLoad`: `true` — fires once at boot unconditionally
- `LaunchEvents → com.apple.iokit.matching`: watches IORegistry for the APFS
  volume UUID. Fires again any time the disk appears (post-reboot, cable
  re-seat).
- `StandardOutPath` / `StandardErrorPath`: `/var/log/mount-external-storage.log`
- No `KeepAlive`. No `StartInterval`. Event-driven only.

Example matching dict:

```xml
<key>LaunchEvents</key>
<dict>
  <key>com.apple.iokit.matching</key>
  <dict>
    <key>com.mac-dev-server.external-storage-appeared</key>
    <dict>
      <key>IOProviderClass</key>
      <string>AppleAPFSVolume</string>
      <key>UUID</key>
      <string>0AE8C5DE-4380-4942-AE72-D8784B57CA8E</string>
    </dict>
  </dict>
</dict>
```

Matching is on **APFS volume UUID**, never on BSD name (`disk7s1`). BSD names
are reassigned by DiskArbitration each boot and drift as other USB/Thunderbolt
devices are added or removed.

### 2. Helper script — `mount-external-storage.sh`

~50 lines of bash. Responsibilities:

1. Source `/Library/Application Support/mac-dev-server/automount.conf` to
   read `EXTERNAL_STORAGE_UUID` and `EXTERNAL_STORAGE_VOLUME`.
2. Check whether already mounted (`diskutil info "$UUID" | grep 'Mounted: *Yes'`).
   If so, log and exit 0 — idempotent. RunAtLoad and IOKit-match will overlap
   during normal boot and this is how we handle it.
3. Wait-loop up to 10 seconds for the UUID to appear in `diskutil list`.
   Guards against IOKit match events that arrive before the APFS container is
   fully parsed.
4. Run `diskutil mount "$UUID"`.
5. Post-mount verification: assert `/Volumes/$EXTERNAL_STORAGE_VOLUME` exists
   and is a mount point.
6. On any failure path, invoke an inline `loud_fail` function defined within
   the same script (see Error Handling for the three layers it writes to).
7. Every step logs with a timestamp to `/var/log/mount-external-storage.log`.

### 3. Setup script — `app-setup/setup-external-automount.sh`

New script, runs on the target as part of setup (or idempotently later).
Responsibilities:

1. Verify we are on the target (hostname matches `SERVER_NAME` from config).
   Abort loudly on dev machine.
2. Verify SSD is currently mounted (setup cannot discover UUID otherwise).
3. Discover UUID via `diskutil info -plist "$EXTERNAL_STORAGE_VOLUME" | plutil -extract VolumeUUID raw -`.
4. Render plist template, helper script template, and banner snippet template
   by substituting `EXTERNAL_STORAGE_UUID` and `EXTERNAL_STORAGE_VOLUME`.
5. `plutil -lint` the rendered plist. `shellcheck -S info` and `bash -n` the
   rendered script. Abort on any lint failure.
6. `sudo` install the files with correct owner (`root:wheel`) and mode.
7. Write `automount.conf` with the discovered UUID and volume label.
8. `sudo launchctl bootstrap system <plist>` to load without reboot.
9. `launchctl list | grep <label>` to verify loaded.
10. Print a "run phase-5 reboot test to verify boot behavior" hint.

Flags:

- `--dry-run`: render templates, run all lints, print the diff of intended
  changes, touch nothing under `/Library/` or `/etc/`.
- `--install-only`: install files but skip the `launchctl bootstrap` step.
  Used in Phase 2 of the test plan.
- `--uninstall`: `launchctl bootout`, remove all installed files, clear
  runtime flag file.

Rollback on partial failure: if `launchctl bootstrap` fails, the script
removes the plist from `/Library/LaunchDaemons/` before exiting so a future
reboot does not try to load a known-broken daemon.

### 4. Runtime config — `automount.conf`

Short key=value file at `/Library/Application Support/mac-dev-server/automount.conf`:

```
EXTERNAL_STORAGE_VOLUME=extra-vieille
EXTERNAL_STORAGE_UUID=0AE8C5DE-4380-4942-AE72-D8784B57CA8E
```

Separate from the big `config/config.conf` because (a) it needs to be
readable by root-owned launchd at boot without sourcing the full project
config, and (b) its values are machine-specific post-setup facts, not
setup-time preferences.

### 5. Login-banner snippet

Installed at the OS-appropriate path (`/etc/bashrc.d/`, `/etc/profile.d/`, or
equivalent — confirmed in implementation). Fires for every interactive login:

```bash
if [[ -f /var/run/mount-external-storage.FAILED ]]; then
  printf '\033[1;31m⚠️  EXTERNAL STORAGE MOUNT FAILED AT BOOT\033[0m\n'
  printf '   Reason: %s\n' "$(cat /var/run/mount-external-storage.FAILED)"
  printf '   Log:    /var/log/mount-external-storage.log\n\n'
fi
```

Non-blocking; silent when no failure flag present.

### 6. Integration with `run-app-setup.sh`

Add `setup-external-automount.sh` to the ordered script list, immediately
after `storage-setup.sh`. Both require the SSD mounted; `storage-setup.sh`
creates the symlinks that `automount` preserves across reboot.

### 7. Config template additions

`config/config.conf.template` gains one line:

```
EXTERNAL_STORAGE_UUID=""     # auto-discovered by setup-external-automount.sh
```

## Data Flow

### Boot, happy path (SSD present)

```
kernel → launchd → (parallel):
  ├─ sshd loads
  ├─ diskarbitrationd enumerates APFS containers
  │    └─ APFS volume UUID <...> registered as AppleAPFSVolume
  │         └─ IOKit match event fires (keyed on UUID)
  │              └─ launchd runs mount-external-storage.sh
  │                   ├─ diskutil info <UUID> confirms discoverable
  │                   ├─ diskutil mount <UUID> → /Volumes/extra-vieille
  │                   └─ log: "mounted OK"
  └─ RunAtLoad fires → script runs idempotently, sees mount, exits 0
```

### Boot, SSD missing

```
kernel → launchd →
  ├─ sshd loads
  └─ RunAtLoad fires → mount-external-storage.sh
       ├─ wait-loop: UUID not in diskutil list after 10s
       └─ loud failure: syslog + flag file + log
(IOKit match event never fires — disk never enumerates)
```

### Cable re-seat mid-uptime

```
diskarbitrationd sees disk → IOKit match fires → script runs → mounts, logs.
```

### Race: sshd vs. mount

sshd may accept connections during the short window between its start and
mount completion. A shell that logs in during that window will see broken
symlinks chaining through `~/Developer`. This is not prevented. The window is
~1–5 seconds; the banner covers the persistent-failure case.

### Ordering: RunAtLoad vs. IOKit-match

Both may fire at boot in either order. The script's idempotency
(check-mounted-first) handles the overlap. No launchd-level ordering needed.

## Error Handling and Loud Failure

Three independent layers. A bug in any one layer cannot swallow the alert.

### Layer 1 — unified log + syslog

On any failure:

```bash
logger -p daemon.crit -t mac-dev-server-automount "MOUNT FAILED: <reason>"
```

Visible in `log show` and `Console.app`. Survives reboot.

### Layer 2 — flag file in `/var/run`

Helper writes `/var/run/mount-external-storage.FAILED` containing timestamp,
reason, and UUID on failure. Removes it on success. `/var/run` is tmpfs on
macOS, so the file — if present — always reflects the *current* boot. No
stale alerts.

### Layer 3 — login banner

Snippet (Component #5) checks for the flag file on every interactive login
and prints a red banner. Impossible to miss when SSH-ing in.

### What we do not do

- No `osascript` user notifications — unreliable from a root LaunchDaemon.
- No email — msmtp is new and root-owned config isn't set up. Deferred.
- No sshd-ordering gates. Short window is acceptable.

### Helper-script failure modes

| Failure | Detection | Exit code |
|---|---|---|
| Config file missing/unreadable | `[[ -r automount.conf ]]` | 4 |
| UUID not discoverable after 10s wait | `diskutil info <UUID>` non-zero | 1 |
| `diskutil mount` returns non-zero | check `$?` | 2 |
| Mount succeeded but `/Volumes/<label>` missing | stat post-check | 3 |
| Already mounted on entry | `diskutil info` shows `Mounted: Yes` | 0 (idempotent) |

Distinct exit codes so `launchctl list` identifies which branch fired.

### Setup-time safety

Before any install action that touches `/Library/` or `/etc/`:

1. `plutil -lint` on rendered plist.
2. `shellcheck -S info` on rendered script.
3. `bash -n` on rendered script.
4. Abort on any lint failure.

If `launchctl bootstrap` fails, setup script removes the plist from
`/Library/LaunchDaemons/` before exit. A future reboot will not try to load a
known-broken daemon.

`--dry-run` flag renders everything and shows intended changes without
writing outside `/tmp/`.

### Un-brickability analysis

Worst case is "SSD doesn't mount, I don't know why." Not "machine doesn't
boot." This spec never touches fstab. A broken plist is isolated — launchd
logs it and moves on; sshd is unaffected. A broken helper script exits
non-zero; same result. Internal disk always boots, sshd always comes up, the
user always has a remote-editable path to fix whatever's wrong.

## Testing Plan

Seven phases, each reversible before committing to the next. No phase
proceeds until the previous one's acceptance checks pass.

### Phase 0 — Static validation (dev machine)

No target touched.

- `shellcheck -S info` on all shell scripts and templates
- `bash -n` on rendered templates
- `plutil -lint` on rendered plist
- Render templates with test values; diff against fixtures

**Acceptance:** all lints clean, rendered output matches fixtures.

### Phase 1 — Dry-run install on target

Reversible: nothing written under `/Library/` or `/etc/`.

- `sudo ./setup-external-automount.sh --dry-run`
- Verify printed plan shows exact `sudo cp` / `sudo chmod` / `sudo launchctl
  bootstrap` commands with rendered content
- Verify UUID auto-discovered from mounted SSD

**Acceptance:** plan matches expectations, `/Library/` untouched, `launchctl
list` unchanged.

### Phase 2 — Real install, daemon not yet loaded

Reversible: `rm` the installed files.

- `sudo ./setup-external-automount.sh --install-only`
- Verify files present with correct owner/mode
- `plutil -lint` passes on installed plist
- `bash -n` passes on installed script
- Re-run setup; assert idempotent no-op

**Acceptance:** files correct, nothing loaded; machine boots normally if
rebooted now.

### Phase 3 — Load daemon, happy-path runtime test

Reversible: `launchctl bootout`.

- `sudo launchctl bootstrap system /Library/LaunchDaemons/<plist>`
- `sudo launchctl list | grep automount-external-storage` — verify loaded,
  last exit status shown
- Run helper script manually with SSD mounted → expect exit 0, log says
  "already mounted"
- `sudo diskutil unmount /Volumes/extra-vieille`
- Re-run helper script manually → expect exit 0, log says "mounted OK"
- Verify `/Volumes/extra-vieille` present

**Acceptance:** script idempotent and correctly mounts from unmounted state.

### Phase 4 — Loud-fail validation (no reboot)

Reversible: restore config.

- Back up `automount.conf`
- Set `EXTERNAL_STORAGE_UUID=00000000-0000-0000-0000-000000000000`
- Run helper script manually → expect non-zero exit, UUID-not-discoverable
  branch
- Verify `/var/run/mount-external-storage.FAILED` exists with sane reason
- Verify `logger` entry visible in `log show --last 5m`
- Open a new SSH session → verify login banner fires
- Restore config, re-run helper → flag file removed, new SSH session has no
  banner

**Acceptance:** all three loud-fail layers fire and clear correctly.

### Phase 5 — Reboot test with preauth

First time we trust boot-time firing. Reversible: `launchctl bootout` via
SSH if it fails.

- `sudo fdesetup authrestart`
- Poll `ssh MIMOLETTE.local true` from dev machine until reachable
- Verify `/Volumes/extra-vieille` is mounted
- Verify `/var/log/mount-external-storage.log` shows RunAtLoad and/or
  IOKit-match entries (both idempotent)
- Verify `/var/run/mount-external-storage.FAILED` absent

**Acceptance:** mount complete within seconds of sshd being reachable.

### Phase 6 — Simulated missing-SSD reboot

Fully software; no physical unplug needed.

- Edit `automount.conf` to use valid-looking but nonexistent UUID
- `sudo fdesetup authrestart`
- SSH in → verify banner appears, flag file present, SSH otherwise functional
- Restore config, reboot once more → verify clean state

**Acceptance:** boot succeeds with "missing" disk, loud-fail fires
end-to-end, remote recovery possible.

### Phase 7 — Uninstall / rollback

- `sudo ./setup-external-automount.sh --uninstall`: `launchctl bootout`,
  `rm` plist, `rm` helper + config dir, `rm` banner snippet
- Verify all traces gone
- Reboot → verify machine boots normally with SSD mounted via the old
  GUI-login path (back to original behavior, not worse)

**Acceptance:** clean uninstall path works; machine returns to pre-spec
state.

### Safety property of the test plan

Every phase before Phase 5 is reversible without reboot. Phase 5 is the
first one where we trust the daemon to do anything at boot, and by then
every individual piece has been validated. If Phase 5 fails, sshd is still
up (unaffected by our plist) and `sudo launchctl bootout` disables the
daemon remotely.

## Open Questions

- **Correct path for login-banner snippet.** `/etc/bashrc.d/` vs
  `/etc/profile.d/` vs `/etc/profile` append vs `/etc/zshenv` — confirm
  during implementation. The snippet must fire for interactive SSH logins
  under the user's actual login shell (bash, per project standards) without
  affecting non-interactive shells.
- **Should the uninstall path also roll back `storage-setup.sh` symlinks?**
  Probably not — symlinks are harmless when target is absent. Confirm.

## Follow-Ups (Out of Scope)

- Email-on-failure via msmtp once root-owned msmtp config is in place.
- Robust shell RC that waits briefly for the mount before sourcing
  SSD-dependent dotfiles, closing the sshd-vs-mount race entirely.
- Extending the framework to additional external volumes (generic
  per-volume LaunchDaemon generation). YAGNI for now.
- Phase 3 hybrid from the brainstorming session: relocate critical
  shell/config off the SSD so SSH works in a degraded mode when the SSD
  actually fails. Deferred until we see whether the loud-fail model is
  sufficient in practice.
