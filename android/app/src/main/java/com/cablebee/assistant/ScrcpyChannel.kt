package com.cablebee.assistant

import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.CoroutineScope

/**
 * ScrcpyChannel — 把 ScrcpySession 暴露给 Flutter
 *
 * MethodChannel  "com.cablebee.assistant/scrcpy"
 *   start        { serial, maxSize, bitRate, maxFps } → textureId (Long)
 *   stop         {} → null
 *   touch        { action, pointerId, x, y } → null
 *   scroll       { x, y, hScroll, vScroll } → null
 *   keycode      { action, keycode } → null
 *   back         {} → null
 *
 * EventChannel   "com.cablebee.assistant/scrcpy_events"
 *   推送 Map<String,Any?> 事件：
 *     { type: "status",    msg: String }
 *     { type: "connected", deviceName, deviceWidth, deviceHeight }
 *     { type: "error",     message: String }
 *     { type: "stopped" }
 */
class ScrcpyChannel(
    private val textureRegistry: TextureRegistry,
    private val scope: CoroutineScope,
) {
    companion object {
        const val METHOD_CHANNEL = "com.cablebee.assistant/scrcpy"
        const val EVENT_CHANNEL  = "com.cablebee.assistant/scrcpy_events"
        private const val TAG = "ScrcpyChannel"
    }

    private var session: ScrcpySession? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var eventSink: EventChannel.EventSink? = null

    // ── MethodChannel handler ─────────────────────────────────────────────────

    val methodHandler = MethodChannel.MethodCallHandler { call, result ->
        when (call.method) {

            "start" -> {
                val serial  = call.argument<String>("serial")  ?: ""
                val maxSize = call.argument<Int>("maxSize")    ?: 1080
                val bitRate = call.argument<Int>("bitRate")    ?: 8_000_000
                val maxFps  = call.argument<Int>("maxFps")     ?: 30

                // 停止旧会话
                session?.stop()
                textureEntry?.release()

                // 创建 Flutter Texture
                val entry = textureRegistry.createSurfaceTexture()
                textureEntry = entry
                val textureId = entry.id()

                // 先把 textureId 返回给 Flutter
                result.success(textureId)

                // Flutter 侧已完成 push/forward/server 启动，直接连接
                session = ScrcpySession(entry) { type, data ->
                    sendEvent(mapOf("type" to type) + data)
                }.also { it.connect() }
            }

            "stop" -> {
                session?.stop()
                session = null
                textureEntry?.release()
                textureEntry = null
                result.success(null)
            }

            "touch" -> {
                val action    = call.argument<Int>("action")    ?: 0
                val pointerId = call.argument<Int>("pointerId") ?: 0
                val x         = call.argument<Int>("x")        ?: 0
                val y         = call.argument<Int>("y")        ?: 0
                val w         = call.argument<Int>("w")        ?: 1080
                val h         = call.argument<Int>("h")        ?: 1920
                val pressure  = call.argument<Double>("pressure")?.toFloat() ?: 1f
                session?.sendTouch(action, pointerId.toLong(), x, y, w, h, pressure)
                result.success(null)
            }

            "scroll" -> {
                val x       = call.argument<Int>("x")       ?: 0
                val y       = call.argument<Int>("y")       ?: 0
                val w       = call.argument<Int>("w")       ?: 1080
                val h       = call.argument<Int>("h")       ?: 1920
                val hScroll = call.argument<Int>("hScroll") ?: 0
                val vScroll = call.argument<Int>("vScroll") ?: 0
                session?.sendScroll(x, y, w, h, hScroll, vScroll)
                result.success(null)
            }

            "keycode" -> {
                val action  = call.argument<Int>("action")  ?: 0
                val keycode = call.argument<Int>("keycode") ?: 0
                session?.sendKeycode(action, keycode)
                result.success(null)
            }

            "back" -> {
                session?.sendBackOrScreenOn()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ── EventChannel handler ──────────────────────────────────────────────────

    val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
            eventSink = sink
        }
        override fun onCancel(arguments: Any?) {
            eventSink = null
        }
    }

    // ── 内部工具 ──────────────────────────────────────────────────────────────

    private fun sendEvent(data: Map<String, Any?>) {
        // EventSink 必须在主线程调用
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try { eventSink?.success(data) }
            catch (e: Exception) { Log.e(TAG, "sendEvent failed", e) }
        }
    }
}
