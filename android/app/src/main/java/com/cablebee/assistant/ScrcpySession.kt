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

class ScrcpySession(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val onEvent: (String, Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "ScrcpySession"
        private const val SCRCPY_PORT    = 5005
        private const val DEVICE_SOCKET  = "localabstract:scrcpy"
        private const val SERVER_PATH    = "/data/local/tmp/scrcpy_server.apk"
        private const val SERVER_PATH_SD = "/sdcard/adbhelper/scrcpy_server.apk"

        // 控制消息类型
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

    // ── 启动 ─────────────────────────────────────────────────────────────────

    fun start(
        adbExec: String,
        serial: String,
        maxSize: Int = 1080,
        bitRate: Int = 8_000_000,
        maxFps: Int = 30,
        serverBytes: ByteArray,
    ) {
        if (running) return
        running = true
        Thread {
            try { _start(adbExec, serial, maxSize, bitRate, maxFps, serverBytes) }
            catch (e: Exception) {
                Log.e(TAG, "Session failed", e)
                onEvent("error", mapOf("message" to (e.message ?: "未知错误")))
                stop()
            }
        }.also { it.isDaemon = true; it.name = "scrcpy-start" }.start()
    }

    private fun _start(
        adbExec: String, serial: String,
        maxSize: Int, bitRate: Int, maxFps: Int,
        serverBytes: ByteArray,
    ) {
        // 1. 推送 server
        onEvent("status", mapOf("msg" to "正在推送 server..."))
        val serverPath = pushServer(adbExec, serial, serverBytes)
        Log.i(TAG, "server pushed to $serverPath")

        // 2. adb forward
        onEvent("status", mapOf("msg" to "建立隧道..."))
        adbRun(adbExec, "-s", serial, "forward", "--remove", "tcp:$SCRCPY_PORT")
        adbRun(adbExec, "-s", serial, "forward", "tcp:$SCRCPY_PORT", DEVICE_SOCKET)

        // 3. 启动 server（甲壳虫方式：无版本号无参数）
        onEvent("status", mapOf("msg" to "启动 server..."))
        startServer(adbExec, serial, serverPath)
        Thread.sleep(800)

        // 4. 连接 video socket
        onEvent("status", mapOf("msg" to "连接中..."))
        var attempt = 0
        while (attempt < 25 && running) {
            try {
                videoSocket = Socket("127.0.0.1", SCRCPY_PORT)
                break
            } catch (e: IOException) {
                attempt++
                Log.w(TAG, "connect attempt $attempt: ${e.message}")
                onEvent("status", mapOf("msg" to "连接中... ($attempt/25)"))
                Thread.sleep(300)
            }
        }
        val vSock = videoSocket
            ?: throw IOException("无法连接 scrcpy server，请检查设备 ADB 授权")

        // 5. 连接 control socket
        controlSocket = Socket("127.0.0.1", SCRCPY_PORT)
        controlOut = controlSocket!!.getOutputStream()

        // 6. 读握手头：设备名(64B) + 宽(2B) + 高(2B)
        val videoIn = vSock.getInputStream()
        val header = videoIn.readExactly(68)
        val deviceName = String(header, 0, 64).trimEnd('\u0000')
        deviceWidth  = ((header[64].toInt() and 0xFF) shl 8) or (header[65].toInt() and 0xFF)
        deviceHeight = ((header[66].toInt() and 0xFF) shl 8) or (header[67].toInt() and 0xFF)
        Log.i(TAG, "connected: $deviceName ${deviceWidth}x${deviceHeight}")

        onEvent("connected", mapOf(
            "deviceName"   to deviceName,
            "deviceWidth"  to deviceWidth,
            "deviceHeight" to deviceHeight,
        ))

        // 7. 初始化解码器
        initDecoder()

        // 8. 开始解码
        startDecode(videoIn)
    }

    // ── Server 管理 ──────────────────────────────────────────────────────────

    private fun pushServer(adbExec: String, serial: String, bytes: ByteArray): String {
        for (path in listOf(SERVER_PATH, SERVER_PATH_SD)) {
            try {
                // 先确保目录存在
                if (path.contains("adbhelper")) {
                    adbShell(adbExec, serial, "mkdir -p /sdcard/adbhelper 2>/dev/null")
                }

                val tmp = java.io.File.createTempFile("scrcpy_srv", ".apk")
                tmp.writeBytes(bytes)

                val proc = ProcessBuilder(adbExec, "-s", serial, "push",
                    tmp.absolutePath, path)
                    .redirectErrorStream(true).start()
                val out = proc.inputStream.bufferedReader().readText()
                proc.waitFor()
                tmp.delete()

                Log.d(TAG, "push to $path: $out")
                if (out.contains("error", ignoreCase = true) ||
                    out.contains("failed", ignoreCase = true)) continue

                // 验证大小
                val check = adbShell(adbExec, serial, "wc -c < $path 2>/dev/null")
                val remoteSize = check.trim().toIntOrNull() ?: 0
                if (remoteSize == bytes.size) {
                    Log.i(TAG, "verified $path size=$remoteSize")
                    return path
                }
                Log.w(TAG, "size mismatch: local=${bytes.size} remote=$remoteSize")
            } catch (e: Exception) {
                Log.w(TAG, "push to $path failed: ${e.message}")
            }
        }
        throw IOException("无法推送 scrcpy server 到设备")
    }

    private fun startServer(adbExec: String, serial: String, serverPath: String) {
        // 甲壳虫方式：无版本号，无额外参数
        val androidData = if (serverPath.startsWith("/sdcard")) "ANDROID_DATA=/sdcard " else ""
        val cmd = "${androidData}CLASSPATH=$serverPath app_process ./ com.genymobile.scrcpy.Server"
        Log.i(TAG, "startServer cmd: $cmd")

        Thread {
            try {
                val proc = ProcessBuilder(adbExec, "-s", serial, "shell", cmd)
                    .redirectErrorStream(true).start()
                val output = proc.inputStream.bufferedReader().readText()
                if (output.isNotBlank()) {
                    Log.i(TAG, "server output: $output")
                    if (output.contains("Exception", ignoreCase = true) ||
                        output.contains("Error", ignoreCase = true)) {
                        onEvent("error", mapOf("message" to "server启动失败:\n$output"))
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "startServer failed", e)
            }
        }.also { it.isDaemon = true }.start()
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
                    // 每帧12字节元数据: PTS(8B) + 帧大小(4B)
                    val meta = videoIn.readExactly(12)
                    if (meta.size < 12) break

                    val pts = ByteBuffer.wrap(meta, 0, 8)
                        .order(ByteOrder.BIG_ENDIAN).getLong()
                    val frameSize = ByteBuffer.wrap(meta, 8, 4)
                        .order(ByteOrder.BIG_ENDIAN).getInt() and 0x7FFFFFFF

                    if (frameSize <= 0 || frameSize > 10_000_000) continue

                    val frameData = videoIn.readExactly(frameSize)
                    if (frameData.size < frameSize) break

                    // 喂给解码器
                    val inputIdx = c.dequeueInputBuffer(timeoutUs)
                    if (inputIdx >= 0) {
                        val buf = c.getInputBuffer(inputIdx) ?: continue
                        buf.clear()
                        buf.put(frameData, 0, frameSize)
                        c.queueInputBuffer(inputIdx, 0, frameSize, pts, 0)
                    }

                    // 渲染输出帧
                    val info = MediaCodec.BufferInfo()
                    val outputIdx = c.dequeueOutputBuffer(info, timeoutUs)
                    if (outputIdx >= 0) {
                        c.releaseOutputBuffer(outputIdx, true)
                    }
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

    private fun adbShell(adbExec: String, serial: String, cmd: String): String = try {
        val p = ProcessBuilder(adbExec, "-s", serial, "shell", cmd)
            .redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor()
        out
    } catch (_: Exception) { "" }

    private fun adbRun(vararg args: String) = try {
        ProcessBuilder(*args).redirectErrorStream(true).start().waitFor()
    } catch (_: Exception) { 0 }

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
