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

# --- Stub subcommands (to be implemented in subsequent tasks) ---
cmd_server()    { echo "server: not yet implemented"; }
cmd_mount()     { echo "mount: not yet implemented"; }
cmd_unmount()   { echo "unmount: not yet implemented"; }
cmd_status()    { echo "status: not yet implemented"; }
cmd_shares()    { echo "shares: not yet implemented"; }
cmd_install()   { echo "install: not yet implemented"; }
cmd_uninstall() { echo "uninstall: not yet implemented"; }
cmd_log()       { echo "log: not yet implemented"; }

main "$@"
