# code-server Termux Deployment Guide

[中文](README.md) | **English**

For the [`localhost.webview.code`](../) Android WebView companion app.

## Overview

This script deploys code-server with one command in the **Termux** environment on Android, using `termux-services` (runit) for lifecycle management and auto-start. After installation, a `code` shortcut is registered for all operations: install, update, uninstall, and mode switching.

### Architecture

```
Android Device
├── Termux
│   ├── code-server (127.0.0.1:8443)
│   │   ├── Self-signed certificate (auto-managed)
│   │   ├── Default Linux mode (process.platform polyfill)
│   │   └── termux-services (runit)
│   │       ├── sv up/down       # Start/Stop
│   │       ├── sv status        # Status
│   │       └── sv-enable        # Auto-start
│   ├── ~/.config/code-server/
│   │   ├── config.yaml
│   │   └── rewrite-android2linux.js
│   └── $PREFIX/bin/code          # Shortcut command
└── localhost.webview.code (WebView app)
    └── https://localhost:8443/
```

### Key Design Decisions

| Decision | Reason |
|------|------|
| `127.0.0.1:8443` binding | Local-only access, prevents insecure LAN connections |
| `--cert` (no args) | code-server auto-generates and manages self-signed certs |
| Default Linux mode | Works out of the box for most extensions |
| Optional Android mode | Required by Live Share and a few extensions needing native platform |
| Marketplace switching (install-time) | Live Share etc. must be installed from VS Code Marketplace, then restored to Open VSX |
| Auto-start after install | Zero manual steps — ready to connect immediately after deployment |

## Quick Start

### Prerequisites

1. Install [Termux](https://f-droid.org/packages/com.termux/) (**F-Droid version**; Google Play version is outdated)
2. (Optional) Install [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) for system-level auto-start on boot

### One-Command Deploy

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/DieMoe233/localhost.webview.code/refs/heads/master/scripts/install.en.sh && bash install.sh
```

The script performs these steps:
- Installs dependencies (`termux-services`, `openssl-tool`, `git`, `nodejs`)
- Installs `code-server` (tur-repo)
- Creates the `process.platform` polyfill
- Interactive password setup
- Creates `config.yaml` and runit service
- Installs preloaded extensions (Live Share, Copilot Chat, Chinese language pack, SSH FS)
- Registers the `code` shortcut
- Auto-starts the service and enables auto-start

Open `https://127.0.0.1:8443` after installation to start using.

## Shortcut Commands

After installation, use `code` instead of `bash install.sh`:

```bash
code start       # Start service
code stop        # Stop service
code restart     # Restart service
code status      # View status
code enable      # Enable auto-start
code disable     # Disable auto-start
code update      # Update code-server
code reinstall   # Force reinstall
code uninstall   # Uninstall (prompts for full removal)

# Extension management
code extension install <ID>     # Install extension
code extension list             # List installed
code extension uninstall <ID>   # Uninstall extension

# Mode switching
code linux       # Switch to Linux mode (default)
code android     # Switch to Android mode (required by Live Share)
```

## Preloaded Extensions

Installed in two phases:

### Phase 1: VS Code Marketplace

code-server defaults to Open VSX, but some extensions (Live Share, GitHub Copilot Chat) are only available on the VS Code Marketplace. The script temporarily switches `product.json` → installs → restores.

| Extension | ID |
|------|-----|
| VS Live Share | `ms-vsliveshare.vsliveshare@1.0.5936` |
| GitHub Copilot Chat | `GitHub.copilot-chat` |

### Phase 2: Open VSX

The default marketplace for code-server. Most extensions can be installed directly.

| Extension | ID |
|------|-----|
| Chinese Language Pack | `MS-CEINTL.vscode-language-pack-zh-hans` |
| SSH FS | `Kelvin.vscode-sshfs` |

### Installing Additional Extensions

```bash
# Switch to Linux mode first to bypass platform checks:
code linux

# Then install:
code extension install <extension-id>

# Switch back to Android mode or keep Linux mode:
code android
```

## Mode Switching

### Linux Mode (Default)

```bash
code linux
```

- `process.platform` → `"linux"` (via polyfill)
- Most extensions install and work normally
- **Default mode**, works out of the box

### Android Mode

```bash
code android
```

- `process.platform` → `"android"` (native value)
- Use when native platform detection is required



## Configuration

### config.yaml

Location: `~/.config/code-server/config.yaml`

**With password** (entered during installation):

```yaml
bind-addr: 127.0.0.1:8443
auth: password
password: <your-password>
cert: true
```

**Without password** (skipped during installation):

```yaml
bind-addr: 127.0.0.1:8443
auth: none
cert: true
```

> `bind-addr` is locked to `127.0.0.1` — local-only access. Passwordless mode is acceptable for this setup.

Restart the service after changing config: `code restart`

### rewrite-android2linux.js

Location: `~/.config/code-server/rewrite-android2linux.js`

Rewrites `process.platform` to `"linux"` to resolve Android platform compatibility issues. Injected via `NODE_OPTIONS="--require"` at startup in Linux mode, and automatically used during extension installation.

## Logs & Debugging

### Viewing Logs

```bash
# Service runtime logs (stdout/stderr)
tail -f ~/.local/share/code-server/current

# Exit status logs (recorded on each exit)
cat ~/.local/share/code-server/exit.log
```

### Manual Startup for Troubleshooting

```bash
# Linux mode
NODE_OPTIONS="--require $HOME/.config/code-server/rewrite-android2linux.js" \
  code-server --bind-addr 127.0.0.1:8443 --cert

# Android mode
code-server --bind-addr 127.0.0.1:8443 --cert
```

### FAQ

| Issue | Solution |
|------|------|
| `sv: command not found` | Available immediately after install. If not: `source $PREFIX/etc/profile.d/termux-services.sh` |
| Connection refused | Check service status: `code status` |
| code-server keeps restarting | View logs: `tail -f ~/.local/share/code-server/current` |
| Live Share not working | Ensure Live Share extension is installed; code-server 4.125.0+ supports Linux mode |
| Extension install blocked by platform check | Switch to Linux mode first: `code linux && code extension install <ID>` |
| Forgot password | View `~/.config/code-server/config.yaml` or delete it and run `code install` |
| Running install when already installed | Shows help instead of reinstalling; use `code reinstall` to force |

## Uninstall

```bash
code uninstall
```

Prompts whether to fully remove code-server:
- `y` → Runs `pkg uninstall code-server` + removes `$PREFIX/bin/code`
- `n` → Removes only config and service, keeps the binary (can be removed later with `pkg uninstall code-server`)
