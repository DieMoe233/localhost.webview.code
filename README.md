# code-server WebView Shell

一个 Android WebView 壳应用，全屏加载 `https://localhost:8443/`（code-server），让平板/手机变身移动 IDE。

## 特性

- **全屏 WebView**：无 ActionBar，无状态栏，最大化可用空间
- **多窗口支持**：分屏、自由窗口，taskbar 独立实例
- **code-server New Window**：菜单点「新建窗口」自动打开新应用实例
- **外部链接拦截**：弹出窗口/外部域名自动跳转系统浏览器
- **ESC 键支持**：系统返回键 / 硬件 ESC → WebView，终端面板正常关闭
- **剪贴板权限**：自动授予，code-server 内可正常复制粘贴
- **文件关联**：外部文件管理器可选择「用 VS Code 打开」
- **自签名证书**：`localhost` HTTPS 自签名证书自动信任
- **VS Code 图标**：透明背景矢量图标，多密度适配

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| Ctrl+Shift+W | 关闭当前窗口 |
| ESC / 返回键 | 转发给 WebView（关闭面板/取消补全） |

## 构建

### 环境要求

- JDK 17+
- Android SDK（API 24+，Build Tools 34+）

### 环境变量

```powershell
# Windows PowerShell（按实际路径调整）
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
```

```bash
# macOS / Linux
export JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
```

### 命令

```bash
./gradlew assembleDebug
```

APK 生成在 `app/build/outputs/apk/debug/app-debug.apk`。

### 首次构建

项目自带 Gradle Wrapper，无需手动安装 Gradle。Windows 用 `gradlew.bat`，macOS/Linux 用 `gradlew`。

## 配置

### 修改目标 URL

编辑 `app/src/main/java/localhost/webview/code/MainActivity.kt`：

```kotlin
companion object {
    private const val DEFAULT_URL = "https://localhost:8443/"
}
```

### 修改应用名

编辑 `app/src/main/res/values/strings.xml`：

```xml
<string name="app_name">Visual Studio Code</string>
```

### 修改图标

替换 `app/src/main/res/mipmap-*/ic_launcher.png`（5 个密度），1024×1024 源图会自动缩放适配。

## 项目结构

```
├── app/
│   ├── build.gradle.kts          # 模块构建配置 (API 26+)
│   ├── proguard-rules.pro
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/localhost/webview/code/
│       │   └── MainActivity.kt   # 唯一 Activity
│       └── res/
│           ├── layout/activity_main.xml
│           ├── xml/network_security_config.xml
│           ├── drawable/          # 自适应图标
│           ├── mipmap-*/          # 多密度启动图标
│           └── values/            # strings, colors, themes
├── build.gradle.kts              # 项目级构建
├── settings.gradle.kts
├── gradle.properties
├── gradle/wrapper/
└── gradlew / gradlew.bat
```

## License

MIT
