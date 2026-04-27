package com.cablebee.assistant

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
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
 * ScrcpySession — 管理单次 scrcpy 投屏会话
 *
 * 流程：
 * 1. adb push scrcpy-server 到设备
 * 2. adb shell 启动 server
 * 3. adb forward 建立本地端口到设备 socket 的隧道
 * 4. 连接本地 socket，读取设备信息头
 * 5. 启动 MediaCodec 解码 H.264 视频流
 * 6. 渲染到 Flutter TextureEntry
 */
class ScrcpySession(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val onEvent: (String, Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "ScrcpySession"

        // scrcpy 协议常量
        private const val SCRCPY_PORT       = 27183
        private const val DEVICE_SOCKET     = "localabstract:scrcpy"
        private const val SERVER_PATH_TMP   = "/data/local/tmp/scrcpy-server.jar"
        private const val SERVER_PATH_SDCARD= "/sdcard/scrcpy-server.jar"
        private const val SCRCPY_VERSION    = "3.3.1"

        // 控制消息类型
        const val TYPE_INJECT_TOUCH         = 2
        const val TYPE_INJECT_SCROLL        = 3
        const val TYPE_BACK_OR_SCREEN_ON    = 4
        const val TYPE_INJECT_KEYCODE       = 0
    }

    // ── 状态 ─────────────────────────────────────────────────────────────────
    @Volatile private var running = false

    private var videoSocket:   Socket? = null
    private var controlSocket: Socket? = null
    private var controlOut:    OutputStream? = null

    private var codec:         MediaCodec? = null
    private var surface:       Surface? = null

    private var decodeThread:  Thread? = null
    private var readThread:    Thread? = null

    // 设备屏幕信息（从 server 握手读取）
    var deviceWidth:  Int = 0; private set
    var deviceHeight: Int = 0; private set

    // ── 启动 ─────────────────────────────────────────────────────────────────

    /**
     * 启动投屏会话。
     * @param adbExec  adb 二进制路径
     * @param serial   设备 serial（如 "192.168.1.1:5555"）
     * @param maxSize  最大边长（0=原始）
     * @param bitRate  视频码率（bps），如 8_000_000
     * @param maxFps   最大帧率，如 30
     * @param serverBytes  scrcpy-server.jar 的字节内容（从 assets 读取）
     */
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
            try {
                _start(adbExec, serial, maxSize, bitRate, maxFps, serverBytes)
            } catch (e: Exception) {
                Log.e(TAG, "Session failed", e)
                onEvent("error", mapOf("message" to (e.message ?: "unknown")))
                stop()
            }
        }.also { it.isDaemon = true; it.name = "scrcpy-start" }.start()
    }

    private fun _start(
        adbExec: String,
        serial: String,
        maxSize: Int,
        bitRate: Int,
        maxFps: Int,
        serverBytes: ByteArray,
    ) {
        // 1. 推送 server 到设备
        onEvent("status", mapOf("msg" to "正在推送 server..."))
        val serverPath = pushServer(adbExec, serial, serverBytes)
        Log.i(TAG, "server pushed to $serverPath")

        // 2. 启动 server（后台 shell）
        onEvent("status", mapOf("msg" to "正在启动 server..."))
        startServer(adbExec, serial, serverPath, maxSize, bitRate, maxFps)
        Thread.sleep(500) // 给 server 启动时间

        // 3. adb forward
        onEvent("status", mapOf("msg" to "建立隧道..."))
        setupForward(adbExec, serial)

        // 4. 连接 video socket（server 启动后监听）
        onEvent("status", mapOf("msg" to "连接中..."))
        var attempt = 0
        while (attempt < 20 && running) {
            try {
                videoSocket = Socket("127.0.0.1", SCRCPY_PORT)
                break
            } catch (e: IOException) {
                attempt++
                Log.w(TAG, "connect attempt $attempt failed: ${e.message}")
                onEvent("status", mapOf("msg" to "连接中... ($attempt/20)"))
                Thread.sleep(300)
            }
        }
        val vSock = videoSocket
            ?: throw IOException("无法连接 scrcpy server（尝试20次均失败）\n请检查：1.设备已授权ADB 2.scrcpy-server已正确推送")

        // 5. 连接 control socket
        controlSocket = Socket("127.0.0.1", SCRCPY_PORT)
        controlOut = controlSocket!!.getOutputStream()

        // 6. 读握手头：设备名(64字节) + 宽(2字节) + 高(2字节)
        val videoIn = vSock.getInputStream()
        val header = videoIn.readNBytes(68)
        val deviceName = String(header, 0, 64).trimEnd('\u0000')
        deviceWidth  = ((header[64].toInt() and 0xFF) shl 8) or (header[65].toInt() and 0xFF)
        deviceHeight = ((header[66].toInt() and 0xFF) shl 8) or (header[67].toInt() and 0xFF)
        Log.i(TAG, "Connected: $deviceName ${deviceWidth}x${deviceHeight}")

        onEvent("connected", mapOf(
            "deviceName"   to deviceName,
            "deviceWidth"  to deviceWidth,
            "deviceHeight" to deviceHeight,
        ))

        // 7. 初始化 MediaCodec 解码器
        initDecoder()

        // 8. 开始读取并解码视频流
        startDecode(videoIn)
    }

    // ── Server 管理 ──────────────────────────────────────────────────────────

    private fun pushServer(adbExec: String, serial: String, bytes: ByteArray): String {
        // 优先推到 /data/local/tmp，失败则 /sdcard
        for (path in listOf(SERVER_PATH_TMP, SERVER_PATH_SDCARD)) {
            try {
                // 写临时文件
                val tmp = java.io.File.createTempFile("scrcpy-server", ".jar")
                tmp.writeBytes(bytes)

                val proc = ProcessBuilder(
                    adbExec, "-s", serial, "push", tmp.absolutePath, path
                ).redirectErrorStream(true).start()
                val out = proc.inputStream.bufferedReader().readText()
                proc.waitFor()
                tmp.delete()

                if (out.contains("error", ignoreCase = true) ||
                    out.contains("failed", ignoreCase = true)) continue

                // 验证
                val check = adbShell(adbExec, serial, "wc -c < $path 2>/dev/null")
                val remoteSize = check.trim().toIntOrNull() ?: 0
                if (remoteSize == bytes.size) return path
            } catch (e: Exception) {
                Log.w(TAG, "push to $path failed: ${e.message}")
            }
        }
        throw IOException("无法推送 scrcpy-server 到设备")
    }

    private fun startServer(
        adbExec: String, serial: String, serverPath: String,
        maxSize: Int, bitRate: Int, maxFps: Int,
    ) {
        // scrcpy 3.x 启动格式
        val androidData = if (serverPath.startsWith("/sdcard")) "ANDROID_DATA=/sdcard " else ""
        val cmd = buildString {
            append("CLASSPATH=$serverPath ")
            append(androidData)
            append("app_process /system/bin com.genymobile.scrcpy.Server $SCRCPY_VERSION ")
            append("tunnel_forward=true ")
            append("video=true ")
            append("audio=false ")
            append("control=true ")
            append("send_device_meta=true ")
            append("send_frame_meta=true ")
            append("raw_video_stream=false ")
            if (maxSize > 0) append("max_size=$maxSize ")
            append("video_bit_rate=$bitRate ")
            if (maxFps > 0) append("max_fps=$maxFps ")
            append("video_codec=h264 ")
            append("lock_video_orientation=-1 ")
            append("display_id=0")
        }
        // 后台运行，不等待
        Thread {
            try {
                val proc = ProcessBuilder(adbExec, "-s", serial, "shell", cmd)
                    .redirectErrorStream(true)
                    .start()
                // 读输出日志（server 启动失败时会有错误信息）
                val output = proc.inputStream.bufferedReader().readText()
                if (output.isNotBlank()) {
                    Log.i(TAG, "server output: $output")
                    if (output.contains("error", ignoreCase = true) ||
                        output.contains("exception", ignoreCase = true)) {
                        onEvent("error", mapOf("message" to "server启动失败: $output"))
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "startServer failed", e)
            }
        }.also { it.isDaemon = true }.start()
    }

    private fun setupForward(adbExec: String, serial: String) {
        // 先清除旧的 forward
        adbRun(adbExec, "-s", serial, "forward", "--remove", "tcp:$SCRCPY_PORT")
        // 建立新的 forward
        adbRun(adbExec, "-s", serial, "forward", "tcp:$SCRCPY_PORT", DEVICE_SOCKET)
    }

    // ── MediaCodec 解码 ──────────────────────────────────────────────────────

    private fun initDecoder() {
        val surfaceTexture = textureEntry.surfaceTexture()
        surfaceTexture.setDefaultBufferSize(deviceWidth, deviceHeight)
        surface = Surface(surfaceTexture)

        codec = MediaCodec.createDecoderByType("video/avc").also { c ->
            val format = MediaFormat.createVideoFormat("video/avc", deviceWidth, deviceHeight)
            c.configure(format, surface, null, 0)
            c.start()
        }
        Log.i(TAG, "MediaCodec initialized ${deviceWidth}x${deviceHeight}")
    }

    private fun startDecode(videoIn: InputStream) {
        decodeThread = Thread {
            val c = codec ?: return@Thread
            val timeoutUs = 10_000L
            val buf = ByteArray(65536)

            // 帧元数据读取状态
            var pts = 0L

            try {
                while (running) {
                    // scrcpy 3.x: 每帧前有12字节元数据
                    // [0..7] PTS (uint64 big-endian)
                    // [8..11] 帧大小 (uint32 big-endian)
                    val metaBuf = videoIn.readNBytes(12)
                    if (metaBuf.size < 12) break

                    pts = ByteBuffer.wrap(metaBuf, 0, 8)
                        .order(ByteOrder.BIG_ENDIAN).getLong()
                    val frameSize = ByteBuffer.wrap(metaBuf, 8, 4)
                        .order(ByteOrder.BIG_ENDIAN).getInt() and 0xFFFFFFFFL.toInt()

                    if (frameSize <= 0 || frameSize > 10_000_000) continue

                    // 读取帧数据
                    var remaining = frameSize
                    val frameData = ByteArray(frameSize)
                    var offset = 0
                    while (remaining > 0 && running) {
                        val read = videoIn.read(frameData, offset,
                            minOf(remaining, buf.size))
                        if (read < 0) break
                        offset += read
                        remaining -= read
                    }
                    if (remaining > 0) break

                    // 喂给 MediaCodec
                    val inputIdx = c.dequeueInputBuffer(timeoutUs)
                    if (inputIdx >= 0) {
                        val inputBuf = c.getInputBuffer(inputIdx) ?: continue
                        inputBuf.clear()
                        inputBuf.put(frameData, 0, frameSize)
                        c.queueInputBuffer(inputIdx, 0, frameSize, pts, 0)
                    }

                    // 输出帧
                    val info = MediaCodec.BufferInfo()
                    val outputIdx = c.dequeueOutputBuffer(info, timeoutUs)
                    if (outputIdx >= 0) {
                        c.releaseOutputBuffer(outputIdx, true) // true = 渲染到 Surface
                    }
                }
            } catch (e: Exception) {
                if (running) Log.e(TAG, "Decode error", e)
            }
            Log.i(TAG, "Decode thread ended")
        }.also { it.isDaemon = true; it.name = "scrcpy-decode"; it.start() }
    }

    // ── 控制 ─────────────────────────────────────────────────────────────────

    /** 发送触摸事件（action: 0=down, 1=up, 2=move） */
    fun sendTouch(action: Int, pointerId: Long, x: Int, y: Int,
                  w: Int, h: Int, pressure: Float = 1f) {
        // scrcpy 控制包格式 (TYPE_INJECT_TOUCH_EVENT = 2)
        // 1(type) + 1(action) + 8(pointerId) + 4(x) + 4(y) +
        // 2(screenW) + 2(screenH) + 2(pressure) + 4(buttons)
        val buf = ByteBuffer.allocate(28).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_TOUCH.toByte())  // type
        buf.put(action.toByte())              // action
        buf.putLong(pointerId)               // pointerId
        buf.putInt(x)                        // x
        buf.putInt(y)                        // y
        buf.putShort(w.toShort())            // screenWidth
        buf.putShort(h.toShort())            // screenHeight
        buf.putShort((pressure * 65535).toInt().toShort()) // pressure
        buf.putInt(if (action == 0) 1 else 0) // buttons (1=primary)
        sendControl(buf.array())
    }

    /** 发送滚动事件 */
    fun sendScroll(x: Int, y: Int, w: Int, h: Int, hScroll: Int, vScroll: Int) {
        val buf = ByteBuffer.allocate(21).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_SCROLL.toByte())
        buf.putInt(x); buf.putInt(y)
        buf.putShort(w.toShort()); buf.putShort(h.toShort())
        buf.putInt(hScroll); buf.putInt(vScroll)
        buf.put(0) // buttons
        sendControl(buf.array())
    }

    /** 发送按键事件 */
    fun sendKeycode(action: Int, keycode: Int, repeat: Int = 0, metaState: Int = 0) {
        // TYPE_INJECT_KEYCODE = 0
        // 1(type) + 1(action) + 4(keycode) + 4(repeat) + 4(metaState)
        val buf = ByteBuffer.allocate(14).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_KEYCODE.toByte())
        buf.put(action.toByte())
        buf.putInt(keycode)
        buf.putInt(repeat)
        buf.putInt(metaState)
        sendControl(buf.array())
    }

    /** 返回键 / 点亮屏幕 */
    fun sendBackOrScreenOn() {
        sendControl(byteArrayOf(TYPE_BACK_OR_SCREEN_ON.toByte()))
    }

    private fun sendControl(data: ByteArray) {
        try { controlOut?.write(data); controlOut?.flush() }
        catch (_: Exception) {}
    }

    // ── 停止 ─────────────────────────────────────────────────────────────────

    fun stop() {
        running = false
        try { videoSocket?.close()   } catch (_: Exception) {}
        try { controlSocket?.close() } catch (_: Exception) {}
        try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        try { surface?.release() } catch (_: Exception) {}
        codec   = null
        surface = null
        onEvent("stopped", emptyMap())
    }

    // ── 工具 ─────────────────────────────────────────────────────────────────

    private fun adbShell(adbExec: String, serial: String, cmd: String): String {
        return try {
            val proc = ProcessBuilder(adbExec, "-s", serial, "shell", cmd)
                .redirectErrorStream(true).start()
            val out = proc.inputStream.bufferedReader().readText()
            proc.waitFor()
            out
        } catch (_: Exception) { "" }
    }

    private fun adbRun(vararg args: String) {
        try {
            ProcessBuilder(*args).redirectErrorStream(true).start()
                .also { it.waitFor() }
        } catch (_: Exception) {}
    }

    private fun InputStream.readNBytes(n: Int): ByteArray {
        val buf = ByteArray(n)
        var offset = 0
        while (offset < n) {
            val read = read(buf, offset, n - offset)
            if (read < 0) break
            offset += read
        }
        return if (offset == n) buf else buf.copyOf(offset)
    }
}
