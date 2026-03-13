# CLAUDE.md — smb-mount

## Auto-Update Rule

**IMPORTANT:** Any time files are added, removed, renamed, or their purpose changes, update this CLAUDE.md to reflect the current state. This includes new scripts, config files, CLI subcommands, dependencies, or architectural changes. Keep this file as the single source of truth for the project.

## Project Overview

macOS CLI tool (`smb-mount`) that auto-discovers and mounts SMB shares from Windows file servers — including hidden `$` shares — without requiring the Mac to join Active Directory. Uses a LaunchAgent to auto-mount on login and network changes for a native Finder experience.

## Target Environment

- macOS (Darwin 25.x / Sequoia)
- zsh (default shell)
- Primary server: GOXSRV01 (10.88.3.1), domain: gox.ca, user: jcproulx
- Credentials stored in macOS Keychain

## Architecture

```
smb-mount.sh                                  # Main CLI script (installed to /usr/local/bin/smb-mount)
com.smb-mount.plist                           # LaunchAgent template
docs/plans/                                   # Design and planning documents

Runtime config (created by install):
~/.config/smb-mount/
├── servers.conf                              # Server definitions (INI-style)
├── exclusions.conf                           # Shares to skip (IPC$, ADMIN$, C$, etc.)
├── smb-mount.pid                             # Lockfile to prevent concurrent runs
└── smb-mount.log                             # Log file (auto-rotated at 1MB)

Mount points:
/Volumes/<server>/<sharename>/                # Native Finder sidebar visibility
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
smb-mount install                   # install deps, config, LaunchAgent
smb-mount uninstall                 # remove LaunchAgent, symlink, optionally config
smb-mount log                       # tail log file
```

## Key Design Decisions

- **smbclient -L** for share discovery — only tool that finds hidden `$` shares
- **mount_smbfs** for mounting — macOS native, auto-reads Keychain
- **INI-style config** — simple, human-editable, no extra parsers needed
- **LaunchAgent** (not cron/systemd) — macOS-native daemon with network change triggers
- **PID lockfile** — prevents concurrent runs during rapid network flaps
- **Interactive vs daemon detection** via `[[ -t 0 ]]` (TTY check)
- **Stale mount cleanup** — auto-unmounts shares that no longer exist on server

## Credential Flow

1. `mount_smbfs` tries Keychain automatically
2. If fails + interactive: prompt password, offer to save via `security add-internet-password`
3. If fails + daemon: skip, log warning

## Dependencies

- `samba` (brew) — provides `smbclient` for share discovery
- `zsh` — default macOS shell
- No Python, no compiled code, no Node

## Conventions

- All paths use `/Volumes/<server>/<share>` pattern
- Logs go to `~/.config/smb-mount/smb-mount.log`
- Config lives in `~/.config/smb-mount/`
- LaunchAgent plist lives in `~/Library/LaunchAgents/`
- Script symlinked to `/usr/local/bin/smb-mount`

## Testing

- Test with `smb-mount shares GOXSRV01` first (discovery without mounting)
- Use `smb-mount status` to verify mounts
- Check `smb-mount log` for daemon behavior after install

## Default Exclusions

IPC$, ADMIN$, C$, D$, print$, NETLOGON, SYSVOL
