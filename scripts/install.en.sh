#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# code-server Termux One-Click Deployment Script
# Companion for localhost.webview.code Android WebView app
#
# Usage:
#   bash install.sh               # Interactive install
#   bash install.sh start         # Start service
#   bash install.sh stop          # Stop service
#   bash install.sh restart       # Restart service
#   bash install.sh status        # View status
#   bash install.sh enable        # Enable auto-start
#   bash install.sh disable       # Disable auto-start
#   bash install.sh uninstall     # Uninstall
# ============================================================================

set -e

# =========================== Constants ===========================
SERVICE_NAME="code-server"
CONFIG_DIR="$HOME/.config/code-server"
REWRITE_JS="$CONFIG_DIR/rewrite-android2linux.js"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOG_DIR="$HOME/.local/share/code-server"
EXIT_LOG="$LOG_DIR/exit.log"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
ARGV_FILE="$HOME/.local/share/code-server/User/argv.json"

# Preloaded extensions — Phase 1: VS Code Marketplace (not available on Open VSX)
EXTENSIONS_VSCODE_MARKETPLACE=(
    "ms-vsliveshare.vsliveshare@1.0.5936"
    "GitHub.copilot-chat"
)

# Preloaded extensions — Phase 2: Open VSX (code-server default)
EXTENSIONS_OPEN_VSX=(
    "Kelvin.vscode-sshfs"
)

# =========================== Color Output ===========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "${BLUE}==>${NC} $1"; }
ok()    { echo -e "     ${GREEN}✓${NC} $1"; }

banner() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  code-server Termux Deployment Script         ║${NC}"
    echo -e "${BOLD}║  Companion for localhost.webview.code         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    echo "Usage: bash install.sh [subcommand]"
    echo ""
    echo "  install     Interactive install (default)"
    echo "  start       Start service"
    echo "  stop        Stop service"
    echo "  restart     Restart service"
    echo "  status      View status"
    echo "  enable      Enable auto-start"
    echo "  disable     Disable auto-start"
    echo "  update      Update code-server"
    echo "  reinstall   Force reinstall"
    echo "  linux       Switch to Linux mode"
    echo "  android     Switch to Android mode"
    echo "  extension   Manage extensions"
    echo "  uninstall   Uninstall"
    echo ""
    echo "After install, use:"
    echo "  code start | stop | restart | status | update | extension ..."
}

# =========================== Environment Check ===========================
check_termux() {
    step "Checking Termux environment..."
    [ -n "$PREFIX" ] && [ -d "$PREFIX" ] || { error "Please run in Termux"; exit 1; }
    [ "$(uname -o)" = "Android" ] || { error "Current system is not Android"; exit 1; }
    ok "Termux environment OK"
}

# =========================== Dependencies ===========================
install_deps() {
    step "Updating package list..."
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1 || { error "pkg update failed"; exit 1; }

    step "Installing required dependencies..."
    { yes '' 2>/dev/null || true; } | pkg install -y termux-services openssl-tool git nodejs || { error "Dependency installation failed"; exit 1; }
    ok "Dependencies installed"
}

# =========================== Install code-server ===========================
install_code_server() {
    step "Installing code-server..."

    if command -v code-server &>/dev/null; then
        ok "code-server already installed: $(code-server --version 2>&1 | head -1)"
        return 0
    fi

    # Strategy 1: pkg prebuilt (tur-repo)
    step "  Enabling tur-repo and installing via pkg..."
    pkg install -y tur-repo 2>&1 || true
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1 || true

    if pkg install -y code-server 2>&1; then
        hash -r 2>/dev/null || true
        command -v code-server &>/dev/null && { ok "code-server installed (pkg)"; return 0; }
    fi

    # Strategy 2: GitHub prebuilt binary
    warn "pkg failed, downloading prebuilt binary from GitHub..."

    local arch
    case "$(uname -m)" in
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7l" ;;
        x86_64)  arch="amd64" ;;
        *)       error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    local tarball="code-server-linux-${arch}.tar.gz"
    local url="https://github.com/coder/code-server/releases/latest/download/${tarball}"

    step "  Downloading $tarball ..."
    local tmpdir
    tmpdir=$(mktemp -d)

    if curl -fsSL --retry 3 -o "$tmpdir/$tarball" "$url"; then
        tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
        local extracted_dir
        extracted_dir=$(find "$tmpdir" -maxdepth 1 -type d -name "code-server-*" | head -1)
        if [ -d "$extracted_dir" ]; then
            mkdir -p "$PREFIX/lib/code-server"
            cp -r "$extracted_dir"/* "$PREFIX/lib/code-server/"
            ln -sf "$PREFIX/lib/code-server/bin/code-server" "$PREFIX/bin/code-server"
            chmod +x "$PREFIX/bin/code-server"
            rm -rf "$tmpdir"
            hash -r 2>/dev/null || true
            command -v code-server &>/dev/null && { ok "code-server installed (GitHub)"; return 0; }
        fi
        rm -rf "$tmpdir"
    fi

    error "code-server installation failed"
    error "  Manual install: pkg install -y tur-repo && pkg install -y code-server"
    exit 1
}

# =========================== Create Platform Polyfill ===========================
create_rewrite_js() {
    step "Creating Android -> Linux platform polyfill..."
    mkdir -p "$CONFIG_DIR"
    cat > "$REWRITE_JS" << 'JSEOF'
// rewrite process.platform from "android" to "linux"
Object.defineProperty(process, "platform", {
  get() { return "linux" },
})
JSEOF
    ok "Created $REWRITE_JS"
}

# =========================== Create code-server Config ===========================
create_config() {
    step "Configuring code-server..."
    mkdir -p "$CONFIG_DIR"

    if [ -f "$CONFIG_FILE" ]; then
        warn "Config already exists: $CONFIG_FILE"
        read -r -p "  Reconfigure password? (y/N): " reconf
        if [[ ! "$reconf" =~ ^[Yy] ]]; then
            ok "Keeping existing config"
            return 0
        fi
        info "Reconfiguring password..."
    fi

    echo ""
    echo -e "  ${BOLD}Set code-server access password${NC}"
    echo "  Press Enter to skip (no password)"

    local password="" auth="none"

    read -s -r -p "  Enter password (empty to skip): " password
    echo ""

    if [ -z "$password" ]; then
        read -r -p "  Confirm no password? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            auth="none"
            info "No-password mode selected"
        else
            while true; do
                read -s -r -p "  Enter password: " password
                echo ""
                [ -z "$password" ] && { auth="none"; info "No-password mode selected"; break; }
                local pwd2
                read -s -r -p "  Confirm password: " pwd2
                echo ""
                if [ "$password" = "$pwd2" ]; then auth="password"; break
                else error "Passwords do not match, try again"; fi
            done
        fi
    else
        local pwd2
        read -s -r -p "  Confirm password: " pwd2
        echo ""
        if [ "$password" = "$pwd2" ]; then auth="password"
        else
            error "Passwords do not match"; warn "Falling back to no-password mode"; auth="none"
        fi
    fi

    if [ "$auth" = "password" ]; then
        cat > "$CONFIG_FILE" << YAMLEOF
bind-addr: 127.0.0.1:8443
auth: password
password: $password
cert: true
YAMLEOF
    else
        cat > "$CONFIG_FILE" << YAMLEOF
bind-addr: 127.0.0.1:8443
auth: none
cert: true
YAMLEOF
    fi
    chmod 600 "$CONFIG_FILE"

    ok "配置文件Created: $CONFIG_FILE"
    [ "$auth" = "password" ] && ok "Password auth enabled" || ok "No-password mode (localhost only)"
}

# =========================== Marketplace Switching ===========================
_find_product_json() {
    for p in         "$PREFIX/lib/node_modules/code-server/lib/vscode/product.json"         "$PREFIX/lib/code-server/lib/vscode/product.json"; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

_switch_to_vscode_marketplace() {
    local product_json
    product_json=$(_find_product_json)
    if [ -z "$product_json" ]; then
        warn "product.json not found, skipping marketplace switch"
        return 1
    fi
    cp "$product_json" "$product_json.bak" || { warn "Failed to backup product.json"; return 1; }

    if command -v node &>/dev/null; then
        local had_gallery
        had_gallery=$(node -e "
            var fs=require('fs'),p=JSON.parse(fs.readFileSync('$product_json','utf8'));
            var had=p.extensionsGallery?1:0;
            p.extensionsGallery={serviceUrl:'https://marketplace.visualstudio.com/_apis/public/gallery',itemUrl:'https://marketplace.visualstudio.com/items'};
            fs.writeFileSync('$product_json',JSON.stringify(p,null,2));
            process.stdout.write(String(had));
        " || true)
        if [ "$had_gallery" = "0" ]; then
            touch "$product_json.no_gallery" || true
            info "Switched to VS Code Marketplace (product.json had no extensionsGallery)"
        else
            info "Switched to VS Code Marketplace"
        fi
    else
        warn "node unavailable, cannot switch marketplace"
        return 1
    fi
}

_restore_marketplace() {
    local product_json
    product_json=$(_find_product_json)
    [ -z "$product_json" ] && return 1

    if [ -f "$product_json.no_gallery" ]; then
        node -e "
            var fs=require('fs'),p=JSON.parse(fs.readFileSync('$product_json','utf8'));
            delete p.extensionsGallery;
            fs.writeFileSync('$product_json',JSON.stringify(p,null,2));
        " 2>/dev/null || true
        rm -f "$product_json.no_gallery" "$product_json.bak" || true
    elif [ -f "$product_json.bak" ]; then
        mv "$product_json.bak" "$product_json" || true
    fi
    info "Restored default marketplace (Open VSX)"
}

# =========================== Install Single Extension ===========================
_install_one() {
    local ext="$1" ext_dir="$2"
    local ext_name install_target="$ext"

    if [[ "$ext" =~ \.vsix(\?.*)?$ ]]; then
        ext_name=$(basename "$ext" .vsix | sed 's/-[0-9].*//')
    else
        ext_name=$(echo "$ext" | sed 's/@.*//')
    fi

    echo -n "    安装 $ext_name ... "

    if [[ "$ext" =~ ^https?:// ]]; then
        local tmp_vsix
        tmp_vsix=$(mktemp -d)/"${ext_name}.vsix"
        if curl -fsSL --retry 2 -o "$tmp_vsix" "$ext" 2>/dev/null; then
            install_target="$tmp_vsix"
            local sz; sz=$(stat -c%s "$tmp_vsix" 2>/dev/null || echo "?")
            echo -n "(下载 ${sz} bytes) "
        else
            echo -e "${RED}✗${NC} (下载failed)"
            return 1
        fi
    fi

    local err_output exit_code
    err_output=$(NODE_OPTIONS="--require $REWRITE_JS" code-server --force --install-extension "$install_target" 2>&1)
    exit_code=$?

    local installed_ok=false
    if [ $exit_code -eq 0 ]; then
        if ls "$ext_dir" 2>/dev/null | grep -qi "$ext_name"; then
            installed_ok=true
        elif NODE_OPTIONS="--require $REWRITE_JS" code-server --list-extensions 2>/dev/null | grep -qi "$ext_name"; then
            installed_ok=true
        fi
    fi

    [[ "$install_target" != "$ext" ]] && rm -f "$install_target" || true

    if $installed_ok; then
        echo -e "${GREEN}✓${NC}"; return 0
    else
        echo -e "${RED}✗${NC}"
        [ -n "$err_output" ] && { echo "$err_output" | while read -r line; do echo "        $line"; done; } || true
        return 1
    fi
}
# =========================== 安装扩展 ===========================
install_extensions() {
    step "Installing preloaded extensions..."

    # 预检
    step "  Pre-checking code-server..."
    local cs_out
    cs_out=$(NODE_OPTIONS="--require $REWRITE_JS" code-server --version 2>&1) || {
        warn "code-server --version error: $cs_out"
    }

    local ext_dir="$HOME/.local/share/code-server/extensions"
    mkdir -p "$ext_dir" || true
    info "  Extensions directory: $ext_dir"

    local installed=() failed=()

    # ---- 第一阶段：VS Code 官方市场 ----
    if [ ${#EXTENSIONS_VSCODE_MARKETPLACE[@]} -gt 0 ]; then
        step "  Phase 1: VS Code Marketplace"
        _switch_to_vscode_marketplace || warn "Marketplace switch failed, Phase 1 may not install"
        echo ""

        for ext in "${EXTENSIONS_VSCODE_MARKETPLACE[@]}"; do
            if _install_one "$ext" "$ext_dir"; then
                installed+=("$ext")
            else
                failed+=("$ext")
            fi
        done

        _restore_marketplace
        echo ""
    fi

    # ---- 第二阶段：Open VSX（code-server 默认） ----
    if [ ${#EXTENSIONS_OPEN_VSX[@]} -gt 0 ]; then
        step "  Phase 2: Open VSX"
        echo ""

        for ext in "${EXTENSIONS_OPEN_VSX[@]}"; do
            if _install_one "$ext" "$ext_dir"; then
                installed+=("$ext")
            else
                failed+=("$ext")
            fi
        done
        echo ""
    fi


    echo ""
    ok "Extensions installed: ${#installed[@]} success / ${#failed[@]} failed"
    if [ ${#failed[@]} -gt 0 ]; then
        warn "以下扩展安装failed:"
        for f in "${failed[@]}"; do echo "     - $f"; done
        echo ""
        warn "Manual install example:"
        echo "  NODE_OPTIONS=\"--require $REWRITE_JS\" code-server --force --install-extension <扩展>"
    fi
}

# =========================== Setup termux-services ===========================
setup_service() {
    step "Configuring termux-services service..."

    mkdir -p "$SERVICE_DIR/log" "$LOG_DIR"

    cat > "$SERVICE_DIR/run" << RUNEOF
#!/data/data/com.termux/files/usr/bin/bash
exec env NODE_OPTIONS="--require $REWRITE_JS" code-server \\
    --app-name "Visual Studio Code" \\
    --welcome-text "Visual Studio Code" \\
    --bind-addr 127.0.0.1:8443 \\
    --cert \\
    --config "$CONFIG_FILE" \\
    2>&1
RUNEOF
    chmod +x "$SERVICE_DIR/run"

    cat > "$SERVICE_DIR/finish" << 'FINEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "[$(date '+%Y-%m-%d %H:%M:%S')] code-server exited with status $1" >> "$EXIT_LOG"
FINEOF
    chmod +x "$SERVICE_DIR/finish"

    cat > "$SERVICE_DIR/log/run" << LOGEOF
#!/data/data/com.termux/files/usr/bin/bash
mkdir -p "$LOG_DIR"
exec svlogd -t "$LOG_DIR"
LOGEOF
    chmod +x "$SERVICE_DIR/log/run"

    ok "服务配置Created: $SERVICE_DIR"
}

# =========================== Installation Summary ===========================
print_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           Deployment Complete!                        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  code-server running at https://127.0.0.1:8443"
    echo ""
    echo -e "  ${YELLOW}⚠ Restart Termux after first install of termux-services${NC}"
    echo "  After restart run:"
    echo ""
    echo "  code start                 # Start service"
    echo "  code enable                # Enable auto-start"
    echo ""
    echo "  For additional extensions switch to Linux mode:"
    echo "  code linux                 # Then code extension install <ID>"
    echo "  code android               # Switch back after installing"
    echo ""
    echo "  ⚠ Live Share requires Android mode"
    echo "  For Live Share, ensure: code android"
    echo ""
}

# =========================== Service Management ===========================
_sv_ready() {
    if ! command -v sv &>/dev/null; then
        [ -f "$PREFIX/etc/profile.d/termux-services.sh" ] && source "$PREFIX/etc/profile.d/termux-services.sh"
    fi
    command -v sv &>/dev/null || { error "sv unavailable, please restart Termux"; exit 1; }
}

sv_start() {
    _sv_ready
    step "启动 $SERVICE_NAME ..."
    sv up "$SERVICE_NAME"
    sleep 1
    sv status "$SERVICE_NAME" 2>&1 | grep -q 'run:' && ok "Started (127.0.0.1:8443)" || warn "启动可能failed"
}

sv_stop() {
    _sv_ready
    step "停止 $SERVICE_NAME ..."
    sv down "$SERVICE_NAME"
    sleep 1
    sv status "$SERVICE_NAME" 2>&1 | grep -q 'down:' && ok "Stopped" || warn "停止可能failed"
}

sv_restart() {
    _sv_ready
    step "重启 $SERVICE_NAME ..."
    sv down "$SERVICE_NAME"; sleep 2; sv up "$SERVICE_NAME"; sleep 1
    sv status "$SERVICE_NAME" 2>&1 | grep -q 'run:' && ok "Restarted" || warn "重启可能failed"
}

sv_status() {
    _sv_ready
    if sv status "$SERVICE_NAME" 2>&1 | grep -q 'run:'; then
        local pid
        pid=$(sv status "$SERVICE_NAME" 2>&1 | grep -oP '\(pid \K[0-9]+')
        echo -e "${GREEN}●${NC} code-server running"
        echo "  Address: https://127.0.0.1:8443"
        [ -n "$pid" ] && echo "  PID:  $pid"
        [ -f "$EXIT_LOG" ] && { echo "  Recent exits:"; tail -3 "$EXIT_LOG" | sed 's/^/    /'; }
    else
        echo -e "${RED}●${NC} code-server not running"
    fi
}

sv_enable() {
    _sv_ready
    step "Enabling auto-start..."
    command -v sv-enable &>/dev/null && sv-enable "$SERVICE_NAME" 2>/dev/null || true
    ok "Auto-start enabled"
}

sv_disable() {
    _sv_ready
    step "Disabling auto-start..."
    command -v sv-disable &>/dev/null && sv-disable "$SERVICE_NAME" 2>/dev/null || true
    ok "Auto-start disabled"
}

# =========================== Uninstall ===========================
do_uninstall() {
    echo ""
    warn "About to uninstall code-server service & config"
    read -r -p "  Confirm? (type YES to continue): " confirm
    [ "$confirm" != "YES" ] && { info "Cancelled"; exit 0; }

    step "Stopping service..."
    if command -v sv &>/dev/null; then sv down "$SERVICE_NAME" 2>/dev/null || true; fi
    [ -f "$PREFIX/etc/profile.d/termux-services.sh" ] && {
        source "$PREFIX/etc/profile.d/termux-services.sh"
        sv down "$SERVICE_NAME" 2>/dev/null || true
        sv-disable "$SERVICE_NAME" 2>/dev/null || true
    }

    step "Cleaning up files..."
    rm -rf "$SERVICE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$ARGV_FILE"

    rm -f "$PREFIX/bin/code" || true

    echo ""
    read -r -p "  Remove code-server binary? (y/N): " purge
    if [[ "$purge" =~ ^[Yy] ]]; then
        step "Uninstalling code-server..."
        pkg uninstall -y code-server 2>/dev/null || true
        rm -f "$PREFIX/bin/code" || true
        ok "code-server fully removed"
    else
        warn "code-server binary kept (run: pkg uninstall code-server)"
    fi
    ok "Uninstall complete"
}

# =========================== Mode Switching ===========================
_switch_mode() {
    local mode="$1"
    local runfile="$SERVICE_DIR/run"
    [ -f "$runfile" ] || { error "Service not installed, run code install first"; exit 1; }

    case "$mode" in
        linux)
            if grep -q 'env NODE_OPTIONS=' "$runfile" 2>/dev/null; then
                info "Already in Linux mode"
                return 0
            fi
            sed -i "s|^exec code-server|exec env NODE_OPTIONS=\"--require $REWRITE_JS\" code-server|" "$runfile" || true
            ok "Switched to Linux mode"
            sv_restart
            ;;
        android)
            if ! grep -q 'env NODE_OPTIONS=' "$runfile" 2>/dev/null; then
                info "Already in Android mode"
                return 0
            fi
            sed -i 's|^exec env NODE_OPTIONS="[^"]*" code-server|exec code-server|' "$runfile" || true
            ok "Switched to Android mode"
            sv_restart
            ;;
        *)
            echo "Usage: code linux | code android"
            ;;
    esac
}

# =========================== Update ===========================
do_update() {
    step "Updating code-server..."
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1 || { error "pkg update failed"; exit 1; }
    pkg upgrade -y code-server || { error "更新failed"; exit 1; }
    ok "code-server updated"
    sv_restart
}

# =========================== Extension Management ===========================
do_extension() {
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        install)
            [ -z "$1" ] && { error "Usage: code extension install <extension-id>"; exit 1; }
            step "Installing extension: $1"
            local ext_dir="$HOME/.local/share/code-server/extensions"
            mkdir -p "$ext_dir" || true
            NODE_OPTIONS="--require $REWRITE_JS" code-server --force --install-extension "$1"                 && ok "Installation complete" || error "安装failed"
            ;;
        list)
            step "已Installing extension:"
            NODE_OPTIONS="--require $REWRITE_JS" code-server --list-extensions 2>/dev/null | while read -r line; do echo "  $line"; done || true
            ;;
        uninstall)
            [ -z "$1" ] && { error "Usage: code extension uninstall <extension-id>"; exit 1; }
            step "Uninstalling extension: $1"
            NODE_OPTIONS="--require $REWRITE_JS" code-server --uninstall-extension "$1"                 && ok "Uninstall complete" || error "卸载failed"
            ;;
        *)
            echo "Usage: code extension [install|list|uninstall] [extension-id]"
            ;;
    esac
}

# =========================== Main Flow ===========================
do_install() {
    banner
    check_termux
    echo ""
    install_deps
    echo ""
    install_code_server
    echo ""
    create_rewrite_js
    echo ""
    create_config
    echo ""
    setup_service
    echo ""
    install_extensions
    echo ""
    print_summary
}

# =========================== Register Shortcut ===========================
_register_code() {
    local self_path
    self_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")")
    [ "$self_path" = "$PREFIX/bin/code" ] && return 0
    if [ -f "$self_path" ]; then
        cp "$self_path" "$PREFIX/bin/code" || true
        chmod +x "$PREFIX/bin/code" || true
    fi
}

# =========================== Entry Point ===========================
case "${1:-install}" in
    install)
        if command -v code-server &>/dev/null; then
            usage
        else
            do_install
        fi
        ;;
    start)     sv_start ;;
    stop)      sv_stop ;;
    restart)   sv_restart ;;
    status)    sv_status ;;
    enable)    sv_enable ;;
    disable)   sv_disable ;;
    update)    do_update ;;
    reinstall)
        step "Force reinstalling code-server..."
        pkg install -y code-server || { error "重装failed"; exit 1; }
        hash -r 2>/dev/null || true
        ok "code-server reinstalled"
        sv_restart
        ;;
    linux)    shift; _switch_mode "${1:-linux}" ;;
    android)  _switch_mode "android" ;;
    extension) shift; do_extension "$@" ;;
    uninstall) do_uninstall ;;
    -h|--help) usage ;;
    *)         error "Unknown subcommand: $1"; usage; exit 1 ;;
esac

# 确保 code 快捷指令始终为最新（除彻底卸载外）
[ "$1" != "uninstall" ] && _register_code
