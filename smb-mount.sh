#!/bin/zsh
set -euo pipefail

# --- Globals ---
readonly VERSION="1.0.0"
readonly CONFIG_DIR="$HOME/.config/smb-mount"
readonly SERVERS_CONF="$CONFIG_DIR/servers.conf"
readonly EXCLUSIONS_CONF="$CONFIG_DIR/exclusions.conf"
readonly LOG_FILE="$CONFIG_DIR/smb-mount.log"
readonly PID_FILE="$CONFIG_DIR/smb-mount.pid"
readonly PLIST_NAME="com.smb-mount"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
readonly INSTALL_PATH="/usr/local/bin/smb-mount"

# --- Logging ---
log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null
    if [[ -t 1 ]]; then
        case "$level" in
            ERROR) echo "\033[31m[ERROR]\033[0m $msg" ;;
            WARN)  echo "\033[33m[WARN]\033[0m $msg" ;;
            OK)    echo "\033[32m[OK]\033[0m $msg" ;;
            *)     echo "[$level] $msg" ;;
        esac
    fi
}

# --- Config helpers ---
ensure_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        log INFO "Created config directory: $CONFIG_DIR"
    fi
}

# Parse servers.conf — populates global PARSED_SERVER associative array
# Usage: parse_server "GOXSRV01"  then read PARSED_SERVER[ip], etc.
typeset -gA PARSED_SERVER
parse_server() {
    local name="$1"
    PARSED_SERVER=()
    local in_section=false

    [[ ! -f "$SERVERS_CONF" ]] && return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header
        if [[ "$line" =~ "^\[([^]]+)\]$" ]]; then
            if [[ "${match[1]}" == "$name" ]]; then
                in_section=true
            else
                $in_section && break
            fi
            continue
        fi

        # Key=value inside our section
        if $in_section && [[ "$line" =~ "^([^=]+)=(.*)$" ]]; then
            local key="${match[1]// /}"
            local val="${match[2]// /}"
            PARSED_SERVER[$key]="$val"
        fi
    done < "$SERVERS_CONF"

    $in_section && return 0 || return 1
}

# List all server names from servers.conf
list_servers() {
    [[ ! -f "$SERVERS_CONF" ]] && return
    while IFS= read -r line; do
        if [[ "$line" =~ "^\[([^]]+)\]$" ]]; then
            echo "${match[1]}"
        fi
    done < "$SERVERS_CONF"
}

# Write a server section to servers.conf
write_server() {
    local name="$1" ip="$2" domain="$3" user="$4"
    ensure_config_dir

    # Remove existing section if present
    remove_server_from_conf "$name"

    # Append new section
    {
        echo ""
        echo "[$name]"
        echo "ip=$ip"
        echo "domain=$domain"
        echo "user=$user"
    } >> "$SERVERS_CONF"
}

# Remove a server section from servers.conf
remove_server_from_conf() {
    local name="$1"
    [[ ! -f "$SERVERS_CONF" ]] && return

    local tmpfile
    tmpfile="$(mktemp)"
    local in_section=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ "^\[([^]]+)\]$" ]]; then
            if [[ "${match[1]}" == "$name" ]]; then
                in_section=true
                continue
            else
                in_section=false
            fi
        fi
        $in_section && continue
        echo "$line"
    done < "$SERVERS_CONF" > "$tmpfile"

    mv "$tmpfile" "$SERVERS_CONF"
}

# --- Exclusions ---
ensure_exclusions() {
    if [[ ! -f "$EXCLUSIONS_CONF" ]]; then
        ensure_config_dir
        cat > "$EXCLUSIONS_CONF" <<'EXCL'
IPC$
ADMIN$
C$
D$
print$
NETLOGON
SYSVOL
EXCL
        log INFO "Created default exclusions: $EXCLUSIONS_CONF"
    fi
}

is_excluded() {
    local share="$1"
    ensure_exclusions
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
        [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
        # Case-insensitive match
        if [[ "${share:l}" == "${pattern:l}" ]]; then
            return 0
        fi
    done < "$EXCLUSIONS_CONF"
    return 1
}

# --- Discovery ---
# Discover shares on a server. Outputs one share name per line (Disk type only, not excluded).
discover_shares() {
    local server_name="$1"
    typeset -gA PARSED_SERVER
    PARSED_SERVER=()

    if ! parse_server "$server_name"; then
        log ERROR "Server not configured: $server_name"
        return 1
    fi

    local ip="${PARSED_SERVER[ip]}"
    local domain="${PARSED_SERVER[domain]}"
    local user="${PARSED_SERVER[user]}"

    # Check reachability
    if ! ping -c1 -W2 "$ip" &>/dev/null; then
        log WARN "Server unreachable: $server_name ($ip)"
        return 1
    fi

    # Run smbclient -L to list shares
    # Try Keychain password first (via security find-internet-password)
    local password=""
    password="$(security find-internet-password -s "$server_name" -a "$user" -w 2>/dev/null)" || true

    local smb_output=""
    if [[ -n "$password" ]]; then
        smb_output="$(smbclient -L "//$ip" -U "$domain/$user%$password" --no-pass 2>/dev/null)" || \
        smb_output="$(smbclient -L "//$ip" -U "$domain/$user" --password="$password" 2>/dev/null)" || true
    fi

    # If no password or smbclient failed, try without (Kerberos/guest)
    if [[ -z "$smb_output" ]]; then
        smb_output="$(smbclient -L "//$ip" -U "$domain/$user" -N 2>/dev/null)" || true
    fi

    # If still empty and interactive, prompt for password
    if [[ -z "$smb_output" ]] && [[ -t 0 ]]; then
        echo -n "Password for $domain\\$user on $server_name: "
        read -rs password
        echo
        smb_output="$(smbclient -L "//$ip" -U "$domain/$user%$password" 2>/dev/null)" || true

        if [[ -n "$smb_output" ]]; then
            echo -n "Save password to Keychain? [Y/n] "
            read -r yn
            if [[ ! "$yn" =~ ^[Nn]$ ]]; then
                security add-internet-password -a "$user" -s "$server_name" -D "SMB" -r "smb " -w "$password" -U 2>/dev/null && \
                    log OK "Password saved to Keychain for $server_name" || \
                    log WARN "Failed to save password to Keychain"
            fi
        fi
    fi

    if [[ -z "$smb_output" ]]; then
        log ERROR "Could not list shares on $server_name — authentication failed"
        return 1
    fi

    # Parse smbclient output: lines like "  ShareName    Disk    Comment here"
    echo "$smb_output" | while IFS= read -r line; do
        # Match lines with share name, type Disk
        if [[ "$line" =~ "^[[:space:]]+([^[:space:]]+)[[:space:]]+Disk" ]]; then
            local share_name="${match[1]}"
            if ! is_excluded "$share_name"; then
                echo "$share_name"
            fi
        fi
    done
}

# --- Lockfile ---
acquire_lock() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log WARN "Another instance is running (PID $old_pid)"
            return 1
        fi
        # Stale lockfile
        rm -f "$PID_FILE"
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT
}

release_lock() {
    rm -f "$PID_FILE"
}

# --- Log rotation ---
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size="$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
        if (( size > 1048576 )); then
            : > "$LOG_FILE"
            log INFO "Log rotated (was ${size} bytes)"
        fi
    fi
}

# --- Mount helpers ---
is_mounted() {
    local mount_point="$1"
    mount | grep -q " on ${mount_point} " 2>/dev/null
}

mount_share() {
    local server_name="$1" share="$2"

    parse_server "$server_name"
    local ip="${PARSED_SERVER[ip]}"
    local domain="${PARSED_SERVER[domain]}"
    local user="${PARSED_SERVER[user]}"
    local mount_point="/Volumes/${server_name}/${share}"

    # Skip if already mounted
    if is_mounted "$mount_point"; then
        log INFO "Already mounted: $mount_point"
        return 0
    fi

    # Create mount point
    if [[ ! -d "$mount_point" ]]; then
        sudo mkdir -p "$mount_point" 2>/dev/null || mkdir -p "$mount_point" 2>/dev/null || {
            log ERROR "Cannot create mount point: $mount_point"
            return 1
        }
    fi

    # Attempt mount — mount_smbfs reads Keychain automatically
    local smb_url="//${domain};${user}@${ip}/${share}"

    if mount_smbfs "$smb_url" "$mount_point" 2>/dev/null; then
        log OK "Mounted: $mount_point"
        return 0
    fi

    # If mount failed and interactive, try with explicit password
    if [[ -t 0 ]]; then
        local password=""
        password="$(security find-internet-password -s "$server_name" -a "$user" -w 2>/dev/null)" || true

        if [[ -z "$password" ]]; then
            echo -n "Password for $domain\\$user on $server_name: "
            read -rs password
            echo

            if mount_smbfs "//${domain};${user}:${password}@${ip}/${share}" "$mount_point" 2>/dev/null; then
                log OK "Mounted: $mount_point"
                # Offer to save
                echo -n "Save password to Keychain? [Y/n] "
                read -r yn
                if [[ ! "$yn" =~ ^[Nn]$ ]]; then
                    security add-internet-password -a "$user" -s "$server_name" -D "SMB" -r "smb " -w "$password" -U 2>/dev/null && \
                        log OK "Password saved to Keychain" || \
                        log WARN "Failed to save to Keychain"
                fi
                return 0
            fi
        else
            if mount_smbfs "//${domain};${user}:${password}@${ip}/${share}" "$mount_point" 2>/dev/null; then
                log OK "Mounted: $mount_point"
                return 0
            fi
        fi
    fi

    log ERROR "Failed to mount: $mount_point"
    # Clean up empty mount point
    rmdir "$mount_point" 2>/dev/null
    return 1
}

unmount_share() {
    local mount_point="$1"

    if ! is_mounted "$mount_point"; then
        # Check if mount is dead/stale
        if [[ -d "$mount_point" ]]; then
            rmdir "$mount_point" 2>/dev/null
        fi
        return 0
    fi

    if umount "$mount_point" 2>/dev/null; then
        log OK "Unmounted: $mount_point"
    else
        # Force unmount dead mount
        umount -f "$mount_point" 2>/dev/null && \
            log WARN "Force unmounted: $mount_point" || \
            log ERROR "Failed to unmount: $mount_point"
    fi

    # Clean up empty directory
    rmdir "$mount_point" 2>/dev/null
}

# Clean up stale mounts — mount points that exist but share no longer discovered
cleanup_stale() {
    local server_name="$1"
    local discovered_shares="$2"
    local server_vol="/Volumes/${server_name}"

    [[ ! -d "$server_vol" ]] && return

    for mount_point in "$server_vol"/*(N); do
        local share_name="${mount_point:t}"
        if ! echo "$discovered_shares" | grep -qx "$share_name"; then
            log WARN "Stale mount detected: $mount_point"
            unmount_share "$mount_point"
        fi
    done
}

# --- Usage ---
usage() {
    cat <<'EOF'
Usage: smb-mount <command> [options]

Commands:
  server add <name> <ip> --domain <domain> --user <user>   Add a server
  server list                                               List configured servers
  server remove <name>                                      Remove a server
  mount [<server>]                                          Mount shares (all or specific)
  unmount [<server>]                                        Unmount shares (all or specific)
  status                                                    Show mount status
  shares <server>                                           List discovered shares
  install                                                   Install deps + LaunchAgent
  uninstall                                                 Remove LaunchAgent + cleanup
  log                                                       Tail the log file
  version                                                   Show version

EOF
    exit "${1:-0}"
}

# --- Main dispatch ---
main() {
    [[ $# -eq 0 ]] && usage 1

    local cmd="$1"; shift

    case "$cmd" in
        server)   cmd_server "$@" ;;
        mount)    cmd_mount "$@" ;;
        unmount)  cmd_unmount "$@" ;;
        status)   cmd_status "$@" ;;
        shares)   cmd_shares "$@" ;;
        install)  cmd_install "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        log)      cmd_log "$@" ;;
        version)  echo "smb-mount v${VERSION}" ;;
        help|-h|--help) usage 0 ;;
        *)        echo "Unknown command: $cmd"; usage 1 ;;
    esac
}

# --- Server subcommands ---
cmd_server() {
    [[ $# -eq 0 ]] && { echo "Usage: smb-mount server <add|list|remove> ..."; return 1; }

    local subcmd="$1"; shift

    case "$subcmd" in
        add)    cmd_server_add "$@" ;;
        list)   cmd_server_list "$@" ;;
        remove) cmd_server_remove "$@" ;;
        *)      echo "Unknown server subcommand: $subcmd"; return 1 ;;
    esac
}

cmd_server_add() {
    local name="" ip="" domain="" user=""

    # Parse positional + flags
    [[ $# -ge 1 ]] && name="$1" && shift
    [[ $# -ge 1 ]] && ip="$1" && shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift 2 ;;
            --user)   user="$2"; shift 2 ;;
            *)        echo "Unknown option: $1"; return 1 ;;
        esac
    done

    # Validate
    if [[ -z "$name" || -z "$ip" || -z "$domain" || -z "$user" ]]; then
        echo "Usage: smb-mount server add <name> <ip> --domain <domain> --user <user>"
        return 1
    fi

    write_server "$name" "$ip" "$domain" "$user"
    log OK "Server added: $name ($ip) — $domain\\$user"
}

cmd_server_list() {
    if [[ ! -f "$SERVERS_CONF" ]] || [[ -z "$(list_servers)" ]]; then
        echo "No servers configured. Add one with: smb-mount server add <name> <ip> --domain <domain> --user <user>"
        return 0
    fi

    local name
    for name in $(list_servers); do
        parse_server "$name"
        printf "  %-20s %-15s %s\\\\%s\n" "$name" "${PARSED_SERVER[ip]}" "${PARSED_SERVER[domain]}" "${PARSED_SERVER[user]}"
    done
}

cmd_server_remove() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: smb-mount server remove <name>"
        return 1
    fi

    if ! parse_server "$name"; then
        echo "Server not found: $name"
        return 1
    fi

    remove_server_from_conf "$name"
    log OK "Server removed: $name"

    # Offer to clean Keychain entry
    if [[ -t 0 ]]; then
        echo -n "Remove Keychain credentials for $name? [y/N] "
        read -r yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            security delete-internet-password -s "$name" 2>/dev/null && \
                log OK "Keychain entry removed for $name" || \
                log WARN "No Keychain entry found for $name"
        fi
    fi
}

# --- Stub subcommands (to be implemented in subsequent tasks) ---
cmd_mount() {
    local target_server="${1:-}"

    ensure_config_dir
    rotate_log
    acquire_lock || return 1

    local servers
    if [[ -n "$target_server" ]]; then
        servers="$target_server"
    else
        servers="$(list_servers)"
    fi

    if [[ -z "$servers" ]]; then
        echo "No servers configured. Add one with: smb-mount server add <name> <ip> --domain <domain> --user <user>"
        release_lock
        return 1
    fi

    local server_name
    for server_name in ${(f)servers}; do
        log INFO "Processing server: $server_name"

        local shares
        shares="$(discover_shares "$server_name" 2>/dev/null)" || continue

        if [[ -z "$shares" ]]; then
            log WARN "No shares found on $server_name"
            continue
        fi

        # Mount each share
        local share
        for share in ${(f)shares}; do
            mount_share "$server_name" "$share"
        done

        # Clean up stale mounts
        cleanup_stale "$server_name" "$shares"
    done

    release_lock
}

cmd_unmount() {
    local target_server="${1:-}"

    local servers
    if [[ -n "$target_server" ]]; then
        servers="$target_server"
    else
        servers="$(list_servers)"
    fi

    if [[ -z "$servers" ]]; then
        echo "No servers configured."
        return 0
    fi

    local server_name
    for server_name in ${(f)servers}; do
        local server_vol="/Volumes/${server_name}"
        [[ ! -d "$server_vol" ]] && continue

        for mount_point in "$server_vol"/*(N); do
            unmount_share "$mount_point"
        done

        # Remove server directory if empty
        rmdir "$server_vol" 2>/dev/null
    done
}
cmd_status() {
    local servers
    servers="$(list_servers)"

    if [[ -z "$servers" ]]; then
        echo "No servers configured."
        return 0
    fi

    local server_name
    for server_name in ${(f)servers}; do
        parse_server "$server_name"

        # Reachability check
        local reachable="unreachable"
        if ping -c1 -W2 "${PARSED_SERVER[ip]}" &>/dev/null; then
            reachable="reachable"
        fi

        local status_color="\033[31m"
        [[ "$reachable" == "reachable" ]] && status_color="\033[32m"
        echo "${status_color}[$reachable]\033[0m $server_name (${PARSED_SERVER[ip]}) — ${PARSED_SERVER[domain]}\\${PARSED_SERVER[user]}"

        # List mounted shares
        local server_vol="/Volumes/${server_name}"
        if [[ -d "$server_vol" ]]; then
            for mount_point in "$server_vol"/*(N); do
                local share_name="${mount_point:t}"
                if is_mounted "$mount_point"; then
                    echo "  \033[32m●\033[0m $share_name"
                else
                    echo "  \033[31m○\033[0m $share_name (not mounted)"
                fi
            done
        else
            echo "  No shares mounted"
        fi
        echo
    done
}
cmd_shares() {
    local server_name="${1:-}"
    if [[ -z "$server_name" ]]; then
        echo "Usage: smb-mount shares <server>"
        return 1
    fi

    if ! parse_server "$server_name"; then
        echo "Server not configured: $server_name"
        echo "Add it with: smb-mount server add $server_name <ip> --domain <domain> --user <user>"
        return 1
    fi

    log INFO "Discovering shares on $server_name (${PARSED_SERVER[ip]})..."
    local shares
    shares="$(discover_shares "$server_name")"

    if [[ -z "$shares" ]]; then
        echo "No accessible shares found on $server_name"
        return 0
    fi

    echo "Shares on $server_name:"
    echo "$shares" | while IFS= read -r share; do
        printf "  %s\n" "$share"
    done
}
cmd_install()   { echo "install: not yet implemented"; }
cmd_uninstall() { echo "uninstall: not yet implemented"; }
cmd_log()       { echo "log: not yet implemented"; }

main "$@"
