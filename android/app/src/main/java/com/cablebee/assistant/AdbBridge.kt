package com.cablebee.assistant

import android.util.Log
import java.io.*
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyPair
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "AdbBridge"

// ── ADB Stream ────────────────────────────────────────────────────────────────

private class AdbStream(val localId: UInt) {
    val remoteId = AtomicInteger(0)
    val open     = AtomicBoolean(true)
    private val buf = ByteArrayOutputStream()

    @Synchronized fun append(data: ByteArray) { buf.write(data) }
    @Synchronized fun drain(): ByteArray { val b = buf.toByteArray(); buf.reset(); return b }
    fun close() { open.set(false) }
}

// ── ADB Connection ────────────────────────────────────────────────────────────

class AdbConnection private constructor(
    val serial: String,
    private val socket: Socket,
    private val inp: InputStream,
    private val out: OutputStream,
    private val keyPair: KeyPair
) {
    private val nextLocalId = AtomicInteger(1)
    private val streams     = ConcurrentHashMap<UInt, AdbStream>()
    val connected           = AtomicBoolean(true)

    // ── Shell ─────────────────────────────────────────────────────────────

    fun shell(command: String, timeoutMs: Long = 15_000): String {
        Log.d(TAG, "shell: $command")
        val stream   = openStream("shell:$command\u0000")
        val deadline = System.currentTimeMillis() + timeoutMs
        val result   = StringBuilder()
        while (System.currentTimeMillis() < deadline) {
            pumpOnce()
            val data = stream.drain()
            if (data.isNotEmpty()) result.append(String(data, Charsets.UTF_8))
            if (!stream.open.get()) break
            Thread.sleep(20)
        }
        closeStream(stream)
        val output = result.toString()
        Log.d(TAG, "shell result len=${output.length} streamOpen=${stream.open.get()} connected=${connected.get()}")
        Log.d(TAG, "shell output>>>$output<<<")
        return output
    }

    // ── SYNC push ─────────────────────────────────────────────────────────
    //
    // Protocol: open "sync:\0", then send DATA frames, close with DONE.
    //
    // Wire format for push:
    //   SEND <path,perms>\0   4-byte "SEND" + 4-byte len + path,perms bytes
    //   DATA <n>              4-byte "DATA" + 4-byte len + <n> bytes  (repeat)
    //   DONE <mtime>          4-byte "DONE" + 4-byte mtime
    //   → server replies OKAY or FAIL

    fun push(localPath: String, remotePath: String,
             mode: Int = 420,            // 0644 octal = 420 decimal
             onProgress: ((Long, Long) -> Unit)? = null): SyncResult {
        val file = File(localPath)
        if (!file.exists()) return SyncResult(false, "local file not found: $localPath")

        val stream = openStream("sync:\u0000")
        try {
            val syncOut = SyncWriter(out, stream)
            val syncIn  = SyncReader(inp, stream, ::pumpOnce)

            // SEND <path,perms> — device expects octal string e.g. "0644"
            val modeOctal = mode.toString(8).padStart(4, '0')
            val header = "$remotePath,$modeOctal"
            syncOut.writeId("SEND", header.length)
            syncOut.raw(header.toByteArray(Charsets.UTF_8))
            syncOut.flush()

            // DATA chunks
            val total   = file.length()
            var sent    = 0L
            val chunk   = ByteArray(64 * 1024)
            file.inputStream().use { fis ->
                var n: Int
                while (fis.read(chunk).also { n = it } != -1) {
                    syncOut.writeId("DATA", n)
                    syncOut.raw(chunk, 0, n)
                    syncOut.flush()
                    sent += n
                    onProgress?.invoke(sent, total)
                }
            }

            // DONE
            val mtime = (System.currentTimeMillis() / 1000).toInt()
            syncOut.writeId("DONE", mtime)
            syncOut.flush()

            // Read response
            return syncIn.readResult()
        } finally {
            closeStream(stream)
        }
    }

    // ── SYNC pull ─────────────────────────────────────────────────────────
    //
    // Wire:
    //   RECV <path>   4-byte "RECV" + 4-byte len + path bytes
    //   → server sends DATA frames then DONE (or FAIL)

    fun pull(remotePath: String, localPath: String,
             onProgress: ((Long, Long) -> Unit)? = null): SyncResult {
        val stream = openStream("sync:\u0000")
        try {
            val syncOut = SyncWriter(out, stream)
            val syncIn  = SyncReader(inp, stream, ::pumpOnce)

            // RECV
            syncOut.writeId("RECV", remotePath.length)
            syncOut.raw(remotePath.toByteArray(Charsets.UTF_8))
            syncOut.flush()

            // Read DATA frames
            File(localPath).parentFile?.mkdirs()
            File(localPath).outputStream().buffered().use { fos ->
                var received = 0L
                while (true) {
                    val id  = syncIn.readId()
                    val len = syncIn.readInt()
                    when (id) {
                        "DATA" -> {
                            val buf = syncIn.readBytes(len)
                            fos.write(buf)
                            received += len
                            onProgress?.invoke(received, -1)
                        }
                        "DONE" -> {
                            syncIn.readInt() // mtime, ignore
                            return SyncResult(true, "")
                        }
                        "FAIL" -> {
                            val msg = String(syncIn.readBytes(len), Charsets.UTF_8)
                            return SyncResult(false, msg)
                        }
                        else -> return SyncResult(false, "unexpected sync id: $id")
                    }
                }
            }
            @Suppress("UNREACHABLE_CODE")
            return SyncResult(false, "unexpected end")
        } finally {
            closeStream(stream)
        }
    }

    // ── Stream lifecycle ──────────────────────────────────────────────────

    private fun openStream(service: String): AdbStream {
        val localId = nextLocalId.getAndIncrement().toUInt()
        val stream  = AdbStream(localId)
        streams[localId] = stream
        send(AdbMessage(AdbCmd.OPEN, localId, 0u, service.toByteArray(Charsets.UTF_8)))

        val deadline = System.currentTimeMillis() + 8_000
        while (stream.remoteId.get() == 0 && System.currentTimeMillis() < deadline) {
            pumpOnce()
            Thread.sleep(10)
        }
        if (stream.remoteId.get() == 0) throw IOException("OPEN timed out: $service")
        return stream
    }

    private fun closeStream(stream: AdbStream) {
        if (!stream.open.get()) return
        stream.close()
        streams.remove(stream.localId)
        runCatching { send(AdbMessage(AdbCmd.CLSE, stream.localId, stream.remoteId.get().toUInt())) }
    }

    // ── Message pump ──────────────────────────────────────────────────────

    private fun pumpOnce() {
        try {
            val avail = inp.available()
            if (avail < 24) return
            Log.v(TAG, "pump: available=$avail")
            val msg = AdbMessage.readFrom(inp)
            Log.v(TAG, "pump: cmd=0x${msg.command.toString(16)} arg0=${msg.arg0} arg1=${msg.arg1} dataLen=${msg.data.size}")
            dispatch(msg)
        } catch (e: Exception) {
            Log.w(TAG, "pump exception: ${e.javaClass.simpleName}: ${e.message}")
            connected.set(false)
        }
    }

    private fun dispatch(msg: AdbMessage) {
        when (msg.command) {
            AdbCmd.OKAY -> {
                // arg1 = our localId, arg0 = their remoteId
                val s = streams[msg.arg1] ?: return
                if (s.remoteId.get() == 0) s.remoteId.set(msg.arg0.toInt())
                // No ack needed for OKAY — only WRTE requires an OKAY reply
            }
            AdbCmd.WRTE -> {
                streams[msg.arg1]?.append(msg.data)
                send(AdbMessage(AdbCmd.OKAY, msg.arg1, msg.arg0))
            }
            AdbCmd.CLSE -> {
                streams[msg.arg1]?.close()
                streams.remove(msg.arg1)
            }
        }
    }

    @Synchronized private fun send(msg: AdbMessage) {
        runCatching { msg.writeTo(out) }.onFailure { connected.set(false) }
    }

    fun close() {
        connected.set(false)
        runCatching { socket.close() }
    }

    /** 检查 socket 是否仍然存活（不看 connected 标志，只看底层 socket） */
    fun isAlive(): Boolean {
        return try {
            !socket.isClosed && socket.isConnected
        } catch (e: Exception) {
            false
        }
    }

    // ── SYNC helpers ──────────────────────────────────────────────────────

    // SyncWriter sends raw bytes directly on the underlying socket output,
    // bypassing the ADB message framing. This works because after the OPEN/OKAY
    // handshake the SYNC service reads a raw byte stream inside the ADB tunnel.
    // We still need to ACK WRTE messages coming back via the pump.

    private inner class SyncWriter(
        private val socketOut: OutputStream,
        private val stream: AdbStream
    ) {
        private val bb = ByteArrayOutputStream(64 * 1024 + 8)

        fun writeId(id: String, value: Int) {
            bb.write(id.toByteArray(Charsets.US_ASCII))
            bb.write(intLE(value))
        }

        fun raw(bytes: ByteArray, off: Int = 0, len: Int = bytes.size) {
            bb.write(bytes, off, len)
        }

        fun flush() {
            // Wrap accumulated bytes in ADB WRTE message
            val data = bb.toByteArray()
            bb.reset()
            if (data.isEmpty()) return
            // Send in chunks ≤ MAX_PAYLOAD
            var off = 0
            while (off < data.size) {
                val chunk = data.copyOfRange(off, minOf(off + 1024 * 1024, data.size))
                send(AdbMessage(AdbCmd.WRTE, stream.localId, stream.remoteId.get().toUInt(), chunk))
                off += chunk.size
                // Pump incoming messages so the remote OKAY ack is processed
                val deadline = System.currentTimeMillis() + 5_000
                while (System.currentTimeMillis() < deadline) {
                    pumpOnce(); Thread.sleep(5)
                    break // WRTE ack is fire-and-forget; one pump pass is sufficient
                }
            }
        }

        private fun intLE(v: Int): ByteArray {
            val b = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
            b.putInt(v)
            return b.array()
        }
    }

    private inner class SyncReader(
        private val socketInp: InputStream,
        private val stream: AdbStream,
        private val pump: () -> Unit
    ) {
        private val buf = ByteArrayOutputStream()

        private fun ensureBytes(n: Int, timeoutMs: Long = 10_000) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (buf.size() < n && System.currentTimeMillis() < deadline) {
                pump()
                val data = stream.drain()
                if (data.isNotEmpty()) buf.write(data)
                if (buf.size() < n) Thread.sleep(10)
            }
            if (buf.size() < n) throw IOException("SYNC read timeout (want $n, have ${buf.size()})")
        }

        fun readId(): String {
            ensureBytes(4)
            val bytes = buf.toByteArray()
            val id = String(bytes, 0, 4, Charsets.US_ASCII)
            val rest = bytes.copyOfRange(4, bytes.size)
            buf.reset(); buf.write(rest)
            return id
        }

        fun readInt(): Int {
            ensureBytes(4)
            val bytes = buf.toByteArray()
            val v = ByteBuffer.wrap(bytes, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
            val rest = bytes.copyOfRange(4, bytes.size)
            buf.reset(); buf.write(rest)
            return v
        }

        fun readBytes(n: Int): ByteArray {
            ensureBytes(n)
            val bytes = buf.toByteArray()
            val result = bytes.copyOfRange(0, n)
            val rest   = bytes.copyOfRange(n, bytes.size)
            buf.reset(); buf.write(rest)
            return result
        }

        fun readResult(): SyncResult {
            val id  = readId()
            val len = readInt()
            return when (id) {
                "OKAY" -> { readBytes(len); SyncResult(true, "") }
                "FAIL" -> SyncResult(false, String(readBytes(len), Charsets.UTF_8))
                else   -> SyncResult(false, "unexpected response: $id")
            }
        }
    }

    // ── Factory ───────────────────────────────────────────────────────────

    companion object {
        fun connect(host: String, port: Int, keyPair: KeyPair): AdbConnection {
            val socket = Socket()
            socket.connect(InetSocketAddress(host, port), 8_000)
            // 握手阶段给足够长的超时（用户需要时间点允许弹窗）
            socket.soTimeout = 30_000
            val inp = socket.getInputStream()
            val out = socket.getOutputStream()

            // CONNECT
            AdbMessage(
                AdbCmd.CNXN, AdbCmd.VERSION, AdbCmd.MAX_PAYLOAD,
                "host::CableBee\u0000".toByteArray(Charsets.UTF_8)
            ).writeTo(out)

            // Handshake 状态机:
            // 1. 设备发 AUTH_TOKEN → 我们回 AUTH_SIGNATURE（用私钥签名）
            // 2a. 公钥已知 → 设备直接发 CNXN → 握手完成，不弹窗
            // 2b. 公钥未知 → 设备再发 AUTH_TOKEN → 我们回 AUTH_RSAPUBLICKEY
            //     → 设备弹"允许调试"窗口，用户点允许 → 设备发 CNXN → 完成
            //     → 之后同一公钥连接走 2a，不再弹窗
            var triedSignature = false
            var triedPublicKey = false
            val deadline = System.currentTimeMillis() + 30_000
            while (System.currentTimeMillis() < deadline) {
                val msg = try {
                    AdbMessage.readFrom(inp)
                } catch (e: java.net.SocketTimeoutException) {
                    // 超时继续等，不中断握手（用户可能还在看弹窗）
                    continue
                }
                when (msg.command) {
                    AdbCmd.CNXN -> {
                        // 握手成功，正常工作超时改回 15s
                        socket.soTimeout = 15_000
                        return AdbConnection("$host:$port", socket, inp, out, keyPair)
                    }
                    AdbCmd.AUTH -> when (msg.arg0.toInt()) {
                        1 -> { // AUTH_TOKEN
                            if (!triedSignature) {
                                triedSignature = true
                                val sig = AdbCrypto.sign(keyPair, msg.data)
                                AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_SIGNATURE, 0u, sig).writeTo(out)
                            } else if (!triedPublicKey) {
                                // 签名未通过（公钥未知），发公钥，等用户点允许
                                triedPublicKey = true
                                val pub = AdbCrypto.encodePublicKey(keyPair)
                                AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_RSAPUBLICKEY, 0u, pub).writeTo(out)
                            }
                            // 已发公钥，继续等 CNXN
                        }
                        else -> {
                            val pub = AdbCrypto.encodePublicKey(keyPair)
                            AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_RSAPUBLICKEY, 0u, pub).writeTo(out)
                        }
                    }
                }
            }
            throw IOException("握手超时，请在设备上点击允许调试")
        }
    }
}

data class SyncResult(val success: Boolean, val error: String)

// ── Bridge singleton ──────────────────────────────────────────────────────────

object AdbBridge {
    private lateinit var keyPair: java.security.KeyPair
    private val connections = ConcurrentHashMap<String, AdbConnection>()

    /** Call once from MainActivity.onCreate() before any connect(). */
    fun init(filesDir: java.io.File) {
        if (!::keyPair.isInitialized) {
            keyPair = AdbCrypto.loadOrGenerateKeyPair(filesDir)
            val pub = AdbCrypto.encodePublicKey(keyPair)
            // 打印公钥指纹，用于确认每次 app 启动使用的是同一个 key
            Log.i(TAG, "ADB key fingerprint: ${pub.take(16).joinToString("") { "%02x".format(it) }}...")
        }
    }

    fun connect(host: String, port: Int): String {
        val key = "$host:$port"
        // 优先复用：socket 存活时直接复用，无需重新握手，不触发授权弹窗
        connections[key]?.let { existing ->
            if (existing.isAlive()) {
                existing.connected.set(true)
                return key
            }
            // socket 已死才清理重建
            runCatching { existing.close() }
            connections.remove(key)
        }
        connections[key] = AdbConnection.connect(host, port, keyPair)
        return key
    }

    /**
     * 软断开：仅将 connected 标记置 false，保留 socket 连接对象在 map 中不销毁。
     * 下次 connect() 同一 host:port 时 socket 仍然存活，直接复用，不触发设备端授权弹窗。
     */
    fun disconnect(serial: String) {
        connections[serial]?.connected?.set(false)
    }

    /** App 退出时才真正关闭所有连接并清空 map。 */
    fun disconnectAll() {
        connections.values.forEach { runCatching { it.close() } }
        connections.clear()
    }

    fun devices(): List<String> = connections.filter { it.value.connected.get() }.keys.toList()

    fun shell(serial: String, command: String, timeoutMs: Long = 15_000): String =
        conn(serial).shell(command, timeoutMs)

    fun push(serial: String, localPath: String, remotePath: String,
             onProgress: ((Long, Long) -> Unit)? = null): SyncResult =
        conn(serial).push(localPath, remotePath, onProgress = onProgress)

    fun pull(serial: String, remotePath: String, localPath: String,
             onProgress: ((Long, Long) -> Unit)? = null): SyncResult =
        conn(serial).pull(remotePath, localPath, onProgress = onProgress)

    private fun conn(serial: String) =
        connections[serial] ?: throw IOException("Not connected: $serial")
}
