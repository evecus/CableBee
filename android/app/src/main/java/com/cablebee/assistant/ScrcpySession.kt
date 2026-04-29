package com.cablebee.assistant

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * ScrcpySession — 只负责 socket 连接 + MediaCodec 解码 + 控制发送
 * push/forward/startServer 全部由 Flutter 侧通过 AdbService 完成
 */
class ScrcpySession(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val onEvent: (String, Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "ScrcpySession"
        private const val SCRCPY_PORT = 5005

        const val TYPE_INJECT_KEYCODE = 0
        const val TYPE_INJECT_TOUCH   = 2
        const val TYPE_INJECT_SCROLL  = 3
        const val TYPE_BACK_OR_SCREEN = 4
    }

    @Volatile private var running = false

    private var videoSocket:   Socket? = null
    private var controlSocket: Socket? = null
    private var controlOut:    OutputStream? = null
    private var codec:         MediaCodec? = null
    private var surface:       Surface? = null
    private var decodeThread:  Thread? = null

    var deviceWidth:  Int = 0; private set
    var deviceHeight: Int = 0; private set

    // ── 连接（push/forward/server 已由 Flutter 完成）─────────────────────────

    fun connect() {
        if (running) return
        running = true
        Thread {
            try { _connect() }
            catch (e: Exception) {
                Log.e(TAG, "connect failed", e)
                onEvent("error", mapOf("message" to (e.message ?: "连接失败")))
                stop()
            }
        }.also { it.isDaemon = true; it.name = "scrcpy-connect" }.start()
    }

    private fun _connect() {
        // 连接 video socket
        onEvent("status", mapOf("msg" to "连接中..."))
        var attempt = 0
        while (attempt < 30 && running) {
            try {
                videoSocket = Socket("127.0.0.1", SCRCPY_PORT)
                break
            } catch (e: IOException) {
                attempt++
                Log.w(TAG, "connect attempt $attempt: ${e.message}")
                onEvent("status", mapOf("msg" to "连接中... ($attempt/30)"))
                Thread.sleep(300)
            }
        }
        val vSock = videoSocket
            ?: throw IOException("无法连接 scrcpy server，请检查设备 ADB 授权")

        // 连接 control socket
        controlSocket = Socket("127.0.0.1", SCRCPY_PORT)
        controlOut = controlSocket!!.getOutputStream()

        // 先读64字节设备名
        val videoIn = vSock.getInputStream()
        val nameBuf = videoIn.readExactly(64)
        if (nameBuf.size < 64) throw IOException("设备名数据不足：${nameBuf.size}/64")
        val deviceName = String(nameBuf, 0, 64).trimEnd('\u0000')

        // 读剩余字节，尝试不同格式
        // 读5字节（够2+2+1或4+1）
        val rest = videoIn.readExactly(5)
        Log.d(TAG, "rest bytes: ${rest.map { it.toInt() and 0xFF }}")

        // 尝试 short+short（scrcpy 1.x早期格式）
        deviceWidth  = ((rest[0].toInt() and 0xFF) shl 8) or (rest[1].toInt() and 0xFF)
        deviceHeight = ((rest[2].toInt() and 0xFF) shl 8) or (rest[3].toInt() and 0xFF)
        Log.i(TAG, "connected: $deviceName ${deviceWidth}x${deviceHeight}")

        onEvent("connected", mapOf(
            "deviceName"   to deviceName,
            "deviceWidth"  to deviceWidth,
            "deviceHeight" to deviceHeight,
        ))

        initDecoder()
        startDecode(videoIn)
    }

    // ── MediaCodec 解码 ──────────────────────────────────────────────────────

    private fun initDecoder() {
        val st = textureEntry.surfaceTexture()
        st.setDefaultBufferSize(deviceWidth, deviceHeight)
        surface = Surface(st)
        codec = MediaCodec.createDecoderByType("video/avc").also { c ->
            val fmt = MediaFormat.createVideoFormat("video/avc", deviceWidth, deviceHeight)
            c.configure(fmt, surface, null, 0)
            c.start()
        }
        Log.i(TAG, "decoder ready ${deviceWidth}x${deviceHeight}")
    }

    private fun startDecode(videoIn: InputStream) {
        decodeThread = Thread {
            val c = codec ?: return@Thread
            val timeoutUs = 10_000L
            try {
                while (running) {
                    val meta = videoIn.readExactly(12)
                    if (meta.size < 12) break

                    val pts = ByteBuffer.wrap(meta, 0, 8)
                        .order(ByteOrder.BIG_ENDIAN).getLong()
                    val frameSize = ByteBuffer.wrap(meta, 8, 4)
                        .order(ByteOrder.BIG_ENDIAN).getInt() and 0x7FFFFFFF

                    if (frameSize <= 0 || frameSize > 10_000_000) continue

                    val frameData = videoIn.readExactly(frameSize)
                    if (frameData.size < frameSize) break

                    val inputIdx = c.dequeueInputBuffer(timeoutUs)
                    if (inputIdx >= 0) {
                        val buf = c.getInputBuffer(inputIdx) ?: continue
                        buf.clear()
                        buf.put(frameData, 0, frameSize)
                        c.queueInputBuffer(inputIdx, 0, frameSize, pts, 0)
                    }

                    val info = MediaCodec.BufferInfo()
                    val outputIdx = c.dequeueOutputBuffer(info, timeoutUs)
                    if (outputIdx >= 0) c.releaseOutputBuffer(outputIdx, true)
                }
            } catch (e: Exception) {
                if (running) Log.e(TAG, "decode error", e)
            }
            Log.i(TAG, "decode thread ended")
        }.also { it.isDaemon = true; it.name = "scrcpy-decode"; it.start() }
    }

    // ── 控制 ─────────────────────────────────────────────────────────────────

    fun sendTouch(action: Int, pointerId: Long, x: Int, y: Int,
                  w: Int, h: Int, pressure: Float = 1f) {
        val buf = ByteBuffer.allocate(28).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_TOUCH.toByte())
        buf.put(action.toByte())
        buf.putLong(pointerId)
        buf.putInt(x); buf.putInt(y)
        buf.putShort(w.toShort()); buf.putShort(h.toShort())
        buf.putShort((pressure * 65535).toInt().toShort())
        buf.putInt(if (action == 0) 1 else 0)
        sendControl(buf.array())
    }

    fun sendScroll(x: Int, y: Int, w: Int, h: Int, hScroll: Int, vScroll: Int) {
        val buf = ByteBuffer.allocate(21).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_SCROLL.toByte())
        buf.putInt(x); buf.putInt(y)
        buf.putShort(w.toShort()); buf.putShort(h.toShort())
        buf.putInt(hScroll); buf.putInt(vScroll)
        buf.put(0)
        sendControl(buf.array())
    }

    fun sendKeycode(action: Int, keycode: Int, repeat: Int = 0, metaState: Int = 0) {
        val buf = ByteBuffer.allocate(14).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_KEYCODE.toByte())
        buf.put(action.toByte())
        buf.putInt(keycode); buf.putInt(repeat); buf.putInt(metaState)
        sendControl(buf.array())
    }

    fun sendBackOrScreenOn() = sendControl(byteArrayOf(TYPE_BACK_OR_SCREEN.toByte()))

    private fun sendControl(data: ByteArray) {
        try { controlOut?.write(data); controlOut?.flush() } catch (_: Exception) {}
    }

    // ── 停止 ─────────────────────────────────────────────────────────────────

    fun stop() {
        running = false
        try { videoSocket?.close()   } catch (_: Exception) {}
        try { controlSocket?.close() } catch (_: Exception) {}
        try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        try { surface?.release() } catch (_: Exception) {}
        codec = null; surface = null
        onEvent("stopped", emptyMap())
    }

    // ── 工具 ─────────────────────────────────────────────────────────────────

    private fun InputStream.readExactly(n: Int): ByteArray {
        val buf = ByteArray(n); var off = 0
        while (off < n) {
            val r = read(buf, off, n - off)
            if (r < 0) break
            off += r
        }
        return if (off == n) buf else buf.copyOf(off)
    }
}
