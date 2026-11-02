# Power, Screen Lock, and Remote Wake

The build server must never sleep, but its attached console must not stay
unlocked forever. This page records the intended settings, why each one is
set, and how to get the machine back from each "unresponsive" state without
walking to its keyboard.

Audited on MIMOLETTE (Mac16,10, macOS 27.2) on 2026-11-02.

## Intended settings

| Setting | Value | Where | Why |
| --- | --- | --- | --- |
| System sleep | `sleep 0` | `pmset` | The server must answer SSH and builds at all times. |
| Disk sleep | `disksleep 0` | `pmset` | External build volumes stay spun up. |
| Display sleep | `displaysleep 180` (3 hours) | System Settings → Lock Screen | Lets the monitor rest. Synergy's `preventSleep=true` holds a display-sleep assertion, so the display may not sleep while Synergy runs. See [Known drift](#known-drift). |
| Standby | `standby 0` | `pmset` | No deep sleep. |
| Wake on network | `womp 1` | `pmset` | Harmless; nothing sleeps, so it is a fallback only. |
| Restart after power failure | `autorestart 1` | `pmset` | Comes back after a power cut. |
| Restart after freeze | On | `systemsetup -getrestartfreeze` | Comes back after a hang. |
| Screen saver starts | 20 minutes idle | System Settings → Lock Screen | Locks the console on idle. It comes well before display sleep, and the system never sleeps. |
| Require password | Immediately | System Settings → Lock Screen | Without it, the lock arrives 15 minutes after the screen saver starts. |
| FileVault | On | `fdesetup status` | Disk encryption. The cost is the pre-boot unlock below. |
| Remote Login (SSH) | On | System Settings → Sharing | Needed for normal access and for the FileVault unlock over SSH. |
| Screen Sharing | On | System Settings → Sharing | A remote way to reach the lock screen, since Synergy cannot type there. |
| Automatic macOS updates | On | System Settings → General → Software Update | Kept on by choice. Each update restart needs the FileVault unlock over SSH. |

Check the live values:

```bash
pmset -g custom
defaults -currentHost read com.apple.screensaver idleTime
sysadminctl -screenLock status
fdesetup status
```

## The two "unresponsive" states

The machine does not sleep. When it looks dead, it is in one of these states.

### 1. Screen locked, display dark

Pressing Escape on the lock screen turns the display off (seen in the power
log on 2026-10-30). SSH and all services keep running.

Synergy cannot help here. macOS turns on secure input at the lock screen, and
Synergy logs `application "loginwindow" is blocking the keyboard`. The mouse
moves, but keystrokes for the password do not arrive.

To recover remotely:

1. Turn the display on: `ssh <server> caffeinate -u -t 5`
2. Unlock with Touch ID on the attached keyboard, or with Screen Sharing
   (`open vnc://<server>`). Screen Sharing at the lock screen is not yet
   tested on MIMOLETTE.

### 2. FileVault pre-boot screen after a restart

After any restart that is not an `authrestart` (macOS update, power cut,
freeze, manual restart), the data volume is locked. Until someone
authenticates, there is no shell, no Synergy, and no Screen Sharing.

macOS 26 and later accept a password over SSH in this state and use it to
unlock the data volume (see `man apple_ssh_and_filevault`). This works even
though normal SSH is key-only: the SSH config lives on the locked data volume,
so the pre-boot SSH uses its built-in password authentication.

1. From another machine: `ssh <admin-user>@<server-ethernet-ip>`
2. Enter the FileVault user's password.
3. The connection drops while macOS mounts the data volume and starts its
   services. Wait a moment and connect again as usual.

Tested and working on MIMOLETTE.

Requirements:

- Apple silicon.
- Remote Login turned on *before* the restart.
- The account is a FileVault user (`sudo fdesetup list`).
- Prefer the wired Ethernet address. Reports differ on whether Wi-Fi works at
  pre-boot.

### Planned restarts

Use `sudo fdesetup authrestart` instead of `sudo shutdown -r now`. It unlocks
the next boot one time, so the pre-boot screen does not appear.

## Known drift

These differences between `scripts/server/` and the audited server are not yet
resolved:

- **Display sleep.** `setup-power-management.sh` sets `displaysleep 60`.
  MIMOLETTE uses `180`.
- **Password delay.** `setup-system-preferences.sh` writes
  `askForPasswordDelay 0` with `defaults`. Before the audit, that key read
  `0` on MIMOLETTE, but `sysadminctl -screenLock status` reported
  `900 seconds`. The `defaults` write did not set the actual delay. Setting
  it in System Settings did. `sysadminctl -screenLock immediate -password -`
  should also work.
- **Screen saver idle time.** No script sets it. Before the audit it was `0`
  (never), so the console never locked on idle.
