#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# code-server Termux 一键部署脚本
# 配套 localhost.webview.code Android WebView 应用
#
# 用法:
#   curl -fsSL <URL> | bash       # 一行部署
#   bash install.sh               # 交互式安装
#   bash install.sh start         # 启动服务
#   bash install.sh stop          # 停止服务
#   bash install.sh restart       # 重启服务
#   bash install.sh status        # 查看状态
#   bash install.sh enable        # 启用自启
#   bash install.sh disable       # 禁用自启
#   bash install.sh uninstall     # 卸载清理
# ============================================================================

set -e

# ---- stdin 检测：管道运行时重定向到终端以支持交互输入 ----
if [ ! -t 0 ]; then
    exec </dev/tty
fi

# =========================== 常量 ===========================
SERVICE_NAME="code-server"
CONFIG_DIR="$HOME/.config/code-server"
REWRITE_JS="$CONFIG_DIR/rewrite-android2linux.js"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOG_DIR="$HOME/.local/share/code-server"
EXIT_LOG="$LOG_DIR/exit.log"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
ARGV_FILE="$HOME/.local/share/code-server/User/argv.json"

# 预装扩展
DEFAULT_EXTENSIONS=(
    "https://touhou.diemoe.net/usr/vsix/ms-vsliveshare.vsliveshare-1.0.5936.vsix"
    "MS-CEINTL.vscode-language-pack-zh-hans"
    "Kelvin.vscode-sshfs"
)

# =========================== 颜色输出 ===========================
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
    echo -e "${BOLD}║   code-server Termux 部署脚本               ║${NC}"
    echo -e "${BOLD}║   配套 localhost.webview.code Android 应用   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    echo "用法: bash install.sh [子命令]"
    echo ""
    echo "  install     交互式安装（默认）"
    echo "  start       启动服务"
    echo "  stop        停止服务"
    echo "  restart     重启服务"
    echo "  status      查看状态"
    echo "  enable      启用自启"
    echo "  disable     禁用自启"
    echo "  uninstall   卸载清理"
}

# =========================== 环境检测 ===========================
check_termux() {
    step "检测 Termux 环境..."
    [ -n "$PREFIX" ] && [ -d "$PREFIX" ] || { error "请在 Termux 中运行"; exit 1; }
    [ "$(uname -o)" = "Android" ] || { error "当前系统不是 Android"; exit 1; }
    ok "Termux 环境正常"
}

# =========================== 依赖安装 ===========================
install_deps() {
    step "更新包列表..."
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1

    step "安装必要依赖..."
    local deps=()
    pkg list-installed termux-services > /dev/null 2>&1 || deps+=(termux-services)
    command -v curl &>/dev/null || deps+=(curl)

    if [ ${#deps[@]} -gt 0 ]; then
        pkg install -y "${deps[@]}"
        ok "依赖安装完成: ${deps[*]}"
    else
        ok "依赖已就绪"
    fi
}

# =========================== 安装 code-server ===========================
install_code_server() {
    step "安装 code-server..."

    if command -v code-server &>/dev/null; then
        ok "code-server 已安装: $(code-server --version 2>&1 | head -1)"
        return 0
    fi

    # 策略 1：pkg 预编译包（tur-repo）
    step "  启用 tur-repo 并尝试 pkg 安装..."
    pkg install -y tur-repo 2>&1 || true
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1 || true

    if pkg install -y code-server 2>&1; then
        hash -r 2>/dev/null || true
        command -v code-server &>/dev/null && { ok "code-server 安装成功 (pkg)"; return 0; }
    fi

    # 策略 2：GitHub 预编译二进制
    warn "pkg 安装失败，从 GitHub 下载预编译二进制..."

    local arch
    case "$(uname -m)" in
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7l" ;;
        x86_64)  arch="amd64" ;;
        *)       error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    local tarball="code-server-linux-${arch}.tar.gz"
    local url="https://github.com/coder/code-server/releases/latest/download/${tarball}"

    step "  下载 $tarball ..."
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
            command -v code-server &>/dev/null && { ok "code-server 安装成功 (GitHub)"; return 0; }
        fi
        rm -rf "$tmpdir"
    fi

    error "code-server 安装失败"
    error "  手动安装: pkg install -y tur-repo && pkg install -y code-server"
    exit 1
}

# =========================== 创建 platform polyfill ===========================
create_rewrite_js() {
    step "创建 Android → Linux platform polyfill..."
    mkdir -p "$CONFIG_DIR"
    cat > "$REWRITE_JS" << 'JSEOF'
// rewrite process.platform from "android" to "linux"
Object.defineProperty(process, "platform", {
  get() { return "linux" },
})
JSEOF
    ok "已创建 $REWRITE_JS"
}

# =========================== 创建 code-server 配置 ===========================
create_config() {
    step "配置 code-server..."
    mkdir -p "$CONFIG_DIR"

    if [ -f "$CONFIG_FILE" ]; then
        warn "配置文件已存在: $CONFIG_FILE"
        read -r -p "  是否重新配置密码？(y/N): " reconf
        if [[ ! "$reconf" =~ ^[Yy] ]]; then
            ok "保留现有配置"
            return 0
        fi
        info "重新配置密码..."
    fi

    echo ""
    echo -e "  ${BOLD}设置 code-server 访问密码${NC}"
    echo "  直接按 Enter 跳过（无密码模式）"

    local password="" auth="none"

    read -s -r -p "  请输入密码（留空跳过）: " password
    echo ""

    if [ -z "$password" ]; then
        read -r -p "  确认不使用密码？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            auth="none"
            info "已选择无密码模式"
        else
            while true; do
                read -s -r -p "  请输入密码: " password
                echo ""
                [ -z "$password" ] && { auth="none"; info "已选择无密码模式"; break; }
                local pwd2
                read -s -r -p "  请再次输入密码: " pwd2
                echo ""
                if [ "$password" = "$pwd2" ]; then auth="password"; break
                else error "两次输入的密码不一致，请重试"; fi
            done
        fi
    else
        local pwd2
        read -s -r -p "  请再次输入密码: " pwd2
        echo ""
        if [ "$password" = "$pwd2" ]; then auth="password"
        else
            error "两次输入不一致"; warn "将使用无密码模式"; auth="none"
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

    ok "配置文件已创建: $CONFIG_FILE"
    [ "$auth" = "password" ] && ok "密码认证已启用" || ok "无密码模式（仅 localhost 可访问）"
}

# =========================== 安装扩展 ===========================
install_extensions() {
    step "安装预装扩展..."

    # 预检
    step "  预检 code-server 运行状态..."
    local cs_out
    cs_out=$(NODE_OPTIONS="--require $REWRITE_JS" code-server --version 2>&1) || {
        warn "code-server --version 异常: $cs_out"
    }

    local ext_dir="$HOME/.local/share/code-server/extensions"
    mkdir -p "$ext_dir"
    info "  扩展目录: $ext_dir"
    echo ""

    local installed=() failed=()

    for ext in "${DEFAULT_EXTENSIONS[@]}"; do
        local ext_name install_target="$ext"

        if [[ "$ext" =~ \.vsix(\?.*)?$ ]]; then
            ext_name=$(basename "$ext" .vsix | sed 's/-[0-9].*//')
        else
            ext_name="$ext"
        fi

        echo -n "  安装 $ext_name ... "

        # vsix URL → 先下载
        if [[ "$ext" =~ ^https?:// ]]; then
            local tmp_vsix
            tmp_vsix=$(mktemp -d)/"${ext_name}.vsix"
            if curl -fsSL --retry 2 -o "$tmp_vsix" "$ext" 2>/dev/null; then
                install_target="$tmp_vsix"
                local sz; sz=$(stat -c%s "$tmp_vsix" 2>/dev/null || echo "?")
                echo -n "(下载 ${sz} bytes) "
            else
                echo -e "${RED}✗${NC} (下载失败)"
                failed+=("$ext"); continue
            fi
        fi

        # 安装
        local err_output exit_code
        err_output=$(NODE_OPTIONS="--require $REWRITE_JS" code-server --force --install-extension "$install_target" 2>&1)
        exit_code=$?

        # 验证
        local installed_ok=false
        if [ $exit_code -eq 0 ]; then
            if ls "$ext_dir" 2>/dev/null | grep -qi "$ext_name"; then
                installed_ok=true
            elif NODE_OPTIONS="--require $REWRITE_JS" code-server --list-extensions 2>/dev/null | grep -qi "$ext_name"; then
                installed_ok=true
            else
                err_output="目录和 --list-extensions 中均未找到（${ext_name}）"
            fi
        fi

        if $installed_ok; then
            echo -e "${GREEN}✓${NC}"; installed+=("$ext")
        else
            echo -e "${RED}✗${NC}"
            [ -n "$err_output" ] && echo "$err_output" | while read -r line; do echo "      $line"; done
            failed+=("$ext")
        fi

        [[ "$install_target" != "$ext" ]] && rm -f "$install_target"
    done

    # ---- 中文语言包 → 自动配置 locale ----
    for ext in "${installed[@]}"; do
        if echo "$ext" | grep -qi "language-pack.*zh"; then
            step "  中文语言包已安装，设置 locale: zh-cn"
            mkdir -p "$(dirname "$ARGV_FILE")"
            if [ ! -f "$ARGV_FILE" ]; then
                echo '{"locale":"zh-cn"}' > "$ARGV_FILE"
                ok "已创建 argv.json"
            elif ! grep -q '"locale"' "$ARGV_FILE" 2>/dev/null; then
                sed -i 's/}$/,"locale":"zh-cn"}/' "$ARGV_FILE"
                ok "已追加 locale"
            else
                info "locale 已配置"
            fi
            break
        fi
    done

    echo ""
    ok "扩展安装完成: ${#installed[@]} 成功 / ${#failed[@]} 失败"
    if [ ${#failed[@]} -gt 0 ]; then
        warn "以下扩展安装失败:"
        for f in "${failed[@]}"; do echo "     - $f"; done
        echo ""
        warn "手动安装示例:"
        echo "  NODE_OPTIONS=\"--require $REWRITE_JS\" code-server --force --install-extension <扩展>"
    fi
}

# =========================== 设置 termux-services ===========================
setup_service() {
    step "配置 termux-services 服务..."

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

    ok "服务配置已创建: $SERVICE_DIR"
}

# =========================== 安装摘要 ===========================
print_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           部署完成！                        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  code-server 将在 https://127.0.0.1:8443 运行"
    echo ""
    echo -e "  ${YELLOW}⚠ termux-services 首次安装后需重启 Termux${NC}"
    echo "  重启后运行:"
    echo ""
    echo "  bash install.sh start      # 启动服务"
    echo "  bash install.sh enable     # 启用自启"
    echo ""
}

# =========================== 服务管理 ===========================
_sv_ready() {
    if ! command -v sv &>/dev/null; then
        [ -f "$PREFIX/etc/profile.d/termux-services.sh" ] && source "$PREFIX/etc/profile.d/termux-services.sh"
    fi
    command -v sv &>/dev/null || { error "sv 不可用，请重启 Termux"; exit 1; }
}

sv_start() {
    _sv_ready
    step "启动 $SERVICE_NAME ..."
    sv up "$SERVICE_NAME"
    sleep 1
    sv status "$SERVICE_NAME" 2>&1 | grep -q 'run:' && ok "已启动 (127.0.0.1:8443)" || warn "启动可能失败"
}

sv_stop() {
    _sv_ready
    step "停止 $SERVICE_NAME ..."
    sv down "$SERVICE_NAME"
    sleep 1
    sv status "$SERVICE_NAME" 2>&1 | grep -q 'down:' && ok "已停止" || warn "停止可能失败"
}

sv_restart() {
    _sv_ready
    step "重启 $SERVICE_NAME ..."
    sv down "$SERVICE_NAME"; sleep 2; sv up "$SERVICE_NAME"; sleep 1
    sv status "$SERVICE_NAME" 2>&1 | grep -q 'run:' && ok "已重启" || warn "重启可能失败"
}

sv_status() {
    _sv_ready
    if sv status "$SERVICE_NAME" 2>&1 | grep -q 'run:'; then
        local pid
        pid=$(sv status "$SERVICE_NAME" 2>&1 | grep -oP '\(pid \K[0-9]+')
        echo -e "${GREEN}●${NC} code-server 运行中"
        echo "  地址: https://127.0.0.1:8443"
        [ -n "$pid" ] && echo "  PID:  $pid"
        [ -f "$EXIT_LOG" ] && { echo "  最近退出:"; tail -3 "$EXIT_LOG" | sed 's/^/    /'; }
    else
        echo -e "${RED}●${NC} code-server 未运行"
    fi
}

sv_enable() {
    _sv_ready
    step "启用自启..."
    command -v sv-enable &>/dev/null && sv-enable "$SERVICE_NAME" 2>/dev/null || true
    ok "已启用自启（Termux 启动时自动拉起）"
}

sv_disable() {
    _sv_ready
    step "禁用自启..."
    command -v sv-disable &>/dev/null && sv-disable "$SERVICE_NAME" 2>/dev/null || true
    ok "已禁用自启"
}

# =========================== 卸载 ===========================
do_uninstall() {
    echo ""
    warn "即将卸载 code-server 服务及配置"
    read -r -p "  确认卸载？(输入 YES 继续): " confirm
    [ "$confirm" != "YES" ] && { info "已取消"; exit 0; }

    step "停止服务..."
    if command -v sv &>/dev/null; then sv down "$SERVICE_NAME" 2>/dev/null || true; fi
    [ -f "$PREFIX/etc/profile.d/termux-services.sh" ] && {
        source "$PREFIX/etc/profile.d/termux-services.sh"
        sv down "$SERVICE_NAME" 2>/dev/null || true
        sv-disable "$SERVICE_NAME" 2>/dev/null || true
    }

    step "清理文件..."
    rm -rf "$SERVICE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$ARGV_FILE"

    warn "code-server 本体未卸载（如需卸载: pkg uninstall code-server）"
    ok "卸载完成"
}

# =========================== 主流程 ===========================
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

# =========================== 入口 ===========================
case "${1:-install}" in
    install)   do_install ;;
    start)     sv_start ;;
    stop)      sv_stop ;;
    restart)   sv_restart ;;
    status)    sv_status ;;
    enable)    sv_enable ;;
    disable)   sv_disable ;;
    uninstall) do_uninstall ;;
    -h|--help) usage ;;
    *)         error "未知子命令: $1"; usage; exit 1 ;;
esac
