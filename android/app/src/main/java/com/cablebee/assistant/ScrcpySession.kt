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
 * ScrcpySession — 适配 scrcpy-server v3.x 协议
 *
 * v3.x 协议关键变化：
 * 1. 启动参数改为 key=value 格式
 * 2. video / control 各自独立 TCP 连接（audio 已禁用）
 * 3. 握手：dummy(1) + deviceName(64) + codecMeta(12) = 77 字节
 *    codecMeta = codec_id(4) + width(4) + height(4)，大端序
 * 4. 帧头 config 标志：bit63 = 1（PACKET_FLAG_CONFIG），不再是 Long.MIN_VALUE
 *    key frame 标志：bit62 = 1（PACKET_FLAG_KEY_FRAME）
 *    实际 PTS 只用低 62 位
 */
class ScrcpySession(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val onEvent: (String, Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "ScrcpySession"
        private const val SCRCPY_PORT = 5005

        // v3.x 帧标志（高位）
        private const val PACKET_FLAG_CONFIG    = Long.MIN_VALUE          // bit63
        private const val PACKET_FLAG_KEY_FRAME = 1L shl 62
        private const val PTS_MASK              = (1L shl 62) - 1L       // 低62位

        // control 消息类型（与 v1.x 相同）
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
    @Volatile private var decodedFrames: Long = 0

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
        onEvent("status", mapOf("msg" to "连接中..."))

        // ── 1. 连接 video socket（重试最多 30 次）────────────────────────────
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

        // ── 2. 独立连接 control socket（v3.x 分离连接）──────────────────────
        controlSocket = Socket("127.0.0.1", SCRCPY_PORT)
        controlOut = controlSocket!!.getOutputStream()

        // ── 3. 读取握手头（v3.x）────────────────────────────────────────────
        // 格式：dummy(1) + deviceName(64) + codec_id(4) + width(4) + height(4) = 77 字节
        // send_dummy_byte=true（默认），send_device_meta=true，send_codec_meta=true
        val videoIn = vSock.getInputStream()

        val header = videoIn.readExactly(77)
        if (header.size < 77) throw IOException("握手数据不足：${header.size}/77")

        // byte[0]      = dummy byte（忽略）
        // byte[1..64]  = device name（UTF-8, null 填充）
        // byte[65..68] = codec id（big-endian uint32，H264=0x68323634）
        // byte[69..72] = video width（big-endian int32）
        // byte[73..76] = video height（big-endian int32）
        val deviceName = String(header, 1, 64).trimEnd('\u0000')
        val codecId    = ByteBuffer.wrap(header, 65, 4).order(ByteOrder.BIG_ENDIAN).int
        val w          = ByteBuffer.wrap(header, 69, 4).order(ByteOrder.BIG_ENDIAN).int
        val h          = ByteBuffer.wrap(header, 73, 4).order(ByteOrder.BIG_ENDIAN).int

        Log.i(TAG, "handshake v3: name=$deviceName codec=0x${Integer.toHexString(codecId)} ${w}x${h}")

        if (w <= 0 || h <= 0 || w > 16384 || h > 16384) {
            throw IOException("握手分辨率无效：${w}x${h}")
        }

        deviceWidth  = w
        deviceHeight = h

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
            var consecutiveInvalidFrames = 0

            try {
                while (running) {
                    // 每帧 12 字节帧头：ptsAndFlags(8B long) + frameSize(4B int)，大端序
                    val meta = videoIn.readExactly(12)
                    if (meta.size < 12) break

                    val ptsAndFlags = ByteBuffer.wrap(meta, 0, 8)
                        .order(ByteOrder.BIG_ENDIAN).long
                    val frameSize = ByteBuffer.wrap(meta, 8, 4)
                        .order(ByteOrder.BIG_ENDIAN).int and 0x7FFFFFFF

                    if (frameSize <= 0 || frameSize > 10_000_000) {
                        Log.w(TAG, "invalid frameSize=$frameSize ptsAndFlags=$ptsAndFlags")
                        consecutiveInvalidFrames++
                        if (consecutiveInvalidFrames >= 20) {
                            throw IOException("视频流格式异常（连续无效帧），请重试并降低分辨率/码率")
                        }
                        continue
                    }
                    consecutiveInvalidFrames = 0

                    val frameData = videoIn.readExactly(frameSize)
                    if (frameData.size < frameSize) break

                    // v3.x 标志解析
                    // bit63 = PACKET_FLAG_CONFIG（config / SPS+PPS 帧）
                    // bit62 = PACKET_FLAG_KEY_FRAME
                    // 低62位 = 实际 PTS（微秒）
                    val isConfig  = (ptsAndFlags and PACKET_FLAG_CONFIG) != 0L
                    val pts       = if (isConfig) 0L else (ptsAndFlags and PTS_MASK)
                    val flags     = if (isConfig) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0

                    val inputIdx = c.dequeueInputBuffer(timeoutUs)
                    if (inputIdx >= 0) {
                        val buf = c.getInputBuffer(inputIdx) ?: continue
                        buf.clear()
                        buf.put(frameData, 0, frameSize)
                        c.queueInputBuffer(inputIdx, 0, frameSize, pts, flags)
                    }

                    if (!isConfig) {
                        val info = MediaCodec.BufferInfo()
                        while (running) {
                            val outputIdx = c.dequeueOutputBuffer(info, timeoutUs)
                            when {
                                outputIdx >= 0 -> c.releaseOutputBuffer(outputIdx, true)
                                outputIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                                outputIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                                    val of = c.outputFormat
                                    Log.i(TAG, "output format changed: $of")
                                    val outW = of.getInteger(MediaFormat.KEY_WIDTH)
                                    val outH = of.getInteger(MediaFormat.KEY_HEIGHT)
                                    if (outW > 0 && outH > 0) {
                                        textureEntry.surfaceTexture().setDefaultBufferSize(outW, outH)
                                        onEvent("connected", mapOf(
                                            "deviceName"   to "scrcpy",
                                            "deviceWidth"  to outW,
                                            "deviceHeight" to outH,
                                        ))
                                    }
                                }
                                outputIdx == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> { /* ignore */ }
                                else -> break
                            }
                        }
                        decodedFrames++
                    }
                }
            } catch (e: Exception) {
                if (running) {
                    Log.e(TAG, "decode error", e)
                    onEvent("error", mapOf("message" to (e.message ?: "视频解码失败")))
                }
            }
            if (running && decodedFrames == 0L) {
                onEvent("error", mapOf("message" to "NO_VIDEO_FRAME"))
            }
            Log.i(TAG, "decode thread ended")
        }.also { it.isDaemon = true; it.name = "scrcpy-decode"; it.start() }
    }

    // ── 控制 ─────────────────────────────────────────────────────────────────

    fun sendTouch(action: Int, pointerId: Long, x: Int, y: Int,
                  w: Int, h: Int, pressure: Float = 1f) {
        // v3.x InjectTouchEvent 格式（32字节）：
        // type(1) + action(1) + pointerId(8) + x(4) + y(4)
        // + screenW(2,unsigned) + screenH(2,unsigned)
        // + pressure(2,u16 fixed-point) + actionButton(4) + buttons(4)
        val buf = ByteBuffer.allocate(32).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_TOUCH.toByte())
        buf.put(action.toByte())
        buf.putLong(pointerId)
        buf.putInt(x); buf.putInt(y)
        buf.putShort((w and 0xFFFF).toShort())
        buf.putShort((h and 0xFFFF).toShort())
        buf.putShort((pressure * 65535).toInt().toShort()) // u16 fixed-point
        buf.putInt(if (action == 0) 1 else 0)              // actionButton
        buf.putInt(if (action == 0) 1 else 0)              // buttons
        sendControl(buf.array())
    }

    fun sendScroll(x: Int, y: Int, w: Int, h: Int, hScroll: Int, vScroll: Int) {
        val buf = ByteBuffer.allocate(21).order(ByteOrder.BIG_ENDIAN)
        buf.put(TYPE_INJECT_SCROLL.toByte())
        buf.putInt(x); buf.putInt(y)
        buf.putShort((w and 0xFFFF).toShort()); buf.putShort((h and 0xFFFF).toShort())
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
