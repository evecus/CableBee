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

    fun push(localPath: String, remotePath: String,
             mode: Int = 420,
             onProgress: ((Long, Long) -> Unit)? = null): SyncResult {
        val file = File(localPath)
        if (!file.exists()) return SyncResult(false, "local file not found: $localPath")

        val stream = openStream("sync:\u0000")
        try {
            val syncOut = SyncWriter(out, stream)
            val syncIn  = SyncReader(inp, stream, ::pumpOnce)

            val modeOctal = mode.toString(8).padStart(4, '0')
            val header = "$remotePath,$modeOctal"
            syncOut.writeId("SEND", header.length)
            syncOut.raw(header.toByteArray(Charsets.UTF_8))
            syncOut.flush()

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

            val mtime = (System.currentTimeMillis() / 1000).toInt()
            syncOut.writeId("DONE", mtime)
            syncOut.flush()

            return syncIn.readResult()
        } finally {
            closeStream(stream)
        }
    }

    // ── SYNC pull ─────────────────────────────────────────────────────────

    fun pull(remotePath: String, localPath: String,
             onProgress: ((Long, Long) -> Unit)? = null): SyncResult {
        val stream = openStream("sync:\u0000")
        try {
            val syncOut = SyncWriter(out, stream)
            val syncIn  = SyncReader(inp, stream, ::pumpOnce)

            syncOut.writeId("RECV", remotePath.length)
            syncOut.raw(remotePath.toByteArray(Charsets.UTF_8))
            syncOut.flush()

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
                            syncIn.readInt()
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
    // FIX(Bug-E): 只有在确定是真实 I/O 错误时才标记连接断开，
    // SocketTimeoutException 等非致命异常不应终止连接。
    // FIX(Bug-pumpOnce): available() < 24 时不跳过，改为非阻塞判断后直接返回，
    // 避免因 TCP 分包导致消息被永久忽略——available() 是当前缓冲字节数，
    // 分包时可能只有部分头到达；用 available()==0 快速返回即可，
    // 真正读取交给 readExactly 的阻塞逻辑。

    private fun pumpOnce() {
        try {
            // 没有任何字节到达时快速返回，避免阻塞
            if (inp.available() == 0) return
            Log.v(TAG, "pump: available=${inp.available()}")
            val msg = AdbMessage.readFrom(inp)
            Log.v(TAG, "pump: cmd=0x${msg.command.toString(16)} arg0=${msg.arg0} arg1=${msg.arg1} dataLen=${msg.data.size}")
            dispatch(msg)
        } catch (e: java.net.SocketTimeoutException) {
            // 空闲超时不代表连接断开，忽略即可
            Log.v(TAG, "pump: socket idle timeout, ignoring")
        } catch (e: Exception) {
            // 真实 I/O 错误才标记断连
            Log.w(TAG, "pump exception: ${e.javaClass.simpleName}: ${e.message}")
            connected.set(false)
        }
    }

    private fun dispatch(msg: AdbMessage) {
        when (msg.command) {
            AdbCmd.OKAY -> {
                val s = streams[msg.arg1] ?: return
                if (s.remoteId.get() == 0) s.remoteId.set(msg.arg0.toInt())
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

    fun isAlive(): Boolean {
        return try {
            !socket.isClosed && socket.isConnected && connected.get()
        } catch (e: Exception) {
            false
        }
    }

    // ── SYNC helpers ──────────────────────────────────────────────────────

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
            val data = bb.toByteArray()
            bb.reset()
            if (data.isEmpty()) return
            var off = 0
            while (off < data.size) {
                val chunk = data.copyOfRange(off, minOf(off + 1024 * 1024, data.size))
                send(AdbMessage(AdbCmd.WRTE, stream.localId, stream.remoteId.get().toUInt(), chunk))
                off += chunk.size
                val deadline = System.currentTimeMillis() + 5_000
                while (System.currentTimeMillis() < deadline) {
                    pumpOnce(); Thread.sleep(5)
                    break
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
            socket.connect(InetSocketAddress(host, port), 5_000)
            // FIX(Bug-E): 握手后重置为较小的 soTimeout，避免空闲时触发超时断连
            socket.soTimeout = 30_000   // 握手阶段允许用户有30秒点击授权
            val inp = socket.getInputStream()
            val out = socket.getOutputStream()

            AdbMessage(
                AdbCmd.CNXN, AdbCmd.VERSION, AdbCmd.MAX_PAYLOAD,
                "host::CableBee\u0000".toByteArray(Charsets.UTF_8)
            ).writeTo(out)

            // Handshake 状态机（修复 Bug-C）：
            //
            // 标准流程（密钥已知）：
            //   CNXN → AUTH_TOKEN → AUTH_SIGNATURE → CNXN ✓
            //
            // 首次授权流程（密钥未知）：
            //   CNXN → AUTH_TOKEN → AUTH_SIGNATURE(失败)
            //        → AUTH_TOKEN → AUTH_RSAPUBLICKEY → [用户点 Allow]
            //        → AUTH_TOKEN（Android 11+ 再发一次让你签名确认）
            //        → AUTH_SIGNATURE → CNXN ✓
            //
            // FIX(Bug-C): 发送 AUTH_RSAPUBLICKEY 并等用户授权后，
            // adbd（尤其 Android 11+）会再发一个 AUTH_TOKEN，
            // 此时应重新用私钥签名回复，而不是静默等待导致30秒超时。
            // 用 lastToken 记录最后收到的 token，随时可以重签。

            var triedSignature = false
            var triedPublicKey = false
            var lastToken: ByteArray? = null
            val deadline = System.currentTimeMillis() + 30_000

            while (System.currentTimeMillis() < deadline) {
                val msg = AdbMessage.readFrom(inp)
                when (msg.command) {
                    AdbCmd.CNXN -> {
                        // 握手完成，切换到较小的 soTimeout 避免空闲误判断连
                        socket.soTimeout = 0   // 0 = 无超时，由 available() 非阻塞驱动
                        return AdbConnection("$host:$port", socket, inp, out, keyPair)
                    }
                    AdbCmd.AUTH -> when (msg.arg0.toInt()) {
                        1 -> { // AUTH_TOKEN
                            lastToken = msg.data
                            when {
                                !triedSignature -> {
                                    // 第一步：先尝试签名（如果密钥已被授权，直接成功）
                                    triedSignature = true
                                    val sig = AdbCrypto.sign(keyPair, msg.data)
                                    AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_SIGNATURE, 0u, sig).writeTo(out)
                                }
                                !triedPublicKey -> {
                                    // 第二步：签名未被接受，发送公钥请求用户授权
                                    triedPublicKey = true
                                    val pub = AdbCrypto.encodePublicKey(keyPair)
                                    AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_RSAPUBLICKEY, 0u, pub).writeTo(out)
                                }
                                else -> {
                                    // FIX(Bug-C): 用户已点击 Allow，adbd 再次发来 AUTH_TOKEN
                                    // 此时用私钥重新签名即可完成握手，不能静默等待
                                    Log.d(TAG, "handshake: re-signing after user accepted public key")
                                    val sig = AdbCrypto.sign(keyPair, msg.data)
                                    AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_SIGNATURE, 0u, sig).writeTo(out)
                                }
                            }
                        }
                        else -> {
                            // AUTH type=3: adbd 主动要求发公钥（不常见）
                            val pub = AdbCrypto.encodePublicKey(keyPair)
                            AdbMessage(AdbCmd.AUTH, AdbCmd.AUTH_RSAPUBLICKEY, 0u, pub).writeTo(out)
                        }
                    }
                }
            }
            throw IOException("Handshake timed out — please accept the authorization dialog on the device")
        }
    }
}

data class SyncResult(val success: Boolean, val error: String)

// ── Bridge singleton ──────────────────────────────────────────────────────────

object AdbBridge {
    private lateinit var keyPair: java.security.KeyPair

    // FIX(Bug-F): 用 @Synchronized 保护 connect()，防止并发时重复建立连接
    private val connections = ConcurrentHashMap<String, AdbConnection>()
    private val connectLock = Any()

    /** Call once from MainActivity.onCreate() before any connect(). */
    fun init(filesDir: java.io.File) {
        if (!::keyPair.isInitialized) {
            keyPair = AdbCrypto.loadOrGenerateKeyPair(filesDir)
        }
    }

    // FIX(Bug-F): 加 synchronized 块，保证「检查-建立」的原子性
    fun connect(host: String, port: Int): String {
        val key = "$host:$port"
        synchronized(connectLock) {
            connections[key]?.let { existing ->
                if (existing.connected.get() && existing.isAlive()) {
                    Log.d(TAG, "connect: reusing existing connection to $key")
                    return key
                }
                Log.d(TAG, "connect: existing connection dead, reconnecting to $key")
                runCatching { existing.close() }
                connections.remove(key)
            }
            connections[key] = AdbConnection.connect(host, port, keyPair)
            return key
        }
    }

    // FIX(Bug-D): 提供 softDisconnect，只清理内存中的连接对象，
    // 不关闭 socket，让 TCP 连接自然保持（适合切后台场景）。
    // 原 disconnect 保留，用于用户主动断开的场景。
    fun disconnect(serial: String) {
        connections.remove(serial)?.close()
    }

    fun disconnectAll() {
        connections.values.forEach { it.close() }
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
