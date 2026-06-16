# code-server Termux 部署指南

为 [`localhost.webview.code`](../) Android WebView 应用配套的 code-server 部署方案。

## 概述

本脚本在 Android 设备的 **Termux** 环境中一键部署 code-server，通过 `termux-services`（runit）管理服务生命周期和开机自启。

### 架构

```
Android 设备
├── Termux
│   ├── code-server (127.0.0.1:8443)
│   │   ├── 自签名证书（自动托管）
│   │   ├── process.platform → "linux" (polyfill)
│   │   └── termux-services (runit)
│   │       ├── sv up/down    # 启动/停止
│   │       ├── sv status     # 状态
│   │       └── sv-enable     # 自启
│   └── ~/.config/code-server/
│       ├── config.yaml
│       └── rewrite-android2linux.js
└── localhost.webview.code (WebView 应用)
    └── https://localhost:8443/
```

### 关键设计

| 决策 | 原因 |
|------|------|
| `127.0.0.1:8443` 绑定 | 仅本地访问，防止局域网不安全连接 |
| `--cert`（不传参） | code-server 自动生成和管理自签名证书 |
| `process.platform` polyfill | Android 上返回 "linux"，避免兼容问题 |
| `exec` + `finish` 脚本 | runit 信号直传 → `sv down` 可正常停止 |
| 密码认证 | 交互式输入，config.yaml 权限 600 |

## 快速开始

### 前置条件

1. 安装 [Termux](https://f-droid.org/packages/com.termux/)（**F-Droid 版本**，Google Play 版本已停更）
2. （可选）安装 [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) 用于系统级开机自启

### 一键部署

```bash
# 在 Termux 中直接运行（推荐）
curl -fsSL https://touhou.diemoe.net/usr/termux/code-server/install.sh | bash

# 或先下载再运行
curl -fsSLo install.sh https://touhou.diemoe.net/usr/termux/code-server/install.sh
bash install.sh
```

脚本会依次完成：
- 安装 `termux-services`、`code-server` 等依赖
- 创建 `process.platform` polyfill
- 交互式设置访问密码
- 创建 `config.yaml` 和 runit 服务
- 安装预置扩展（Live Share、中文语言包、SSH FS）

### 启动服务

**重要**：`termux-services` 首次安装后，必须重启 Termux 才能使 `sv` 命令生效。

```bash
# 关闭 Termux，重新打开后运行:
bash install.sh start     # 启动服务
bash install.sh enable    # 启用开机自启（Termux 启动时自动拉起）
```

### 常用命令

```bash
bash install.sh start     # 启动 code-server
bash install.sh stop      # 停止 code-server
bash install.sh restart   # 重启 code-server
bash install.sh status    # 查看运行状态和退出日志
bash install.sh enable    # 启用自启
bash install.sh disable   # 禁用自启
bash install.sh uninstall # 清理配置和服务
```

## 预装扩展

部署时自动安装以下扩展：

| 扩展 | ID / 来源 |
|------|-----------|
| VS Live Share | `https://touhou.diemoe.net/usr/vsix/ms-vsliveshare.vsliveshare-1.0.5936.vsix` |
| 中文语言包 | `MS-CEINTL.vscode-language-pack-zh-hans` |
| SSH FS | `Kelvin.vscode-sshfs` |

### 自定义扩展列表

编辑 `install.sh`，修改 `DEFAULT_EXTENSIONS` 数组：

```bash
DEFAULT_EXTENSIONS=(
    "publisher.extension-name"           # Open VSX 扩展
    "https://example.com/extension.vsix"  # vsix 直链
    # 添加你需要的扩展...
)
```

## 配置说明

### config.yaml

位置：`~/.config/code-server/config.yaml`

**有密码模式**（安装时输入了密码）：

```yaml
bind-addr: 127.0.0.1:8443   # 锁定回环地址
auth: password               # 密码认证
password: <你的密码>          # 安装时输入
cert: true                   # 自动托管自签名证书
```

**无密码模式**（安装时留空跳过）：

```yaml
bind-addr: 127.0.0.1:8443   # 锁定回环地址
auth: none                   # 无认证
cert: true                   # 自动托管自签名证书
```

> `bind-addr` 已锁定 `127.0.0.1`，仅本地可访问，无密码模式在安全性上可接受。

修改配置后，重启服务生效：

```bash
bash install.sh restart
```

### rewrite-android2linux.js

位置：`~/.config/code-server/rewrite-android2linux.js`

将 `process.platform` 重写为 `"linux"`，解决 Android 平台兼容问题。通过 `NODE_OPTIONS="--require"` 在启动时注入。

## 日志与调试

### 查看运行日志

```bash
# 服务运行日志（stdout/stderr）
tail -f ~/.local/share/code-server/current

# 退出状态日志（每次退出都会记录）
cat ~/.local/share/code-server/exit.log
```

### 手动启动排查

如果服务无法启动，可以手动运行查看详细错误：

```bash
NODE_OPTIONS="--require $HOME/.config/code-server/rewrite-android2linux.js" \
  code-server \
    --app-name "Visual Studio Code" \
    --bind-addr 127.0.0.1:8443 \
    --cert \
    --config ~/.config/code-server/config.yaml
```

### 常见问题

| 问题 | 解决 |
|------|------|
| `sv: command not found` | 重启 Termux（termux-services 首次安装后必须重启） |
| 连接被拒绝 | 确认服务已启动：`bash install.sh status` |
| code-server 崩溃 | 查看退出日志：`cat ~/.local/share/code-server/exit.log` |
| 忘记密码 | 查看 `~/.config/code-server/config.yaml` 或删除后重新运行 `bash install.sh` |
| pkg 找不到 `code-server` 包 | 已自动回退到 GitHub 预编译二进制，无需手动操作 |
| 下载 GitHub 失败（网络问题） | 手动下载：`curl -fsSL https://github.com/coder/code-server/releases/latest/download/code-server-linux-arm64.tar.gz \| tar -xz -C $PREFIX/lib/code-server --strip-components=1`，然后 `ln -s $PREFIX/lib/code-server/bin/code-server $PREFIX/bin/code-server` |
| 扩展安装失败 | 手动安装：`code-server --install-extension <id>` |

## 卸载

```bash
bash install.sh uninstall    # 清理服务和配置
pkg uninstall code-server    # 卸载 code-server 本体
```

## License

MIT（与项目主体一致）
