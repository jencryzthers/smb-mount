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
cmd_mount()     { echo "mount: not yet implemented"; }
cmd_unmount()   { echo "unmount: not yet implemented"; }
cmd_status()    { echo "status: not yet implemented"; }
cmd_shares()    { echo "shares: not yet implemented"; }
cmd_install()   { echo "install: not yet implemented"; }
cmd_uninstall() { echo "uninstall: not yet implemented"; }
cmd_log()       { echo "log: not yet implemented"; }

main "$@"
