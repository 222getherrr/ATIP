#!/usr/bin/env bash
# =============================================================================
#  ASF Manager - one-line installer
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh | bash
#
#  What it does:
#    1. Validates the host OS (Termux proot Ubuntu / Ubuntu / Debian)
#    2. Installs required tools (curl, unzip, python3) when missing
#    3. Downloads ArchiSteamFarm (ASF-generic.zip) through a configurable mirror
#    4. Extracts ASF into $ASF_HOME/asf
#    5. Installs the .NET runtime required by ASF into $ASF_HOME/runtime
#       (the required version is read dynamically from runtimeconfig.json)
#    6. Downloads the TUI manager (asf-manager.sh) into $ASF_HOME
#    7. Writes a minimal default global config when none exists
#
#  Configuration via environment variables (all optional):
#    ASF_VERSION   - ASF release tag to install, default: 6.3.10.6
#    MIRROR        - GitHub acceleration prefix, default: https://ghfast.top/
#                    Every GitHub download is prefixed with this value.
#    ASF_HOME      - installation root, default: $HOME/.asf
#    REPO_RAW      - raw base URL of this project's GitHub repo.
#                    IMPORTANT: replace YOUR_USER/YOUR_REPO below at packaging time.
#
#  Project policy:
#    * English comments and English user-facing text only.
#    * ASF itself is fetched as the generic (runtime-less) package so that one
#      build serves both arm64 and x64. The runtime is managed separately.
# =============================================================================

set -euo pipefail

ASF_VERSION="${ASF_VERSION:-6.3.10.6}"
MIRROR="${MIRROR:-https://ghfast.top/}"
ASF_HOME="${ASF_HOME:-$HOME/.asf}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main}"
DOTNET_INSTALL_URL="${DOTNET_INSTALL_URL:-https://dot.net/v1/dotnet-install.sh}"

log() { printf '\033[1;32m[ASF]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ASF]\033[0m WARNING: %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ASF]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
#  Detect supported OS: Termux (proot Ubuntu) / Ubuntu / Debian
# -----------------------------------------------------------------------------
detect_os() {
    local os_id="" os_like=""
    if [[ -f /etc/os-release ]]; then
        os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
        os_like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')
    fi
    if [[ "$os_id" == "ubuntu" || "$os_like" == *"ubuntu"* ]]; then
        OS_NAME="ubuntu"
    elif [[ "$os_id" == "debian" || "$os_like" == *"debian"* ]]; then
        OS_NAME="debian"
    else
        die "Unsupported OS (id=$os_id). Supported: Termux(proot Ubuntu), Ubuntu, Debian."
    fi
    log "Detected OS: $OS_NAME"
}

# -----------------------------------------------------------------------------
#  Detect CPU architecture
# -----------------------------------------------------------------------------
detect_arch() {
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64)      ARCH="x64" ;;
        aarch64|arm64)     ARCH="arm64" ;;
        armv7l|armv8l)     ARCH="arm" ;;
        *)                 die "Unsupported architecture: $m" ;;
    esac
    log "Detected architecture: $ARCH"
}

# -----------------------------------------------------------------------------
#  Ensure required tools exist (best effort, uses apt)
# -----------------------------------------------------------------------------
ensure_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v unzip >/dev/null 2>&1 || missing+=("unzip")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v tput >/dev/null 2>&1 || missing+=("ncurses-bin")

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing tools: ${missing[*]} - attempting to install via apt"
        if [[ $(id -u) -ne 0 ]]; then
            command -v sudo >/dev/null 2>&1 || die "Root access required to install: ${missing[*]}"
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${missing[@]}" || die "apt install failed: ${missing[*]}"
        else
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}" || die "apt install failed: ${missing[*]}"
        fi
    fi
}

# -----------------------------------------------------------------------------
#  Extract the .NET runtime channel required by ASF (e.g. 10.0)
#  Source of truth: asf/ArchiSteamFarm.runtimeconfig.json
# -----------------------------------------------------------------------------
runtime_channel_from_package() {
    local cfg="$ASF_HOME/asf/ArchiSteamFarm.runtimeconfig.json"
    [[ -f "$cfg" ]] || die "runtimeconfig.json not found: $cfg"
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
    if [[ -z "$ch" ]]; then
        # Fallback: the JSON is formatted multi-line, so name and version are on
        # separate lines; grab the version line right after the matching name.
        ch=$(grep -A1 '"name": "Microsoft.AspNetCore.App"' "$cfg" \
            | sed -n 's/.*"version": "\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' | head -1)
    fi
    [[ -n "$ch" ]] || die "Unable to determine required .NET runtime version"
    echo "$ch"
}

# -----------------------------------------------------------------------------
#  Install the .NET runtime (ASP.NET Core Runtime) into $ASF_HOME/runtime
# -----------------------------------------------------------------------------
install_runtime() {
    local channel
    channel=$(runtime_channel_from_package)
    [[ -n "$channel" ]] || die "Unable to determine required .NET runtime version"
    log "ASF requires .NET runtime channel: $channel"

    local dotnet="$ASF_HOME/runtime/dotnet"
    if [[ -x "$dotnet" ]]; then
        local installed
        installed=$("$dotnet" --version 2>/dev/null || true)
        log "Runtime already installed: $installed"
        return 0
    fi

    log "Downloading .NET Runtime $channel (ASP.NET Core) into $ASF_HOME/runtime"
    mkdir -p "$ASF_HOME/runtime"
    curl -fsSL --retry 3 --connect-timeout 20 -o "$ASF_HOME/dotnet-install.sh" "$DOTNET_INSTALL_URL" \
        || die "Failed to download dotnet-install.sh from $DOTNET_INSTALL_URL"
    bash "$ASF_HOME/dotnet-install.sh" \
        --channel "$channel" \
        --runtime aspnetcore \
        --install-dir "$ASF_HOME/runtime" \
        || die "dotnet-install.sh failed for channel $channel"
    rm -f "$ASF_HOME/dotnet-install.sh"
    log "Runtime installed: $("$ASF_HOME/runtime/dotnet" --version)"
}

# -----------------------------------------------------------------------------
#  Download and extract ASF generic package
# -----------------------------------------------------------------------------
install_asf() {
    local zip="$ASF_HOME/ASF-generic.zip"
    local url="https://github.com/JustArchiNET/ArchiSteamFarm/releases/download/$ASF_VERSION/ASF-generic.zip"

    if [[ -x "$ASF_HOME/asf/ArchiSteamFarm.dll" ]]; then
        log "ASF already present in $ASF_HOME/asf - skipping download"
        return 0
    fi

    log "Downloading ASF $ASF_VERSION (generic) via mirror"
    mkdir -p "$ASF_HOME"
    github_download "$url" "$zip"
    log "Extracting ASF package"
    mkdir -p "$ASF_HOME/asf"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$zip" -d "$ASF_HOME/asf"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "$zip" "$ASF_HOME/asf"
    else
        die "Neither unzip nor python3 is available to extract the ASF package"
    fi
    rm -f "$zip"
    chmod +x "$ASF_HOME/asf/ArchiSteamFarm.sh" 2>/dev/null || true
    log "ASF extracted to $ASF_HOME/asf"
}

# -----------------------------------------------------------------------------
#  Download the TUI manager (self-contained)
# -----------------------------------------------------------------------------
install_manager() {
    local url="$REPO_RAW/asf-manager.sh"
    log "Downloading manager from $url"
    mkdir -p "$ASF_HOME"
    github_download "$url" "$ASF_HOME/asf-manager.sh"
    chmod +x "$ASF_HOME/asf-manager.sh"

    # Version file used by the TUI "Update Project" check
    if github_download "$REPO_RAW/version.txt" "$ASF_HOME/version.txt" 2>/dev/null; then
        log "Version file: $(cat "$ASF_HOME/version.txt")"
    else
        warn "Could not fetch version.txt - update check will be unavailable"
        echo "unknown" > "$ASF_HOME/version.txt"
    fi
}

write_manager_conf() {
    cat > "$ASF_HOME/manager.conf" <<EOF
MIRROR=$MIRROR
REPO_RAW=$REPO_RAW
ASF_VERSION=$ASF_VERSION
EOF
    chmod 600 "$ASF_HOME/manager.conf"
    log "Manager config written to $ASF_HOME/manager.conf"
}

# -----------------------------------------------------------------------------
#  Write a minimal global config on first install (ASF generates the rest)
# -----------------------------------------------------------------------------
write_default_config() {
    local cfg="$ASF_HOME/asf/config/ASF.json"
    [[ -f "$cfg" ]] && return 0
    cat > "$cfg" <<'JSON'
{
  "CurrentCulture": "en-US",
  "Headless": false,
  "IPC": false,
  "IPCPassword": null,
  "SteamOwnerID": 0,
  "AutoRestart": true,
  "Statistics": true
}
JSON
    log "Default ASF.json written (edit it or use the TUI to configure)"
}

# -----------------------------------------------------------------------------
#  Main
# -----------------------------------------------------------------------------
main() {
    log "ASF Manager installer starting"
    detect_os
    detect_arch
    ensure_tools
    install_asf
    install_runtime
    install_manager
    write_manager_conf
    write_default_config

    cat <<EOF

==============================================================================
  ASF Manager installed successfully
==============================================================================
  Location : $ASF_HOME
  ASF      : $ASF_VERSION (generic, runtime managed separately)
  Runtime  : .NET $(runtime_channel_from_package) (ASP.NET Core, in $ASF_HOME/runtime)

  Next steps:
    1. Add bot accounts:
       $ASF_HOME/asf-manager.sh          # choose "Account Config"
    2. Start ASF:
       $ASF_HOME/asf-manager.sh          # choose "Start ArchiSteamFarm"

  One-command future usage:
    $ASF_HOME/asf-manager.sh
==============================================================================
EOF
}

main "$@"
