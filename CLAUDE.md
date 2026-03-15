# CLAUDE.md — smb-mount

## Auto-Update Rule

**IMPORTANT:** Any time files are added, removed, renamed, or their purpose changes, update this CLAUDE.md to reflect the current state. This includes new scripts, config files, CLI subcommands, dependencies, or architectural changes. Keep this file as the single source of truth for the project.

## Project Overview

macOS CLI tool (`smb-mount`) that auto-discovers and mounts SMB shares from Windows file servers — including hidden `$` shares — without requiring the Mac to join Active Directory. Uses a LaunchAgent to auto-mount on login and network changes for a native Finder experience.

**Public-ready:** No personal information, server names, IPs, domains, or usernames are hardcoded. All server configuration is done at runtime via `smb-mount server add` or the interactive guided setup during `smb-mount install`.

## Target Environment

- macOS (Darwin 25.x / Sequoia)
- zsh (default shell)
- Credentials stored in macOS Keychain

## Quickstart

```bash
# Install (sets up deps, config, LaunchAgent, guided server setup)
./smb-mount.sh install

# Or add a server manually
smb-mount server add MYSERVER 10.0.0.1 --domain corp.local --user jsmith

# Discover available shares
smb-mount shares MYSERVER

# Mount all shares
smb-mount mount

# Check what's mounted
smb-mount status

# Manage exclusions
smb-mount exclude add Acomba$
smb-mount exclude list

# Open in Finder
open /Volumes/
```

## Architecture

```
smb-mount.sh                                  # Main CLI script (installed to /usr/local/bin/smb-mount)
docs/plans/                                   # Design and planning documents

Runtime config (created by install):
~/.config/smb-mount/
├── servers.conf                              # Server definitions (INI-style)
├── exclusions.conf                           # Shares to skip (IPC$, ADMIN$, C$, etc.)
├── smb-mount.pid                             # Lockfile to prevent concurrent runs
└── smb-mount.log                             # Log file (auto-rotated at 1MB)

Mount points (flat, macOS native):
/Volumes/<sharename>/                         # Native Finder sidebar visibility
```

## CLI Subcommands

```
smb-mount server add <name> <ip> --domain <domain> --user <user>
smb-mount server list
smb-mount server remove <name>
smb-mount mount [<server>]          # mount all or specific server
smb-mount unmount [<server>]        # unmount all or specific server
smb-mount status                    # show mounted shares + server reachability
smb-mount shares <server>           # list discovered shares without mounting
smb-mount install                   # install deps, config, LaunchAgent, guided setup
smb-mount uninstall                 # remove LaunchAgent, symlink, optionally config
smb-mount exclude add <share>       # exclude a share from mounting
smb-mount exclude list              # list excluded shares
smb-mount exclude remove <share>    # re-include a previously excluded share
smb-mount log                       # tail log file
```

## Key Design Decisions

- **smbclient -L** for share discovery — only tool that finds hidden `$` shares
- **osascript mount volume** for mounting — uses Finder's native mount mechanism, no sudo needed, mounts to `/Volumes/<share>` flat
- **smbclient "ls" pre-check** — verifies access before attempting mount, prevents GUI error popups for denied shares
- **INI-style config** — simple, human-editable, no extra parsers needed
- **LaunchAgent** (not cron/systemd) — macOS-native daemon with network change triggers
- **PID lockfile** — prevents concurrent runs during rapid network flaps
- **Interactive vs daemon detection** via `[[ -t 0 ]]` (TTY check)
- **Stale mount cleanup** — auto-unmounts shares that no longer exist on server
- **Interactive guided setup** — `smb-mount install` walks through adding first server
- **Flat mount points** — shares mount at `/Volumes/<share>` (not `/Volumes/<server>/<share>`), same as native Finder SMB mounts

## Credential Flow

1. Keychain lookup via `security find-internet-password` (tries server name, lowercase, IP variants)
2. Pre-check access with `smbclient "ls"` — skips shares where user has no access (exit code 1)
3. Mount via `osascript -e 'mount volume "smb://..."'` with credentials in URL
4. If no password found + interactive: prompt password, offer to save via `security add-internet-password`
5. If no password + daemon: skip, log warning

## Dependencies

- `samba` (brew) — provides `smbclient` for share discovery
- `zsh` — default macOS shell
- No Python, no compiled code, no Node

## Conventions

- Mount points are flat at `/Volumes/<share>` (macOS native SMB behavior)
- Logs go to `~/.config/smb-mount/smb-mount.log`
- Config lives in `~/.config/smb-mount/`
- LaunchAgent plist lives in `~/Library/LaunchAgents/`
- Script symlinked to `/usr/local/bin/smb-mount`

## Testing

- Syntax check: `zsh -n smb-mount.sh`
- Basic smoke tests: `./smb-mount.sh version`, `./smb-mount.sh help`, `./smb-mount.sh status`
- Test discovery with `smb-mount shares <server>` first
- Use `smb-mount status` to verify mounts
- Check `smb-mount log` for daemon behavior after install

## Default Exclusions

IPC$, ADMIN$, C$, D$, print$, NETLOGON, SYSVOL

## zsh Compatibility Notes

- No `local -n` (bash nameref) — use `typeset -gA` for shared associative arrays
- No `grep -oP` (GNU) — use zsh `[[ =~ ]]` with `${match[1]}`
- Regex with `]` in `[[ =~ ]]` must be quoted: `"^\[([^]]+)\]$"`
- `set -o pipefail` only (not `set -euo pipefail`) — many commands intentionally fail
- Keychain stores creds under various keys — always try multiple variants (server name, lowercase, IP)
- `$` in share names: appears as `%24` in mount output URLs, needs `grep -qxF` (not `-qx`) to avoid regex anchor interpretation
- `${var% \(smbfs*}` not `${var%% (*}` — the latter triggers zsh glob interpretation
