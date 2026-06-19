#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# code-server Termux 一键部署脚本
# 配套 localhost.webview.code Android WebView 应用
#
# 用法:
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

# =========================== 常量 ===========================
SERVICE_NAME="code-server"
CONFIG_DIR="$HOME/.config/code-server"
REWRITE_JS="$CONFIG_DIR/rewrite-android2linux.js"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOG_DIR="$HOME/.local/share/code-server"
EXIT_LOG="$LOG_DIR/exit.log"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
ARGV_FILE="$HOME/.local/share/code-server/User/argv.json"

# 预装扩展 —— 第一阶段：从 VS Code 官方市场安装（Open VSX 上没有的）
EXTENSIONS_VSCODE_MARKETPLACE=(
    "ms-vsliveshare.vsliveshare@1.0.5936"
    "GitHub.copilot-chat"
)

# 预装扩展 —— 第二阶段：从 Open VSX 安装（code-server 默认市场）
EXTENSIONS_OPEN_VSX=(
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
    echo "  update      更新 code-server"
    echo "  reinstall   强制重装 code-server"
    echo "  linux       切换至 Linux 模式"
    echo "  android     切换回 Android 模式"
    echo "  extension   管理扩展 (install|list|uninstall)"
    echo "  uninstall   卸载清理"
    echo ""
    echo "安装后也可使用 code 命令:"
    echo "  code start | stop | restart | status | update | extension ..."
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
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1 || { error "pkg update 失败"; exit 1; }

    step "安装必要依赖..."
    { yes '' 2>/dev/null || true; } | pkg install -y termux-services openssl-tool git nodejs || { error "依赖安装失败"; exit 1; }
    ok "依赖安装完成"
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

    error "code-server 安装失败"
    error ""
    error "  Termux 上唯一可靠的安装方式是通过 tur-repo："
    error "    pkg install -y tur-repo && pkg update && pkg install -y code-server"
    error ""
    error "  如果仍然失败，请检查："
    error "    1. 网络是否能访问 tur-repo 源"
    error "    2. 尝试 pkg update 后重试"
    error "    3. 运行 termux-change-repo 更换镜像源"
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

# =========================== 市场切换 ===========================
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
        warn "找不到 product.json，跳过市场切换"
        return 1
    fi
    cp "$product_json" "$product_json.bak" || { warn "备份 product.json 失败"; return 1; }

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
            info "已切换至 VS Code 官方市场 (product.json 中原本无 extensionsGallery)"
        else
            info "已切换至 VS Code 官方市场"
        fi
    else
        warn "node 不可用，无法切换市场"
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
    info "已恢复默认市场 (Open VSX)"
}

# =========================== 安装单个扩展 ===========================
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
            echo -e "${RED}✗${NC} (下载失败)"
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
    step "安装预装扩展..."

    # 预检
    step "  预检 code-server 运行状态..."
    local cs_out
    cs_out=$(NODE_OPTIONS="--require $REWRITE_JS" code-server --version 2>&1) || {
        warn "code-server --version 异常: $cs_out"
    }

    local ext_dir="$HOME/.local/share/code-server/extensions"
    mkdir -p "$ext_dir" || true
    info "  扩展目录: $ext_dir"

    local installed=() failed=()

    # ---- 第一阶段：VS Code 官方市场 ----
    if [ ${#EXTENSIONS_VSCODE_MARKETPLACE[@]} -gt 0 ]; then
        step "  第一阶段: VS Code 官方市场"
        _switch_to_vscode_marketplace || warn "市场切换失败，第一阶段扩展可能无法安装"
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
        step "  第二阶段: Open VSX"
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

    # ---- 中文语言包 → 自动配置 locale ----
    for ext in "${installed[@]}"; do
        if echo "$ext" | grep -qi "language-pack.*zh"; then
            step "  中文语言包已安装，设置 locale: zh-cn"
            mkdir -p "$(dirname "$ARGV_FILE")" || true
            if [ ! -f "$ARGV_FILE" ]; then
                echo '{"locale":"zh-cn"}' > "$ARGV_FILE" || true
                ok "已创建 argv.json"
            elif ! grep -q '"locale"' "$ARGV_FILE" 2>/dev/null; then
                sed -i 's/}$/,"locale":"zh-cn"}/' "$ARGV_FILE" || true
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
    echo "  code start                 # 启动服务"
    echo "  code enable                # 启用自启"
    echo ""
    echo "  安装额外扩展建议切换至 Linux 模式:"
    echo "  code linux                 # 切换后 code extension install <ID>"
    echo "  code android               # 安装完切回 Android 模式"
    echo ""
    echo "  ⚠ Live Share 必须在 Android 模式下运行"
    echo "  如需使用 Live Share 请确保已切回: code android"
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

    rm -f "$PREFIX/bin/code" || true

    echo ""
    read -r -p "  是否彻底卸载 code-server 本体？(y/N): " purge
    if [[ "$purge" =~ ^[Yy] ]]; then
        step "卸载 code-server..."
        pkg uninstall -y code-server 2>/dev/null || true
        rm -f "$PREFIX/bin/code" || true
        ok "code-server 已彻底卸载"
    else
        warn "code-server 本体已保留（如需卸载: pkg uninstall code-server）"
    fi
    ok "卸载完成"
}

# =========================== 模式切换 ===========================
_switch_mode() {
    local mode="$1"
    local runfile="$SERVICE_DIR/run"
    [ -f "$runfile" ] || { error "服务未安装，请先运行 code install"; exit 1; }

    case "$mode" in
        linux)
            if grep -q 'env NODE_OPTIONS=' "$runfile" 2>/dev/null; then
                info "已是 Linux 模式"
                return 0
            fi
            sed -i "s|^exec code-server|exec env NODE_OPTIONS=\"--require $REWRITE_JS\" code-server|" "$runfile" || true
            ok "已切换至 Linux 模式"
            sv_restart
            ;;
        android)
            if ! grep -q 'env NODE_OPTIONS=' "$runfile" 2>/dev/null; then
                info "已是 Android 模式"
                return 0
            fi
            sed -i 's|^exec env NODE_OPTIONS="[^"]*" code-server|exec code-server|' "$runfile" || true
            ok "已切换至 Android 模式"
            sv_restart
            ;;
        *)
            echo "用法: code linux | code android"
            ;;
    esac
}

# =========================== 更新 ===========================
do_update() {
    step "更新 code-server..."
    pkg update -y -o Dpkg::Options::="--force-confdef" > /dev/null 2>&1 || { error "pkg update 失败"; exit 1; }
    pkg upgrade -y code-server || { error "更新失败"; exit 1; }
    ok "code-server 已更新"
    sv_restart
}

# =========================== 强制重装 ===========================
reinstall_code_server() {
    step "停止服务..."
    if command -v sv &>/dev/null; then sv down "$SERVICE_NAME" 2>/dev/null || true; fi
    [ -f "$PREFIX/etc/profile.d/termux-services.sh" ] && {
        source "$PREFIX/etc/profile.d/termux-services.sh"
        sv down "$SERVICE_NAME" 2>/dev/null || true
    }

    step "强制重装 code-server..."

    # 检测安装方式
    if dpkg -l code-server 2>/dev/null | grep -q '^ii'; then
        # pkg 管理 → 使用 --reinstall 强制重装
        info "检测到 pkg 安装，强制重装..."
        pkg install --reinstall -y code-server || { error "重装失败"; exit 1; }
    elif [ -d "$PREFIX/lib/code-server" ]; then
        # 旧版脚本的损坏手动安装（GitHub 二进制不兼容 Termux）→ 清理后用 pkg 重装
        warn "检测到旧版手动安装（与 Termux 不兼容），清理后通过 pkg 重装..."
        rm -rf "$PREFIX/lib/code-server"
        rm -f "$PREFIX/bin/code-server"
        hash -r 2>/dev/null || true
        install_code_server
    else
        # 未找到安装 → 全新安装
        warn "未检测到 code-server，执行全新安装..."
        install_code_server
    fi

    hash -r 2>/dev/null || true
    ok "code-server 已重装"

    # 重装后恢复平台 polyfill
    create_rewrite_js

    step "重启服务..."
    sv_restart
}

# =========================== 扩展管理 ===========================
do_extension() {
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        install)
            [ -z "$1" ] && { error "用法: code extension install <扩展ID>"; exit 1; }
            step "安装扩展: $1"
            local ext_dir="$HOME/.local/share/code-server/extensions"
            mkdir -p "$ext_dir" || true
            NODE_OPTIONS="--require $REWRITE_JS" code-server --force --install-extension "$1"                 && ok "安装完成" || error "安装失败"
            ;;
        list)
            step "已安装扩展:"
            NODE_OPTIONS="--require $REWRITE_JS" code-server --list-extensions 2>/dev/null | while read -r line; do echo "  $line"; done || true
            ;;
        uninstall)
            [ -z "$1" ] && { error "用法: code extension uninstall <扩展ID>"; exit 1; }
            step "卸载扩展: $1"
            NODE_OPTIONS="--require $REWRITE_JS" code-server --uninstall-extension "$1"                 && ok "卸载完成" || error "卸载失败"
            ;;
        *)
            echo "用法: code extension [install|list|uninstall] [扩展ID]"
            ;;
    esac
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

# =========================== 注册快捷指令 ===========================
_register_code() {
    local self_path
    self_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")")
    [ "$self_path" = "$PREFIX/bin/code" ] && return 0
    if [ -f "$self_path" ]; then
        cp "$self_path" "$PREFIX/bin/code" || true
        chmod +x "$PREFIX/bin/code" || true
    fi
}

# =========================== 入口 ===========================
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
        reinstall_code_server
        ;;
    linux)    shift; _switch_mode "${1:-linux}" ;;
    android)  _switch_mode "android" ;;
    extension) shift; do_extension "$@" ;;
    uninstall) do_uninstall ;;
    -h|--help) usage ;;
    *)         error "未知子命令: $1"; usage; exit 1 ;;
esac

# 确保 code 快捷指令始终为最新（除彻底卸载外）
[ "$1" != "uninstall" ] && _register_code
