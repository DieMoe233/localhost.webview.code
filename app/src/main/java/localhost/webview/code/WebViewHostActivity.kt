package localhost.webview.code

import android.annotation.SuppressLint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.addCallback
import androidx.appcompat.app.AppCompatActivity

/**
 * 子窗口宿主 —— 从 [WebViewCache] 获取 [MainActivity.onCreateWindow] 中同步创建的 WebView，
 * 将其移入自己的视图树，并提供最小化的窗口控制。
 *
 * 所有窗口初始化参数通过 Intent 传递，无 DEFAULT_URL 硬编码兜底：
 *   - intent.getStringExtra(CACHE_ID) → WebViewCache 缓存 ID
 */
class WebViewHostActivity : AppCompatActivity() {

    companion object {
        const val CACHE_ID = "webview_cache_id"
    }

    private var webView: WebView? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            // Ctrl+Shift+W → 关闭当前窗口
            if (event.isCtrlPressed && event.isShiftPressed && event.keyCode == KeyEvent.KEYCODE_W) {
                closeWindow()
                return true
            }
            // ESC → 转发给 WebView
            if (event.keyCode == KeyEvent.KEYCODE_ESCAPE) {
                webView?.dispatchKeyEvent(event)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_webview_host)

        val cacheId = intent.getStringExtra(CACHE_ID) ?: run {
            finish()
            return
        }

        val wv = WebViewCache.take(cacheId) ?: run {
            finish()
            return
        }

        webView = wv

        // 从临时父视图移除，加入当前布局
        (wv.parent as? ViewGroup)?.removeView(wv)
        findViewById<ViewGroup>(R.id.webViewContainer).addView(
            wv,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        // 返回键：先尝试 ESC（关闭 Panel/补全），若 DOM 中无 focus 再提示关闭
        onBackPressedDispatcher.addCallback(this) {
            wv.evaluateJavascript("""
                (function(){
                    var ae = document.activeElement;
                    // 派发 ESC 到当前焦点元素
                    var down = new KeyboardEvent('keydown', {key:'Escape',keyCode:27,code:'Escape',which:27,bubbles:true,cancelable:true});
                    var up   = new KeyboardEvent('keyup',   {key:'Escape',keyCode:27,code:'Escape',which:27,bubbles:true,cancelable:true});
                    (ae||document).dispatchEvent(down);
                    (ae||document).dispatchEvent(up);
                })();
            """.trimIndent(), null)
        }
    }

    /**
     * 通知 code-server 窗口关闭，然后销毁 Activity。
     *
     * 关键：必须先通过 JS 触发 window.close() 和 beforeunload 事件，
     * 让 code-server 更新会话状态。直接 finish() 会导致 code-server 认为窗口仍在使用。
     */
    private fun closeWindow() {
        val wv = webView ?: run {
            finish()
            return
        }

        // 通知 code-server：触发 beforeunload → window.close → 清理
        wv.evaluateJavascript("""
            (function(){
                window.dispatchEvent(new Event('beforeunload', {cancelable:true}));
                try { window.close(); } catch(e) {}
            })();
        """.trimIndent(), null)

        // 给 JS 事件处理留出时间，然后销毁
        handler.postDelayed({
            finish()
        }, 150)
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing) {
            handler.removeCallbacksAndMessages(null)
            webView?.destroy()
            webView = null
        }
    }
}
