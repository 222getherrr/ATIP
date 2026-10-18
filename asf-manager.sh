#!/usr/bin/env bash
# =============================================================================
#  ASF Manager - self-contained TUI manager for ArchiSteamFarm
#
#  Features:
#    * Start/Stop ArchiSteamFarm (dynamic menu text based on runtime state)
#    * Runtime management (download/remove/re-download, on-demand auto-install)
#    * Live log (ASF output, "Press ESC to exit live log" pinned to bottom)
#    * Project update check against the GitHub release version file
#    * Multi-account management (simple TUI + raw JSON editing)
#    * Farm mode switch: auto card farming vs play-only (specific APPIDs)
#      - play-only mode bypasses the badge page by injecting the "play" command
#        through ASF console input (equivalent to typing !play)
#
#  Layout:
#    $ASF_HOME/
#      asf/            ASF generic package (extracted)
#      runtime/        .NET runtime managed by this tool
#      asf-manager.sh  this file
#      manager.conf    mirror / repo / version settings
#      mode.conf       play-only mode settings (bot=appids per line)
#      asf.pid         running ASF pid
#      asf.log         captured ASF output when started from TUI
#      asf-input       FIFO used to inject console commands into ASF
#
#  Project policy: English comments and English user-facing text only.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
#  Environment / configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASF_HOME="${ASF_HOME:-$SCRIPT_DIR}"

if [[ -f "$ASF_HOME/manager.conf" ]]; then
    # shellcheck disable=SC1091
    source "$ASF_HOME/manager.conf"
fi
MIRROR="${MIRROR:-https://ghfast.top/}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/222getherrr/ATIP/main}"
DOTNET_INSTALL_URL="${DOTNET_INSTALL_URL:-https://dot.net/v1/dotnet-install.sh}"

ASF_DIR="$ASF_HOME/asf"
RUNTIME_DIR="$ASF_HOME/runtime"
DOTNET="$RUNTIME_DIR/dotnet"
CONFIG_DIR="$ASF_DIR/config"
FIFO="$ASF_HOME/asf-input"
PID_FILE="$ASF_HOME/asf.pid"
LOG_FILE="$ASF_HOME/asf.log"
MODE_CONF="$ASF_HOME/mode.conf"
MANAGER_VERSION_FILE="$ASF_HOME/version.txt"

# -----------------------------------------------------------------------------
#  Small helpers
# -----------------------------------------------------------------------------
msg()   { printf '\033[1;36m[ASF]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[ASF]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[ASF]\033[0m WARNING: %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[ASF]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

github_download() { # full_github_url dest
    curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "${MIRROR}$1" || return 1
}

require_tput() {
    command -v tput >/dev/null 2>&1 || die "tput (ncurses) is required for the TUI"
}

pause_msg() {
    printf '\033[1;36m[ASF]\033[0m Press Enter to continue...'
    read -r
}

confirm_yn() { # prompt -> returns 0 if yes
    local ans
    printf '\033[1;33m[ASF]\033[0m %s (y/N): ' "$1"
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# -----------------------------------------------------------------------------
#  ASF runtime version discovery (source of truth: runtimeconfig.json)
# -----------------------------------------------------------------------------
required_channel() {
    local cfg="$ASF_DIR/ArchiSteamFarm.runtimeconfig.json"
    [[ -f "$cfg" ]] || return 1
    local ch=""
    if command -v python3 >/dev/null 2>&1; then
        ch=$(python3 - "$cfg" 2>/dev/null <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for fr in data['runtimeOptions']['frameworks']:
        if fr['name'] == 'Microsoft.AspNetCore.App':
            print('.'.join(fr['version'].split('.')[:2]))
            break
except Exception:
    pass
PY
        )
    fi
    if [[ -n "$ch" ]]; then
        echo "$ch"
    else
        # Fallback: the JSON is formatted multi-line, so name and version are on
        # separate lines; grab the version line right after the matching name.
        grep -A1 '"name": "Microsoft.AspNetCore.App"' "$cfg" \
            | sed -n 's/.*"version": "\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' | head -1
    fi
}

installed_runtime_version() {
    [[ -x "$DOTNET" ]] || return 1
    "$DOTNET" --version 2>/dev/null || true
}

# -----------------------------------------------------------------------------
#  Runtime management
# -----------------------------------------------------------------------------
install_runtime() {
    local channel
    channel=$(required_channel) || die "Cannot read runtimeconfig.json; ASF package missing?"
    msg "Downloading .NET Runtime $channel (ASP.NET Core) into $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
    local script="$ASF_HOME/dotnet-install.sh"
    curl -fsSL --retry 3 --connect-timeout 20 -o "$script" "$DOTNET_INSTALL_URL" \
        || die "Failed to download dotnet-install.sh from $DOTNET_INSTALL_URL"
    bash "$script" --channel "$channel" --runtime aspnetcore --install-dir "$RUNTIME_DIR" \
        || die "dotnet-install.sh failed for channel $channel"
    rm -f "$script"
    ok "Runtime installed: $("$DOTNET" --version)"
}

remove_runtime() {
    if is_running; then
        warn "Stop ASF first before removing the runtime"
        pause_msg
        return
    fi
    if confirm_yn "Remove the entire runtime directory ($RUNTIME_DIR)?"; then
        rm -rf "$RUNTIME_DIR"
        ok "Runtime removed. It will be downloaded again automatically on next start."
    fi
}

ensure_runtime() { # called before every ASF start (on-demand download)
    if [[ ! -x "$DOTNET" ]]; then
        msg "Runtime not found - downloading the required runtime now"
        install_runtime
    fi
}

# -----------------------------------------------------------------------------
#  ASF process control
# -----------------------------------------------------------------------------
asf_cmdline() { echo "ArchiSteamFarm.dll --path $ASF_DIR"; }

is_running() {
    pgrep -f "$(asf_cmdline)" >/dev/null 2>&1
}

asf_cmd() { # inject a console command into ASF via FIFO
    [[ -p "$FIFO" ]] || return 1
    echo "$1" > "$FIFO" 2>/dev/null || true
}

start_asf() {
    is_running && { warn "ASF is already running"; pause_msg; return 1; }
    require_tput
    ensure_runtime

    # Clean up a leftover FIFO writer from a previous crashed session
    local old_holder
    old_holder=$(cat "$ASF_HOME/asf-holder.pid" 2>/dev/null || true)
    [[ -n "$old_holder" ]] && kill "$old_holder" 2>/dev/null || true

    [[ -p "$FIFO" ]] || mkfifo "$FIFO"
    cd "$ASF_DIR"
    # Start ASF first: its stdin (read end of the FIFO) blocks until a writer
    # appears. Then open a dedicated writer with `tail -f /dev/null` so that
    # the FIFO stays open for the whole ASF lifetime - even after this manager
    # exits - and ASF never sees EOF on its interactive console.
    nohup "$DOTNET" ArchiSteamFarm.dll --path "$ASF_DIR" < "$FIFO" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    sleep 0.3
    tail -f /dev/null > "$FIFO" 2>/dev/null &
    echo $! > "$ASF_HOME/asf-holder.pid"
    echo "$pid" > "$PID_FILE"

    # Inject play commands for bots configured in play-only mode
    if [[ -f "$MODE_CONF" ]]; then
        while IFS='=' read -r bot appids; do
            [[ -n "$bot" && -n "$appids" ]] && asf_cmd "play $bot $appids"
        done < "$MODE_CONF"
    fi

    ok "ASF started (pid $pid)"
    pause_msg
}

stop_asf() {
    if ! is_running; then
        warn "ASF is not running"
        pause_msg
        return 1
    fi
    local pid
    pid=$(pgrep -f "$(asf_cmdline)" | head -1)
    msg "Stopping ASF (pid $pid)..."
    kill -INT "$pid" 2>/dev/null || true
    local i
    for ((i = 0; i < 20; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
    local holder
    holder=$(cat "$ASF_HOME/asf-holder.pid" 2>/dev/null || true)
    [[ -n "$holder" ]] && kill "$holder" 2>/dev/null || true
    rm -f "$FIFO" "$PID_FILE" "$ASF_HOME/asf-holder.pid"
    ok "ASF stopped"
    pause_msg
}

# -----------------------------------------------------------------------------
#  Live log (ASF output, ESC to exit, hint pinned to the bottom)
# -----------------------------------------------------------------------------
latest_log_file() {
    local f
    f=$(find "$ASF_DIR/logs" -maxdepth 1 -name '*.log' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2-)
    if [[ -n "$f" ]]; then
        echo "$f"
    elif [[ -f "$ASF_DIR/log.txt" ]]; then
        echo "$ASF_DIR/log.txt"
    fi
}

live_log() {
    local logfile
    logfile=$(latest_log_file) || true
    if [[ -z "$logfile" ]]; then
        warn "No log file found yet - start ASF first"
        pause_msg
        return
    fi
    require_tput
    local rows bottom
    rows=$(tput lines)
    bottom=$((rows - 2))
    tput clear
    tput csr 0 $((bottom - 1))          # scroll region above the hint line
    tput cup "$bottom" 0
    tput rev; printf ' Press ESC to exit live log '; tput sgr0
    tput cup $((bottom - 1)) 0
    tail -f -- "$logfile" &
    local tailpid=$!
    local key
    while :; do
        key=$(read_key)
        # ESC quits live log; any other key (including function keys and
        # stray chars, reported as IGNORE) just keeps the loop running.
        [[ "$key" == "ESC" ]] && break
    done
    kill "$tailpid" 2>/dev/null || true
    wait "$tailpid" 2>/dev/null || true
    tput csr 0 $((rows - 1))
    tput clear
}

# -----------------------------------------------------------------------------
#  Project update (version file comparison)
# -----------------------------------------------------------------------------
local_version() {
    [[ -f "$MANAGER_VERSION_FILE" ]] && cat "$MANAGER_VERSION_FILE" || echo "unknown"
}

remote_version() {
    curl -fsSL --retry 2 --connect-timeout 20 "${MIRROR}${REPO_RAW}/version.txt" 2>/dev/null || true
}

update_project() {
    local lv rv
    lv=$(local_version)
    rv=$(remote_version)
    msg "Local version : $lv"
    msg "Remote version: ${rv:-unreachable}"

    if [[ -z "$rv" ]]; then
        warn "Cannot reach the release version file (check REPO_RAW / MIRROR)"
    elif [[ "$lv" == "$rv" ]]; then
        ok "Project is up to date"
    else
        msg "A new version is available: $rv"
        if confirm_yn "Download and replace the manager now?"; then
            if github_download "$REPO_RAW/asf-manager.sh" "$ASF_HOME/asf-manager.sh.new"; then
                chmod +x "$ASF_HOME/asf-manager.sh.new"
                mv "$ASF_HOME/asf-manager.sh.new" "$ASF_HOME/asf-manager.sh"
                ok "Manager updated to $rv - please restart it"
            else
                warn "Failed to download the new manager"
            fi
        fi
    fi
    pause_msg
}

# -----------------------------------------------------------------------------
#  TUI primitives
# -----------------------------------------------------------------------------
read_key() { # prints UP / DOWN / RIGHT / LEFT / ENTER / ESC / IGNORE
    # Read a single char; when it is ESC, wait a short window for the rest of
    # the escape sequence. CSI ([...) and SS3 (O...) sequences are decoded so
    # arrow keys are recognised even on slow terminals / Termux / SSH, while
    # Home/End/PgUp/PgDn/Insert/Delete/F1-F12 and any plain character are
    # reported as IGNORE so the TUI never quits or acts on them. A lone ESC
    # (nothing follows within the window) is the real ESC key.
    local k k2 k3
    IFS= read -rsn1 k
    if [[ "$k" == $'\e' ]]; then
        IFS= read -rsn1 -t 0.3 k2 || k2=''
        case "$k2" in
            '['|'O')
                IFS= read -rsn1 -t 0.3 k3 || k3=''
                case "$k3" in
                    A) echo UP ;;
                    B) echo DOWN ;;
                    C) echo RIGHT ;;
                    D) echo LEFT ;;
                    *) echo IGNORE ;;
                esac
                ;;
            '')  echo ESC ;;
            *)   echo IGNORE ;;
        esac
    else
        case "$k" in
            '' | $'\n' | $'\r') echo ENTER ;;  # LF (canonical tty) and CR (Termux virtual keyboard sends CR) both mean Enter
            *) echo IGNORE ;;
        esac
    fi
}

# menu <title> <item...> -> sets MENU_SEL (255 = ESC)
menu() {
    local title="$1"; shift
    local items=("$@")
    local sel=0 n=${#items[@]} key i
    while :; do
        tput clear
        printf '\033[1;37m%s\033[0m\n\n' "$title"
        for ((i = 0; i < n; i++)); do
            if ((i == sel)); then
                printf '  \033[1;36m> %s\033[0m\n' "${items[$i]}"
            else
                printf '    %s\n' "${items[$i]}"
            fi
        done
        key=$(read_key)
        case "$key" in
            UP)
                # Explicit if/else instead of `((sel = ...))`: an arithmetic
                # expression that evaluates to 0 returns status 1, and under
                # `set -e` that would kill the whole TUI the moment the cursor
                # wraps around the menu edge (e.g. DOWN on the last item).
                if ((sel == 0)); then
                    sel=$((n - 1))
                else
                    sel=$((sel - 1))
                fi
                ;;
            DOWN)
                if ((sel == n - 1)); then
                    sel=0
                else
                    sel=$((sel + 1))
                fi
                ;;
            RIGHT|LEFT)
                ;;  # not bound in this menu - keep looping
            ENTER)
                MENU_SEL=$sel
                return 0
                ;;
            ESC)
                MENU_SEL=255
                return 0  # return 0: a non-zero return would trip set -e and kill the whole TUI before the caller's case runs
                ;;
            IGNORE)
                ;;  # ignore function keys / stray chars, keep looping
        esac
    done
}

# -----------------------------------------------------------------------------
#  Runtime management page
# -----------------------------------------------------------------------------
runtime_page() {
    local items=("Download / re-download full runtime" "Remove downloaded runtime" "Back")
    while :; do
        tput clear
        printf '\033[1;37mManage Runtime\033[0m\n\n'
        local req inst
        req=$(required_channel 2>/dev/null || echo "N/A")
        inst=$(installed_runtime_version || echo "not installed")
        printf '  Required by ASF : %s\n' "$req"
        printf '  Installed       : %s\n\n' "$inst"
        menu "Manage Runtime" "${items[@]}"
        case "$MENU_SEL" in
            0)
                if confirm_yn "Download the full .NET runtime now?"; then
                    rm -rf "$RUNTIME_DIR"
                    install_runtime
                    pause_msg
                fi
                ;;
            1) remove_runtime ;;
            2) return ;;
            255) return ;;
        esac
    done
}

# -----------------------------------------------------------------------------
#  Account management page
# -----------------------------------------------------------------------------
bot_list() { # prints bot config names (excluding ASF.json / IPC.config)
    local f
    for f in "$CONFIG_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f")
        [[ "$base" == "ASF.json" || "$base" == "IPC.config" ]] && continue
        echo "$base"
    done
}

bot_enabled_state() { # bot_name -> true/false
    python3 - "$CONFIG_DIR/$1" <<'PY' 2>/dev/null || echo "?"
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(bool(json.load(f).get('Enabled', False)))
except Exception:
    print('?')
PY
}

write_bot_json() { # bot_name python_code
    local bot="$1" code="$2"
    python3 - "$CONFIG_DIR/$bot.json" <<PY
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
$code
with open(path, 'w') as f:
    json.dump(cfg, f, indent=4)
PY
}

add_bot_form() {
    local name login passwd
    printf 'New bot name (no spaces, must not be "ASF"): '
    read -r name
    [[ -n "$name" ]] || { warn "Empty name"; pause_msg; return; }
    [[ "$name" == "ASF" ]] && { warn '"ASF" is reserved'; pause_msg; return; }
    [[ -f "$CONFIG_DIR/$name.json" ]] && { warn "Bot $name already exists"; pause_msg; return; }
    printf 'Steam login : '
    read -r login
    printf 'Steam password : '
    read -rs passwd; printf '\n'
    if [[ -z "$login" || -z "$passwd" ]]; then
        warn "Login and password are required"
        pause_msg
        return
    fi
    # Arguments are passed via argv (not interpolated into source), so quotes /
    # backslashes in the credentials can never break the JSON.
    python3 - "$CONFIG_DIR/$name.json" "$login" "$passwd" <<'PY'
import json, sys
path, login, passwd = sys.argv[1:4]
cfg = {
    "Enabled": True,
    "SteamLogin": login,
    "SteamPassword": passwd,
    "UseLoginKeys": True,
}
with open(path, 'w') as f:
    json.dump(cfg, f, indent=4)
PY
    ok "Bot $name created in $CONFIG_DIR/$name.json (ASF will pick it up automatically)"
    pause_msg
}

edit_bot_form() {
    local bot="$1"
    local login passwd enable
    printf 'Bot: %s\n' "$bot"
    printf 'Steam login [keep current - empty]: '
    read -r login
    printf 'Steam password [keep current - empty]: '
    read -rs passwd; printf '\n'
    printf 'Enabled (true/false) [keep current - empty]: '
    read -r enable

    if [[ -n "$login" || -n "$passwd" || -n "$enable" ]]; then
        python3 - "$CONFIG_DIR/$bot.json" "$login" "$passwd" "$enable" <<'PY'
import json, sys
path, login, passwd, enable = sys.argv[1:5]
with open(path) as f:
    cfg = json.load(f)
if login:
    cfg['SteamLogin'] = login
if passwd:
    cfg['SteamPassword'] = passwd
if enable == 'true':
    cfg['Enabled'] = True
elif enable == 'false':
    cfg['Enabled'] = False
with open(path, 'w') as f:
    json.dump(cfg, f, indent=4)
PY
        ok "Bot $bot updated"
    else
        msg "No changes"
    fi
    pause_msg
}

edit_bot_raw() {
    local bot="$1" editor
    editor="${EDITOR:-vi}"
    if command -v "$editor" >/dev/null 2>&1; then
        "$editor" "$CONFIG_DIR/$bot.json"
    else
        warn "No editor available; falling back to nano"
        command -v nano >/dev/null 2>&1 && nano "$CONFIG_DIR/$bot.json" || warn "Install an editor (e.g. vim/nano) to edit raw JSON"
    fi
    ok "ASF will reload the bot config automatically"
    pause_msg
}

delete_bot() {
    local bot="$1"
    if confirm_yn "Delete bot $bot ($CONFIG_DIR/$bot.json)? This cannot be undone."; then
        rm -f "$CONFIG_DIR/$bot.json"
        ok "Bot $bot deleted"
    fi
    pause_msg
}

account_page() {
    while :; do
        local bots=()
        mapfile -t bots < <(bot_list)
        if [[ ${#bots[@]} -eq 0 ]]; then
            tput clear
            printf '\033[1;37mAccount Config\033[0m\n\n  No bots configured yet.\n'
            pause_msg
        else
            local sel_bot
            local items=("${bots[@]}" "Add new bot" "Back")
            menu "Account Config (select a bot)" "${items[@]}"
            if ((MENU_SEL == 255)); then return; fi
            if ((MENU_SEL == ${#items[@]} - 1)); then return; fi
            if ((MENU_SEL == ${#items[@]} - 2)); then
                add_bot_form
                continue
            fi
            sel_bot="${bots[$MENU_SEL]%.json}"
            local actions=("Edit bot (simple form)" "Edit source JSON" "Delete bot" "Back")
            menu "Bot: $sel_bot (Enabled: $(bot_enabled_state "$sel_bot"))" "${actions[@]}"
            case "$MENU_SEL" in
                0) edit_bot_form "$sel_bot" ;;
                1) edit_bot_raw "$sel_bot" ;;
                2) delete_bot "$sel_bot" ;;
                *) continue ;;
            esac
        fi
    done
}

# -----------------------------------------------------------------------------
#  Farm mode switch (auto card farming vs play-only specific APPIDs)
# -----------------------------------------------------------------------------
farm_mode_page() {
    while :; do
        local bots=()
        mapfile -t bots < <(bot_list)
        if [[ ${#bots[@]} -eq 0 ]]; then
            tput clear
            printf '\033[1;37mFarm Mode Switch\033[0m\n\n  No bots configured yet - add bots first.\n'
            pause_msg
            return
        fi
        local items=("${bots[@]}" "Back")
        menu "Farm Mode Switch (select a bot)" "${items[@]}"
        if ((MENU_SEL == 255 || MENU_SEL == ${#items[@]} - 1)); then return; fi
        local sel_bot="${bots[$MENU_SEL]%.json}"

        local current="auto card farming"
        if grep -q "^${sel_bot}=" "$MODE_CONF" 2>/dev/null; then
            current="play-only ($(grep "^${sel_bot}=" "$MODE_CONF" | cut -d= -f2-))"
        fi

        local actions=("Auto card farming" "Play-only (specific APPIDs)" "Back")
        menu "Bot: $sel_bot - current: $current" "${actions[@]}"
        case "$MENU_SEL" in
            0)
                # switch back to automatic card farming
                if [[ -f "$MODE_CONF" ]]; then
                    sed -i "/^${sel_bot}=/d" "$MODE_CONF"
                fi
                write_bot_json "$sel_bot" "cfg.pop('FarmingPausedByDefault', None)"
                is_running && asf_cmd "resume $sel_bot"
                ok "$sel_bot: auto card farming mode"
                pause_msg
                ;;
            1)
                local appids
                printf 'APPIDs to play (comma separated, e.g. 730,570): '
                read -r appids
                [[ -n "$appids" ]] || { warn "No APPIDs given"; pause_msg; continue; }
                write_bot_json "$sel_bot" "cfg['FarmingPausedByDefault'] = True"
                if [[ -f "$MODE_CONF" ]]; then
                    sed -i "/^${sel_bot}=/d" "$MODE_CONF"
                fi
                echo "$sel_bot=$appids" >> "$MODE_CONF"
                if is_running; then
                    asf_cmd "play $sel_bot $appids"
                    ok "Command 'play $sel_bot $appids' injected into running ASF"
                else
                    msg "Will inject 'play $sel_bot $appids' automatically on next start"
                fi
                pause_msg
                ;;
            *) continue ;;
        esac
    done
}

# -----------------------------------------------------------------------------
#  Main menu / entry point
# -----------------------------------------------------------------------------
main_menu() {
    while :; do
        local start_label="Start ArchiSteamFarm"
        is_running && start_label="Stop ArchiSteamFarm"
        local items=("$start_label" "Manage Runtime" "Live Log" "Update Project" "Account Config" "Farm Mode Switch" "Exit")
        menu "ASF Manager (home: $ASF_HOME)" "${items[@]}"
        case "$MENU_SEL" in
            0)
                if is_running; then
                    stop_asf
                else
                    start_asf
                fi
                ;;
            1) runtime_page ;;
            2) live_log ;;
            3) update_project ;;
            4) account_page ;;
            5) farm_mode_page ;;
            6|255) exit 0 ;;
        esac
    done
}

main() {
    require_tput
    command -v pgrep >/dev/null 2>&1 || die "pgrep (procps) is required"
    command -v python3 >/dev/null 2>&1 || warn "python3 not found - JSON editing features will be limited"
    main_menu
}

main "$@"
