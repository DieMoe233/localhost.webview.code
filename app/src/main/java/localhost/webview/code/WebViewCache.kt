package localhost.webview.code

import android.webkit.WebView
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Application 级 WebView 缓存 —— 桥接 [MainActivity.onCreateWindow] 中同步创建的 WebView
 * 和 [WebViewHostActivity] 中的异步渲染。
 *
 * 流程：
 * 1. MainActivity.onCreateWindow 创建 WebView → put(webView) 获得缓存 ID
 * 2. WebViewHostActivity 通过 Intent 接收缓存 ID → take(cacheId) 取出 ←→ removeView 移动
 */
object WebViewCache {

    private val cache = ConcurrentHashMap<String, WebView>()

    /**
     * 存入 WebView，返回唯一缓存 ID。
     * 此 ID 通过 Intent 传递给 [WebViewHostActivity]。
     */
    fun put(webView: WebView): String {
        val id = UUID.randomUUID().toString()
        cache[id] = webView
        return id
    }

    /**
     * 取出并移除 WebView。取出后缓存即清空，保证一次消费。
     */
    fun take(id: String): WebView? {
        return cache.remove(id)
    }
}
