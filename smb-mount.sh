#!/bin/zsh
set -o pipefail

# --- Globals ---
readonly VERSION="1.1.0"
readonly CONFIG_DIR="$HOME/.config/smb-mount"
readonly SERVERS_CONF="$CONFIG_DIR/servers.conf"
readonly EXCLUSIONS_CONF="$CONFIG_DIR/exclusions.conf"
readonly LOG_FILE="$CONFIG_DIR/smb-mount.log"
readonly PID_FILE="$CONFIG_DIR/smb-mount.pid"
readonly PLIST_NAME="com.smb-mount"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
readonly INSTALL_PATH="/usr/local/bin/smb-mount"
readonly LAUNCHER_PATH="$CONFIG_DIR/smb-mount-launcher.sh"

# --- Terminal colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# --- Logging ---
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; }

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null
    if [[ -t 1 ]]; then
        case "$level" in
            ERROR) error "$msg" ;;
            WARN)  warn "$msg" ;;
            OK)    info "$msg" ;;
            INFO)  echo -e "${DIM}$msg${NC}" ;;
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
typeset -gA PARSED_SERVER
parse_server() {
    local name="$1"
    PARSED_SERVER=()
    local in_section=false

    [[ ! -f "$SERVERS_CONF" ]] && return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ "^\[([^]]+)\]$" ]]; then
            if [[ "${match[1]}" == "$name" ]]; then
                in_section=true
            else
                $in_section && break
            fi
            continue
        fi

        if $in_section && [[ "$line" =~ "^([^=]+)=(.*)$" ]]; then
            local key="${match[1]// /}"
            local val="${match[2]// /}"
            PARSED_SERVER[$key]="$val"
        fi
    done < "$SERVERS_CONF"

    $in_section && return 0 || return 1
}

list_servers() {
    [[ ! -f "$SERVERS_CONF" ]] && return
    while IFS= read -r line; do
        if [[ "$line" =~ "^\[([^]]+)\]$" ]]; then
            echo "${match[1]}"
        fi
    done < "$SERVERS_CONF"
}

write_server() {
    local name="$1" ip="$2" domain="$3" user="$4"
    ensure_config_dir
    remove_server_from_conf "$name"
    {
        echo ""
        echo "[$name]"
        echo "ip=$ip"
        echo "domain=$domain"
        echo "user=$user"
    } >> "$SERVERS_CONF"
}

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
        if [[ "${share:l}" == "${pattern:l}" ]]; then
            return 0
        fi
    done < "$EXCLUSIONS_CONF"
    return 1
}

# --- Discovery ---
discover_shares() {
    local server_name="$1"
    PARSED_SERVER=()

    if ! parse_server "$server_name"; then
        log ERROR "Server not configured: $server_name"
        return 1
    fi

    local ip="${PARSED_SERVER[ip]}"
    local domain="${PARSED_SERVER[domain]}"
    local user="${PARSED_SERVER[user]}"

    if ! ping -c1 -W2 "$ip" &>/dev/null; then
        log WARN "Server unreachable: $server_name ($ip)"
        return 1
    fi

    local password=""
    local keychain_lookups=("$server_name" "${server_name:l}" "$ip")
    for kc_server in "${keychain_lookups[@]}"; do
        password="$(security find-internet-password -s "$kc_server" -a "$user" -w 2>/dev/null)" || true
        [[ -n "$password" ]] && break
        password="$(security find-internet-password -s "$kc_server" -w 2>/dev/null)" || true
        [[ -n "$password" ]] && break
    done

    local smb_output=""
    if [[ -n "$password" ]]; then
        smb_output="$(smbclient -L "//$ip" -U "$domain/$user%$password" 2>/dev/null)" || true
    fi

    if [[ -z "$smb_output" ]]; then
        smb_output="$(smbclient -L "//$ip" -U "$domain/$user" -N 2>/dev/null)" || true
    fi

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
                    info "Password saved to Keychain for $server_name" || \
                    warn "Failed to save password to Keychain"
            fi
        fi
    fi

    if [[ -z "$smb_output" ]]; then
        log ERROR "Could not list shares on $server_name — authentication failed"
        return 1
    fi

    echo "$smb_output" | while IFS= read -r line; do
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
        rm -f "$PID_FILE"
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT
}

release_lock() {
    rm -f "$PID_FILE"
}

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

is_share_mounted() {
    local server_name="$1" share="$2"
    local server_lower="${server_name:l}"
    local encoded_share="${share//\$/%24}"
    mount | grep -qi "@${server_lower}/${encoded_share} " 2>/dev/null
}

get_mount_point() {
    local server_name="$1" share="$2"
    local server_lower="${server_name:l}"
    local encoded_share="${share//\$/%24}"
    mount | grep -i "@${server_lower}/${encoded_share} " 2>/dev/null | sed 's/.* on //;s/ (smbfs.*//'
}

mount_share() {
    local server_name="$1" share="$2"

    parse_server "$server_name"
    local ip="${PARSED_SERVER[ip]}"
    local domain="${PARSED_SERVER[domain]}"
    local user="${PARSED_SERVER[user]}"

    # Skip if already mounted
    if is_share_mounted "$server_name" "$share"; then
        return 0
    fi

    # Keychain lookup (tries server name, lowercase, IP variants)
    local password=""
    local kc_lookups=("$server_name" "${server_name:l}" "$ip")
    for kc_srv in "${kc_lookups[@]}"; do
        password="$(security find-internet-password -s "$kc_srv" -a "$user" -w 2>/dev/null)" || true
        [[ -n "$password" ]] && break
        password="$(security find-internet-password -s "$kc_srv" -w 2>/dev/null)" || true
        [[ -n "$password" ]] && break
    done

    # Pre-check access with smbclient ls
    if [[ -n "$password" ]]; then
        if ! smbclient "//${ip}/${share}" -U "$domain/$user%$password" -c "ls" &>/dev/null; then
            log INFO "No access to $share on $server_name — skipping"
            return 0
        fi
    fi

    # Mount via osascript (native Finder mount, no sudo)
    local smb_url
    if [[ -n "$password" ]]; then
        smb_url="smb://${domain};${user}:${password}@${server_name}/${share}"
    else
        smb_url="smb://${domain};${user}@${server_name}/${share}"
    fi

    if osascript -e "mount volume \"${smb_url}\"" &>/dev/null; then
        log OK "Mounted: $share from $server_name"
        return 0
    fi

    # Interactive password prompt fallback
    if [[ -t 0 ]] && [[ -z "$password" ]]; then
        echo -n "Password for $domain\\$user on $server_name: "
        read -rs password
        echo

        smb_url="smb://${domain};${user}:${password}@${server_name}/${share}"
        if osascript -e "mount volume \"${smb_url}\"" &>/dev/null; then
            log OK "Mounted: $share from $server_name"
            echo -n "Save password to Keychain? [Y/n] "
            read -r yn
            if [[ ! "$yn" =~ ^[Nn]$ ]]; then
                security add-internet-password -a "$user" -s "${server_name:l}" -D "SMB" -r "smb " -w "$password" -U 2>/dev/null && \
                    info "Password saved to Keychain" || \
                    warn "Failed to save to Keychain"
            fi
            return 0
        fi
    fi

    log ERROR "Failed to mount: $share from $server_name"
    return 1
}

unmount_share() {
    local mount_point="$1"

    if ! mount | grep -q " on ${mount_point} " 2>/dev/null; then
        return 0
    fi

    if umount "$mount_point" 2>/dev/null; then
        info "Unmounted: $mount_point"
    else
        umount -f "$mount_point" 2>/dev/null && \
            warn "Force unmounted: $mount_point" || \
            error "Failed to unmount: $mount_point"
    fi
}

cleanup_stale() {
    local server_name="$1"
    local discovered_shares="$2"
    local server_lower="${server_name:l}"

    mount | grep -i "@${server_lower}/" 2>/dev/null | while IFS= read -r line; do
        local mount_point="${line#* on }"
        mount_point="${mount_point% \(smbfs*}"
        local url_part="${line%% on *}"
        local encoded_share="${url_part##*/}"
        local share_name="${encoded_share//\%24/\$}"

        if ! echo "$discovered_shares" | grep -qxF "$share_name"; then
            warn "Stale mount detected: $mount_point ($share_name)"
            unmount_share "$mount_point"
        fi
    done
}

# --- Usage ---
usage() {
    cat <<USAGE
smb-mount v${VERSION}

Usage:
  smb-mount -help | help
  smb-mount -server | server <add|list|remove> ...
  smb-mount -mount | mount [<server>]
  smb-mount -unmount | unmount [<server>]
  smb-mount -status | status
  smb-mount -shares | shares <server>
  smb-mount -exclude | exclude <add|list|remove> ...
  smb-mount -watch | watch
  smb-mount -install | install
  smb-mount -uninstall | uninstall
  smb-mount -log | log [-f]
  smb-mount -version | version

Server commands:
  smb-mount server add <name> <ip> --domain <domain> --user <user>
  smb-mount server list
  smb-mount server remove <name>

Exclusion commands:
  smb-mount exclude add <share>
  smb-mount exclude list
  smb-mount exclude remove <share>

Examples:
  smb-mount server add FILESERVER01 10.0.0.1 --domain corp.local --user jsmith
  smb-mount mount
  smb-mount shares FILESERVER01
  smb-mount exclude add Acomba\$
  smb-mount status
  smb-mount log -f
USAGE
    exit "${1:-0}"
}

# --- Main dispatch ---
main() {
    [[ $# -eq 0 ]] && usage 1

    local raw_cmd="${1:-help}"
    local cmd="${raw_cmd#-}"

    case "$cmd" in
        install|uninstall|help|h|version|server|log|exclude|watch) ;;
        *)
            if ! command -v smbclient &>/dev/null; then
                error "smbclient not found. Install with 'brew install samba' or run 'smb-mount install'."
                exit 1
            fi
            ;;
    esac

    shift

    case "$cmd" in
        h|help)      usage 0 ;;
        server)      cmd_server "$@" ;;
        mount)       cmd_mount "$@" ;;
        unmount)     cmd_unmount "$@" ;;
        status)      cmd_status "$@" ;;
        shares)      cmd_shares "$@" ;;
        exclude)     cmd_exclude "$@" ;;
        watch)       cmd_watch "$@" ;;
        install)     cmd_install "$@" ;;
        uninstall)   cmd_uninstall "$@" ;;
        log|logs)    cmd_log "$@" ;;
        version)     echo "smb-mount v${VERSION}" ;;
        *)           error "Unknown command: ${raw_cmd}. Use: smb-mount help"; exit 1 ;;
    esac
}

# --- Server subcommands ---
cmd_server() {
    [[ $# -eq 0 ]] && { error "Usage: smb-mount server <add|list|remove> ..."; return 1; }
    local subcmd="$1"; shift
    case "$subcmd" in
        add)    cmd_server_add "$@" ;;
        list)   cmd_server_list "$@" ;;
        remove) cmd_server_remove "$@" ;;
        *)      error "Unknown server subcommand: $subcmd"; return 1 ;;
    esac
}

cmd_server_add() {
    local name="" ip="" domain="" user=""
    [[ $# -ge 1 ]] && name="$1" && shift
    [[ $# -ge 1 ]] && ip="$1" && shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift 2 ;;
            --user)   user="$2"; shift 2 ;;
            *)        error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$name" || -z "$ip" || -z "$domain" || -z "$user" ]]; then
        error "Usage: smb-mount server add <name> <ip> --domain <domain> --user <user>"
        return 1
    fi

    write_server "$name" "$ip" "$domain" "$user"
    info "Server added: $name ($ip) — $domain\\$user"
}

cmd_server_list() {
    if [[ ! -f "$SERVERS_CONF" ]] || [[ -z "$(list_servers)" ]]; then
        echo "No servers configured."
        echo "Add one with: smb-mount server add <name> <ip> --domain <domain> --user <user>"
        return 0
    fi

    printf "%-20s %-15s %s\n" "SERVER" "IP" "CREDENTIALS"
    printf "%-20s %-15s %s\n" "--------------------" "---------------" "------------------------------"

    local name
    for name in $(list_servers); do
        parse_server "$name"
        printf "%-20s %-15s %s\\\\%s\n" "$name" "${PARSED_SERVER[ip]}" "${PARSED_SERVER[domain]}" "${PARSED_SERVER[user]}"
    done
}

cmd_server_remove() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        error "Usage: smb-mount server remove <name>"
        return 1
    fi

    if ! parse_server "$name"; then
        error "Server not found: $name"
        return 1
    fi

    remove_server_from_conf "$name"
    info "Server removed: $name"

    if [[ -t 0 ]]; then
        echo -n "Remove Keychain credentials for $name? [y/N] "
        read -r yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            security delete-internet-password -s "$name" 2>/dev/null && \
                info "Keychain entry removed for $name" || \
                warn "No Keychain entry found for $name"
        fi
    fi
}

# --- Exclude subcommands ---
cmd_exclude() {
    [[ $# -eq 0 ]] && { error "Usage: smb-mount exclude <add|list|remove> ..."; return 1; }
    local subcmd="$1"; shift
    case "$subcmd" in
        add)    cmd_exclude_add "$@" ;;
        list)   cmd_exclude_list "$@" ;;
        remove) cmd_exclude_remove "$@" ;;
        *)      error "Unknown exclude subcommand: $subcmd"; return 1 ;;
    esac
}

cmd_exclude_add() {
    local share="${1:-}"
    if [[ -z "$share" ]]; then
        error "Usage: smb-mount exclude add <share_name>"
        return 1
    fi
    ensure_exclusions
    if is_excluded "$share"; then
        warn "Already excluded: $share"
        return 0
    fi
    echo "$share" >> "$EXCLUSIONS_CONF"
    info "Excluded: $share"
}

cmd_exclude_list() {
    ensure_exclusions
    printf "%-30s\n" "EXCLUDED SHARES"
    printf "%-30s\n" "------------------------------"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        printf "  %s\n" "$line"
    done < "$EXCLUSIONS_CONF"
}

cmd_exclude_remove() {
    local share="${1:-}"
    if [[ -z "$share" ]]; then
        error "Usage: smb-mount exclude remove <share_name>"
        return 1
    fi
    ensure_exclusions
    if ! is_excluded "$share"; then
        warn "Not excluded: $share"
        return 1
    fi
    local tmpfile
    tmpfile="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "${line:l}" != "${share:l}" ]]; then
            echo "$line"
        fi
    done < "$EXCLUSIONS_CONF" > "$tmpfile"
    mv "$tmpfile" "$EXCLUSIONS_CONF"
    info "Unexcluded: $share"
}

# --- Core subcommands ---
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
        error "No servers configured. Add one with: smb-mount server add <name> <ip> --domain <domain> --user <user>"
        release_lock
        return 1
    fi

    local server_name shares share
    for server_name in ${(f)servers}; do
        # Skip if server already has mounts
        local server_lower="${server_name:l}"
        if mount | grep -qi "@${server_lower}/" 2>/dev/null; then
            log INFO "Shares already mounted for $server_name — skipping"
            continue
        fi

        log INFO "Processing server: $server_name"

        shares="$(discover_shares "$server_name" 2>/dev/null)" || continue

        if [[ -z "$shares" ]]; then
            log WARN "No shares found on $server_name"
            continue
        fi

        for share in ${(f)shares}; do
            mount_share "$server_name" "$share"
        done

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
        local server_lower="${server_name:l}"
        mount | grep -i "@${server_lower}/" 2>/dev/null | while IFS= read -r line; do
            local mp="${line#* on }"
            mp="${mp% \(smbfs*}"
            [[ -n "$mp" ]] && unmount_share "$mp"
        done
    done
}

cmd_status() {
    local servers
    servers="$(list_servers)"

    if [[ -z "$servers" ]]; then
        echo "No servers configured."
        return 0
    fi

    echo "smb-mount v${VERSION}"
    echo ""

    local server_name
    for server_name in ${(f)servers}; do
        parse_server "$server_name"
        local server_lower="${server_name:l}"

        local reachable="unreachable"
        if ping -c1 -W2 "${PARSED_SERVER[ip]}" &>/dev/null; then
            reachable="reachable"
        fi

        local status_color="${RED}"
        [[ "$reachable" == "reachable" ]] && status_color="${GREEN}"
        echo -e "${status_color}[$reachable]${NC} $server_name (${PARSED_SERVER[ip]}) — ${PARSED_SERVER[domain]}\\${PARSED_SERVER[user]}"

        if mount | grep -qi "@${server_lower}/" 2>/dev/null; then
            mount | grep -i "@${server_lower}/" 2>/dev/null | while IFS= read -r line; do
                local mp="${line#* on }"
                mp="${mp% \(smbfs*}"
                local sn="${mp:t}"
                echo -e "  ${GREEN}●${NC} $sn → $mp"
            done
        else
            echo -e "  ${DIM}No shares mounted${NC}"
        fi
        echo
    done
}

cmd_shares() {
    local server_name="${1:-}"
    if [[ -z "$server_name" ]]; then
        error "Usage: smb-mount shares <server>"
        return 1
    fi

    if ! parse_server "$server_name"; then
        error "Server not configured: $server_name"
        echo "Add it with: smb-mount server add $server_name <ip> --domain <domain> --user <user>"
        return 1
    fi

    echo -e "${DIM}Discovering shares on $server_name (${PARSED_SERVER[ip]})...${NC}"
    local shares
    shares="$(discover_shares "$server_name")"

    if [[ -z "$shares" ]]; then
        warn "No accessible shares found on $server_name"
        return 0
    fi

    printf "\n%-30s %s\n" "SHARE" "STATUS"
    printf "%-30s %s\n" "------------------------------" "----------"

    echo "$shares" | while IFS= read -r share; do
        if is_share_mounted "$server_name" "$share"; then
            printf "  %-28s ${GREEN}mounted${NC}\n" "$share"
        else
            printf "  %-28s ${DIM}available${NC}\n" "$share"
        fi
    done
}

cmd_install() {
    echo "smb-mount v${VERSION} installer"
    echo ""

    # 1. Check/install Homebrew
    if ! command -v brew &>/dev/null; then
        echo "Homebrew not found. Installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f "/usr/local/bin/brew" ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        if command -v brew &>/dev/null; then
            info "Homebrew installed"
        else
            error "Homebrew installation failed. Install manually: https://brew.sh"
            return 1
        fi
    else
        info "Homebrew found: $(brew --prefix)"
    fi

    # 2. Check/install smbclient
    if ! command -v smbclient &>/dev/null; then
        echo "smbclient not found. Installing samba via Homebrew..."
        brew install samba
        if command -v smbclient &>/dev/null; then
            info "smbclient installed"
        else
            error "samba installation failed"
            return 1
        fi
    else
        info "smbclient found: $(which smbclient)"
    fi

    # 3. Create config directory with defaults
    ensure_config_dir
    ensure_exclusions
    info "Config directory: $CONFIG_DIR"

    # 4. Symlink script — resolve real path
    local script_path
    script_path="${0:A}"

    if [[ -L "$INSTALL_PATH" ]] && [[ "$(readlink "$INSTALL_PATH")" == "$script_path" ]]; then
        info "Already installed at $INSTALL_PATH"
    else
        echo "Installing to $INSTALL_PATH..."
        if [[ $EUID -eq 0 ]]; then
            ln -sf "$script_path" "$INSTALL_PATH"
        else
            sudo ln -sf "$script_path" "$INSTALL_PATH"
        fi
        info "Symlinked $INSTALL_PATH → $script_path"
    fi

    # 5. Generate launcher script (avoids launchd issues with spaces in paths)
    cat > "$LAUNCHER_PATH" <<LAUNCHER
#!/bin/zsh
exec /bin/zsh "${script_path}" "\$@"
LAUNCHER
    chmod +x "$LAUNCHER_PATH"
    info "Launcher: $LAUNCHER_PATH"

    # 6. Generate LaunchAgent plist
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LAUNCHER_PATH}</string>
        <string>watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

    # 7. Load the agent (must run as user, not root)
    if [[ $EUID -eq 0 ]]; then
        warn "LaunchAgent must be loaded as your user, not root."
        echo "Run this after install:  launchctl load $PLIST_PATH"
    else
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        launchctl load "$PLIST_PATH"
        info "LaunchAgent loaded: $PLIST_NAME"
    fi

    echo ""

    # 8. Interactive guided server setup
    if [[ -z "$(list_servers)" ]]; then
        echo "No servers configured yet. Let's set one up now."
        echo
        _guided_server_add
    else
        echo "Configured servers:"
        cmd_server_list
        echo
        echo "Run 'smb-mount mount' to connect now, or it will auto-connect on next network change."
    fi
}

_guided_server_add() {
    local name="" ip="" domain="" user=""
    local add_another=true

    while $add_another; do
        echo "--- Add a server ---"
        echo

        echo -n "Server name (e.g. FILESERVER01): "
        read -r name
        [[ -z "$name" ]] && { warn "Server name is required."; continue; }

        echo -n "Server IP or hostname (e.g. 10.0.0.1): "
        read -r ip
        [[ -z "$ip" ]] && { warn "IP/hostname is required."; continue; }

        echo -n "Domain (e.g. corp.local): "
        read -r domain
        [[ -z "$domain" ]] && { warn "Domain is required."; continue; }

        echo -n "Username (e.g. jsmith): "
        read -r user
        [[ -z "$user" ]] && { warn "Username is required."; continue; }

        echo
        write_server "$name" "$ip" "$domain" "$user"
        info "Server added: $name ($ip) — $domain\\$user"

        echo
        echo -e "${DIM}Verifying connection and discovering shares...${NC}"
        local shares
        shares="$(discover_shares "$name" 2>/dev/null)" || true

        if [[ -n "$shares" ]]; then
            echo
            echo "Shares found on $name:"
            echo "$shares" | while IFS= read -r share; do
                printf "  %s\n" "$share"
            done

            echo
            echo -n "Mount these shares now? [Y/n] "
            read -r yn
            if [[ ! "$yn" =~ ^[Nn]$ ]]; then
                local share
                for share in ${(f)shares}; do
                    mount_share "$name" "$share"
                done
                echo
                echo "Opening Finder..."
                open "/Volumes/" 2>/dev/null || true
            fi
        else
            echo
            warn "No shares discovered. Check credentials and server reachability."
            echo "You can test later with: smb-mount shares $name"
        fi

        echo
        echo -n "Add another server? [y/N] "
        read -r yn
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            add_another=false
        fi
        echo
    done
}

cmd_uninstall() {
    echo "smb-mount v${VERSION} uninstaller"
    echo ""

    if [[ -f "$PLIST_PATH" ]]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        info "LaunchAgent removed"
    else
        warn "No LaunchAgent found"
    fi

    if [[ -L "$INSTALL_PATH" || -f "$INSTALL_PATH" ]]; then
        if [[ $EUID -eq 0 ]]; then
            rm -f "$INSTALL_PATH"
        else
            sudo rm -f "$INSTALL_PATH"
        fi
        info "Removed $INSTALL_PATH"
    fi

    if [[ -t 0 ]]; then
        echo -n "Remove config directory ($CONFIG_DIR)? [y/N] "
        read -r yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            rm -rf "$CONFIG_DIR"
            info "Config removed"
        fi

        echo -n "Unmount all shares? [y/N] "
        read -r yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            cmd_unmount
            info "All shares unmounted"
        fi
    fi

    echo ""
    info "Uninstall complete"
}

# --- Network watcher daemon ---
cmd_watch() {
    ensure_config_dir
    log INFO "Network watcher started"

    local prev_ifaces=""
    prev_ifaces="$(scutil --nwi 2>/dev/null | grep '^  ' | sort)"

    _watch_check() {
        local curr_ifaces
        curr_ifaces="$(scutil --nwi 2>/dev/null | grep '^  ' | sort)"

        [[ "$curr_ifaces" == "$prev_ifaces" ]] && return

        log INFO "Network change detected"
        prev_ifaces="$curr_ifaces"

        local servers
        servers="$(list_servers)"
        [[ -z "$servers" ]] && return

        local server_name
        for server_name in ${(f)servers}; do
            parse_server "$server_name"
            local ip="${PARSED_SERVER[ip]}"
            local server_lower="${server_name:l}"

            if ping -c1 -W2 "$ip" &>/dev/null; then
                if ! mount | grep -qi "@${server_lower}/" 2>/dev/null; then
                    log INFO "Server $server_name now reachable — mounting"
                    cmd_mount "$server_name"
                fi
            else
                if mount | grep -qi "@${server_lower}/" 2>/dev/null; then
                    log INFO "Server $server_name unreachable — unmounting"
                    cmd_unmount "$server_name"
                fi
            fi
        done
    }

    # Run initial check
    _watch_check

    # Poll every 5 seconds
    while true; do
        sleep 5
        _watch_check
    done
}

cmd_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        warn "No log file yet. Run 'smb-mount mount' first."
        return 0
    fi

    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
        tail -f "$LOG_FILE"
    else
        tail -50 "$LOG_FILE"
    fi
}

main "$@"
