# smb-mount — macOS SMB Share Auto-Discovery & Mounting Tool

**Date:** 2026-03-13
**Status:** Approved

## Problem

Mac users not joined to the business Active Directory lose access to network shares that Windows domain-joined machines get automatically via logon scripts. Manually creating aliases for each share is tedious and breaks when admins add/remove shares.

## Solution

A zsh CLI tool (`smb-mount`) that discovers all available SMB shares (including hidden `$` shares) on configured servers, mounts them under `/Volumes/<server>/`, and keeps them synced via a macOS LaunchAgent. The result is a native Finder experience where shares appear in the sidebar under Locations.

## Architecture

```
smb-mount.sh                              # Main CLI script
com.smb-mount.plist                       # LaunchAgent for auto-mount
install.sh                                # Bundled into `smb-mount install`
~/.config/smb-mount/
├── servers.conf                          # Server definitions (INI-style)
├── exclusions.conf                       # Shares to skip
├── smb-mount.pid                         # Lockfile
└── smb-mount.log                         # Log file
```

## CLI Interface

```
smb-mount server add <name> <ip> --domain <domain> --user <user>
smb-mount server list
smb-mount server remove <name>
smb-mount mount [<server>]
smb-mount unmount [<server>]
smb-mount status
smb-mount shares <server>
smb-mount install
smb-mount uninstall
smb-mount log
```

## Flow

1. Read `servers.conf` for configured servers
2. Check reachability (`ping -c1 -W2`)
3. Discover shares via `smbclient -L //SERVER -U domain/user`
4. Filter out system shares (exclusions.conf) and non-Disk types
5. For each share:
   - Skip if already mounted
   - Create `/Volumes/<server>/<share>` mount point
   - Mount via `mount_smbfs //domain;user@server/share /Volumes/server/share`
   - On auth failure: prompt interactively or skip in daemon mode
6. Clean up stale mounts (removed shares, dead mounts)
7. Log everything

## Credential Handling

- Primary: macOS Keychain (mount_smbfs checks automatically)
- Fallback (interactive): `read -s` password prompt, offer to save via `security add-internet-password`
- Daemon mode: skip auth failures, log warning
- Detection: `[[ -t 0 ]]` to distinguish interactive vs daemon

## Share Discovery & Filtering

- `smbclient -L` enumerates all shares including hidden `$` ones
- Default exclusions: IPC$, ADMIN$, C$, D$, print$, NETLOGON, SYSVOL
- Only mount shares of type "Disk"
- User-editable exclusions.conf

## LaunchAgent

- Plist: `~/Library/LaunchAgents/com.smb-mount.plist`
- `RunAtLoad: true`
- `WatchPaths: ["/Library/Preferences/SystemConfiguration"]` (network changes)
- `ThrottleInterval: 30`
- Calls `smb-mount mount` in non-interactive mode

## Install / Uninstall

**install:**
1. `brew install samba` if missing
2. Create `~/.config/smb-mount/` with defaults
3. Symlink script to `/usr/local/bin/smb-mount`
4. Generate + load LaunchAgent
5. Prompt to add first server if none configured

**uninstall:**
1. Unload + remove LaunchAgent
2. Remove symlink
3. Optionally remove config and unmount all

## Error Handling

- **Unreachable server:** ping check, skip + log
- **Already mounted:** detect via `mount | grep`, skip
- **Permission denied:** log, continue to next share
- **Network flap:** ThrottleInterval 30s prevents rapid re-runs
- **Dead mounts:** force unmount with `umount -f`
- **Concurrent runs:** PID lockfile
- **Missing smbclient:** helpful error message pointing to `smb-mount install`
- **Log rotation:** truncate if > 1MB

## Config Examples

**servers.conf:**
```ini
[GOXSRV01]
ip=10.88.3.1
domain=gox.ca
user=jcproulx
```

**exclusions.conf:**
```
IPC$
ADMIN$
C$
D$
print$
NETLOGON
SYSVOL
```

## Dependencies

- macOS (tested on Sequoia / Darwin 25.x)
- samba (`brew install samba`) for `smbclient`
- zsh (default macOS shell)

## Mount Points

```
/Volumes/GOXSRV01/
├── ShareA/
├── ShareB/
├── Apps$/
└── Data$/
```

Appears natively in Finder sidebar under Locations.
