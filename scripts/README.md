# code-server Termux 部署指南

**中文** | [English](README.en.md)

为 [`localhost.webview.code`](../) Android WebView 应用配套的 code-server 部署方案。

## 概述

本脚本在 Android 设备的 **Termux** 环境中一键部署 code-server，通过 `termux-services`（runit）管理服务生命周期和开机自启。安装后注册 `code` 快捷指令，支持安装、更新、卸载、模式切换等全部操作。

### 架构

```
Android 设备
├── Termux
│   ├── code-server (127.0.0.1:8443)
│   │   ├── 自签名证书（自动托管）
│   │   ├── 默认 Linux 模式（process.platform polyfill）
│   │   └── termux-services (runit)
│   │       ├── sv up/down       # 启动/停止
│   │       ├── sv status        # 状态
│   │       └── sv-enable        # 自启
│   ├── ~/.config/code-server/
│   │   ├── config.yaml
│   │   └── rewrite-android2linux.js
│   └── $PREFIX/bin/code          # 快捷指令
└── localhost.webview.code (WebView 应用)
    └── https://localhost:8443/
```

### 关键设计

| 决策 | 原因 |
|------|------|
| `127.0.0.1:8443` 绑定 | 仅本地访问，防止局域网不安全连接 |
| `--cert`（不传参） | code-server 自动生成和管理自签名证书 |
| 默认 Linux 模式 | 开箱即用，绝大多数扩展可正常工作 |
| Android 模式可选 | Live Share 等少数扩展需要原生 Android 平台 |
| 市场切换（安装时） | Live Share 等需从 VS Code 官方市场安装，安装完恢复 Open VSX |
| 安装后自动启动 + 自启 | 无需手动操作，部署完成即可连接 |

## 快速开始

### 前置条件

1. 安装 [Termux](https://f-droid.org/packages/com.termux/)（**F-Droid 版本**，Google Play 版本已停更）
2. （可选）安装 [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) 用于系统级开机自启

### 一键部署

```bash
curl -fsSLo install.sh https://touhou.diemoe.net/usr/termux/code-server/install.sh && bash install.sh
```

脚本会依次完成：
- 安装依赖（`termux-services`、`openssl-tool`、`git`、`nodejs`）
- 安装 `code-server`（tur-repo）
- 创建 `process.platform` polyfill
- 交互式设置访问密码
- 创建 `config.yaml` 和 runit 服务
- 安装预置扩展（Live Share、Copilot Chat、中文语言包、SSH FS）
- 注册 `code` 快捷指令
- 自动启动服务并启用自启

安装完成后直接打开 `https://127.0.0.1:8443` 即可使用。

## 快捷指令

安装后可用 `code` 替代 `bash install.sh`：

```bash
code start       # 启动服务
code stop        # 停止服务
code restart     # 重启服务
code status      # 查看状态
code enable      # 启用自启
code disable     # 禁用自启
code update      # 更新 code-server
code reinstall   # 强制重装
code uninstall   # 卸载（含询问是否彻底删除本体）

# 扩展管理
code extension install <ID>     # 安装扩展
code extension list             # 列出已安装
code extension uninstall <ID>   # 卸载扩展

# 模式切换
code linux       # 切换至 Linux 模式（默认）
code android     # 切换至 Android 模式（Live Share 需要）
```

## 预装扩展

安装时分两个阶段进行：

### 第一阶段：VS Code 官方市场

code-server 默认使用 Open VSX 市场，但部分扩展（Live Share、GitHub Copilot Chat）仅在此市场可用。安装时脚本自动切换 `product.json` → 安装 → 恢复。

| 扩展 | ID |
|------|-----|
| VS Live Share | `ms-vsliveshare.vsliveshare@1.0.5936` |
| GitHub Copilot Chat | `GitHub.copilot-chat` |

### 第二阶段：Open VSX

code-server 默认市场，大部分扩展可直接安装。

| 扩展 | ID |
|------|-----|
| 中文语言包 | `MS-CEINTL.vscode-language-pack-zh-hans` |
| SSH FS | `Kelvin.vscode-sshfs` |

### 安装额外扩展

```bash
# 建议先切到 Linux 模式以确保不受平台检查限制：
code linux

# 然后安装：
code extension install <扩展ID>

# 如果不需要 Live Share，保持 Linux 模式即可
# 如果需要 Live Share，安装完切回 Android：
code android
```

## 模式切换

### Linux 模式（默认）

```bash
code linux
```

- `process.platform` → `"linux"`（通过 polyfill）
- 绝大多数扩展可正常安装和使用
- **默认模式**，开箱即用

### Android 模式

```bash
code android
```

- `process.platform` → `"android"`（原生值）
- **Live Share 需要此模式才能运行**

> ⚠ Live Share 内部逻辑依赖原生 `process.platform`，必须在 Android 模式下使用。

## 配置说明

### config.yaml

位置：`~/.config/code-server/config.yaml`

**有密码模式**（安装时输入了密码）：

```yaml
bind-addr: 127.0.0.1:8443
auth: password
password: <你的密码>
cert: true
```

**无密码模式**（安装时留空跳过）：

```yaml
bind-addr: 127.0.0.1:8443
auth: none
cert: true
```

> `bind-addr` 已锁定 `127.0.0.1`，仅本地可访问，无密码模式在安全性上可接受。

修改配置后重启服务生效：`code restart`

### rewrite-android2linux.js

位置：`~/.config/code-server/rewrite-android2linux.js`

将 `process.platform` 重写为 `"linux"`，解决 Android 平台兼容问题。Linux 模式下通过 `NODE_OPTIONS="--require"` 在启动时注入，安装扩展时也会自动使用。

## 日志与调试

### 查看运行日志

```bash
# 服务运行日志（stdout/stderr）
tail -f ~/.local/share/code-server/current

# 退出状态日志（每次退出都会记录）
cat ~/.local/share/code-server/exit.log
```

### 手动启动排查

```bash
# Linux 模式
NODE_OPTIONS="--require $HOME/.config/code-server/rewrite-android2linux.js" \
  code-server --bind-addr 127.0.0.1:8443 --cert

# Android 模式
code-server --bind-addr 127.0.0.1:8443 --cert
```

### 常见问题

| 问题 | 解决 |
|------|------|
| `sv: command not found` | 安装后自动可用，无需重启。如仍不可用：`source $PREFIX/etc/profile.d/termux-services.sh` |
| 连接被拒绝 | 检查服务状态：`code status` |
| code-server 反复重启 | 查看日志：`tail -f ~/.local/share/code-server/current` |
| Live Share 无法使用 | 确认已切 Android 模式：`code android` |
| 扩展安装被平台检查拦截 | 切 Linux 模式后安装：`code linux && code extension install <ID>` |
| 忘记密码 | 查看 `~/.config/code-server/config.yaml` 或删除后重新运行 `code install` |
| 已安装时运行 install | 会显示帮助而不会重复安装，用 `code reinstall` 强制重装 |

## 卸载

```bash
code uninstall
```

运行时会询问是否彻底卸载 code-server 本体：
- 选 `y` → 连带 `pkg uninstall code-server` + 删除 `$PREFIX/bin/code`
- 选 `n` → 仅清理配置和服务，保留本体（可 `pkg uninstall code-server` 手动清理）
