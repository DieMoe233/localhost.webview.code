package localhost.webview.code

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.view.KeyEvent
import androidx.activity.addCallback
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import android.content.Context
import android.net.http.SslError
import android.webkit.JavascriptInterface
import android.os.Bundle
import android.os.Message
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.PermissionRequest
import android.webkit.WebResourceRequest
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import localhost.webview.code.databinding.ActivityMainBinding

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    // 全局快捷键拦截
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && ::binding.isInitialized) {
            // Ctrl+Shift+W → 关闭当前窗口
            if (event.isCtrlPressed && event.isShiftPressed && event.keyCode == KeyEvent.KEYCODE_W) {
                finish()
                return true
            }
            // ESC → 转发给 WebView
            if (event.keyCode == KeyEvent.KEYCODE_ESCAPE) {
                binding.webView.dispatchKeyEvent(event)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // 隐藏状态栏，导航栏不遮挡 WebView 内容
        hideSystemBars()
        applyWindowInsets()

        setupWebView(binding.webView)

        val url = resolveFileUrl(intent)
        binding.webView.loadUrl(url)

        // 将返回键作为 ESC 发送给 WebView（系统把 ESC 转成了返回键）
        onBackPressedDispatcher.addCallback(this) {
            binding.webView.evaluateJavascript("""
                (function(){
                    var down = new KeyboardEvent('keydown', {key:'Escape',keyCode:27,code:'Escape',which:27,bubbles:true,cancelable:true});
                    var up   = new KeyboardEvent('keyup',   {key:'Escape',keyCode:27,code:'Escape',which:27,bubbles:true,cancelable:true});
                    (document.activeElement||document).dispatchEvent(down);
                    (document.activeElement||document).dispatchEvent(up);
                })();
            """.trimIndent(), null)
        }
    }

    // 将外部文件管理器传来的文件 URI 转换为 code-server 可打开的文件夹 URL
    private fun resolveFileUrl(intent: Intent?): String {
        val data = intent?.data ?: return DEFAULT_URL
        val scheme = data.scheme ?: return DEFAULT_URL

        // http/https URL 直接使用
        if (scheme == "http" || scheme == "https") return data.toString()

        // 尝试提取文件路径
        val path = when (scheme) {
            "file" -> data.path
            "content" -> resolveContentUri(data)
            else -> null
        }

        if (path == null) return DEFAULT_URL

        // code-server 打开文件所在文件夹
        val file = File(path)
        val folder = if (file.isDirectory) file.absolutePath else file.parentFile?.absolutePath
        return if (folder != null) "https://localhost:8443/?folder=$folder" else DEFAULT_URL
    }

    // 将 content:// URI 解析为文件系统路径
    private fun resolveContentUri(uri: Uri): String? {
        // 尝试直接通过 _data 列获取
        contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex("_data")
                if (idx >= 0) return cursor.getString(idx)
            }
        }
        // 回退：尝试 DISPLAY_NAME（无法获取完整路径时返回 null）
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIdx >= 0) {
                    val name = cursor.getString(nameIdx)
                    // 构造一个临时缓存路径
                    val cacheFile = File(cacheDir, name)
                    contentResolver.openInputStream(uri)?.use { input ->
                        cacheFile.outputStream().use { output -> input.copyTo(output) }
                        return cacheFile.absolutePath
                    }
                }
            }
        }
        return null
    }

    // 隐藏状态栏（全屏），手势下滑可临时唤出
    private fun hideSystemBars() {
        // 窗口化模式（分屏 / 自由窗口 / DeX）下不隐藏，否则会与窗口标题栏叠加
        if (isInMultiWindowMode) return
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, binding.root)
        controller.hide(WindowInsetsCompat.Type.statusBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    // 导航栏不遮挡 WebView 底部内容
    private fun applyWindowInsets() {
        // 窗口化模式下系统会自动处理内边距，不需要手动设置
        if (isInMultiWindowMode) return
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val navBar = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
            view.setPadding(
                view.paddingLeft,
                view.paddingTop,
                view.paddingRight,
                navBar.bottom
            )
            insets
        }
    }

    companion object {
        private const val DEFAULT_URL = "https://localhost:8443/"
    }

    // 原生剪贴板桥 —— 绕过 Android WebView 中 navigator.clipboard.readText() 静默失败的问题
    inner class ClipboardBridge {
        @JavascriptInterface
        fun read(): String {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip ?: return ""
            if (clip.itemCount == 0) return ""
            return clip.getItemAt(0).coerceToText(this@MainActivity).toString()
        }

        @JavascriptInterface
        fun write(text: String) {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("", text))
        }
    }

    @SuppressLint("WebViewApiAvailability")
    private fun setupWebView(webView: WebView) {
        with(webView.settings) {
            // 启用 JavaScript
            javaScriptEnabled = true

            // 启用 DOM 存储（localStorage / sessionStorage）
            domStorageEnabled = true

            // 允许混合内容（HTTP + HTTPS）
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW

            // 允许文件访问（部分 Web 应用需要）
            allowFileAccess = true

            // 视口支持
            useWideViewPort = true
            loadWithOverviewMode = true

            // 缩放控制
            builtInZoomControls = true
            displayZoomControls = false

            // 缓存模式
            cacheMode = WebSettings.LOAD_DEFAULT

            // 允许 JS 打开新窗口（code-server New Window 依赖）
            javaScriptCanOpenWindowsAutomatically = true
            @Suppress("DEPRECATION")
            setSupportMultipleWindows(true)
        }

        // 注册原生剪贴板桥
        webView.addJavascriptInterface(ClipboardBridge(), "_clipboardNative")

        webView.webViewClient = object : WebViewClient() {

            // 外部链接（非 localhost:8443）用系统浏览器打开
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                val uri = request?.url ?: return false
                val host = uri.host ?: return false
                val port = if (uri.port != -1) uri.port else if (uri.scheme == "https") 443 else 80

                // localhost:8443 留在 WebView 内，其他用浏览器
                if (host == "localhost" && port == 8443) {
                    return false
                }

                try {
                    view?.context?.startActivity(
                        Intent(Intent.ACTION_VIEW, uri).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                    )
                } catch (_: Exception) { }
                return true
            }

            // 忽略 SSL 证书错误（适用于 localhost 自签名证书）
            override fun onReceivedSslError(
                view: WebView?,
                handler: SslErrorHandler,
                error: SslError?
            ) {
                handler.proceed()
            }

            // 每次页面加载完成后注入剪贴板补丁
            override fun onPageFinished(view: WebView?, url: String?) {
                view?.evaluateJavascript("""
                    (function(){
                        if (window.__clipPatched) return;
                        window.__clipPatched = true;
                        var origRead = navigator.clipboard.readText;
                        navigator.clipboard.readText = function(){
                            try { return Promise.resolve(_clipboardNative.read()); }
                            catch(e) { return origRead.call(navigator.clipboard); }
                        };
                        var origWrite = navigator.clipboard.writeText;
                        navigator.clipboard.writeText = function(t){
                            try { _clipboardNative.write(t); return Promise.resolve(); }
                            catch(e) { return origWrite.call(navigator.clipboard, t); }
                        };
                    })();
                """.trimIndent(), null)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {

            // 授予剪贴板、摄像头、麦克风等权限
            override fun onPermissionRequest(request: PermissionRequest?) {
                request?.grant(request.resources)
            }

            // 拦截新窗口（target="_blank" / window.open），用系统浏览器打开
            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message?
            ): Boolean {
                val context = view?.context ?: return false

                // 尝试直接从 hitTestResult 获取 URL（适用于点击链接的场景）
                val hitTestUrl = view.hitTestResult.extra
                if (hitTestUrl != null) {
                    openUrl(context, hitTestUrl)
                    return false
                }

                // 弹窗（window.open）场景：创建临时 WebView 捕获目标 URL
                val tempWebView = WebView(context).apply {
                    webViewClient = object : WebViewClient() {
                        override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                            openUrl(context, url)
                            view?.stopLoading()
                        }

                        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                            openUrl(context, request?.url?.toString())
                            return true
                        }
                    }
                }
                (resultMsg?.obj as? WebView.WebViewTransport)?.webView = tempWebView
                resultMsg?.sendToTarget()
                return true
            }

            // localhost:8443 → 新应用实例；其他 → 系统浏览器
            private fun openUrl(context: android.content.Context, url: String?) {
                if (url == null) return
                val uri = Uri.parse(url)

                if (uri.host == "localhost" && uri.port == 8443) {
                    // code-server 新窗口 → 启动新 MainActivity 实例
                    context.startActivity(
                        Intent(context, MainActivity::class.java).apply {
                            data = uri
                            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                        }
                    )
                } else {
                    // 外部链接 → 系统浏览器
                    try {
                        context.startActivity(
                            Intent(Intent.ACTION_VIEW, uri).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                    } catch (_: Exception) { }
                }
            }
        }
    }
}