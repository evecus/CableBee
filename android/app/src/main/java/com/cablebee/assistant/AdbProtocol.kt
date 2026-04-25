package com.cablebee.assistant

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.File
import java.security.KeyPair
import java.security.KeyFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.interfaces.RSAPublicKey
import android.util.Base64

// ── ADB Message constants ────────────────────────────────────────────────────

object AdbCmd {
    const val SYNC = 0x434e5953u
    const val CNXN = 0x4e584e43u
    const val AUTH = 0x48545541u
    const val OPEN = 0x4e45504fu
    const val OKAY = 0x59414b4fu
    const val CLSE = 0x45534c43u
    const val WRTE = 0x45545257u

    const val AUTH_TOKEN        = 1u
    const val AUTH_SIGNATURE    = 2u
    const val AUTH_RSAPUBLICKEY = 3u

    const val VERSION    = 0x01000000u
    const val MAX_PAYLOAD = 1_048_576u
}

// ── Raw ADB message (24-byte header + payload) ───────────────────────────────

data class AdbMessage(
    val command: UInt,
    val arg0:    UInt,
    val arg1:    UInt,
    val data:    ByteArray = ByteArray(0)
) {
    val magic: UInt get() = command xor 0xFFFFFFFFu

    fun checksum(): UInt {
        var s = 0u
        for (b in data) s += (b.toUInt() and 0xFFu)
        return s
    }

    fun writeTo(out: OutputStream) {
        val buf = ByteBuffer.allocate(24 + data.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(command.toInt())
        buf.putInt(arg0.toInt())
        buf.putInt(arg1.toInt())
        buf.putInt(data.size)
        buf.putInt(checksum().toInt())
        buf.putInt(magic.toInt())
        if (data.isNotEmpty()) buf.put(data)
        out.write(buf.array())
        out.flush()
    }

    companion object {
        fun readFrom(inp: InputStream): AdbMessage {
            val header = inp.readExactly(24)
            val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val cmd  = buf.int.toUInt()
            val arg0 = buf.int.toUInt()
            val arg1 = buf.int.toUInt()
            val len  = buf.int
            buf.int  // checksum
            buf.int  // magic
            val data = if (len > 0) inp.readExactly(len) else ByteArray(0)
            return AdbMessage(cmd, arg0, arg1, data)
        }
    }
}

private fun InputStream.readExactly(n: Int): ByteArray {
    val buf = ByteArray(n)
    var off = 0
    while (off < n) {
        val r = read(buf, off, n - off)
        if (r == -1) throw java.io.EOFException("Stream ended early (wanted $n, got $off)")
        off += r
    }
    return buf
}

// ── RSA key helpers (for AUTH handshake) ─────────────────────────────────────

object AdbCrypto {

    /**
     * Load persisted RSA-2048 key pair from filesDir, or generate and save a new one.
     * Persisting the key means the device only shows the "Allow USB debugging" dialog once
     * (provided the user ticks "Always allow").
     */
    fun loadOrGenerateKeyPair(filesDir: File): KeyPair {
        val privFile = File(filesDir, "adb_key.pk8")
        val pubFile  = File(filesDir, "adb_key.pub")
        if (privFile.exists() && pubFile.exists()) {
            runCatching {
                val kf = KeyFactory.getInstance("RSA")
                val priv = kf.generatePrivate(PKCS8EncodedKeySpec(privFile.readBytes()))
                val pub  = kf.generatePublic(X509EncodedKeySpec(pubFile.readBytes()))
                return KeyPair(pub, priv)
            }
        }
        val kpg = KeyPairGenerator.getInstance("RSA")
        kpg.initialize(2048)
        val kp = kpg.generateKeyPair()
        filesDir.mkdirs()
        privFile.writeBytes(kp.private.encoded)
        pubFile.writeBytes(kp.public.encoded)
        return kp
    }

    fun sign(keyPair: KeyPair, token: ByteArray): ByteArray {
        val sig = java.security.Signature.getInstance("SHA1withRSA")
        sig.initSign(keyPair.private)
        sig.update(token)
        return sig.sign()
    }

    /**
     * Encode the public key in the ADB wire format expected by adbd.
     *
     * Format: BASE64(AdbRSAPublicKey) + " CableBee\n"
     *
     * FIX(Bug-B): 原代码末尾用 \u0000（null byte），导致 adbd 将公钥写入
     * /data/misc/adb/adb_keys 时没有换行符。adbd 按 \n 分行读取该文件，
     * 缺少 \n 会导致多个公钥被拼成一行，后续公钥匹配失败，每次重连都弹窗。
     * 修复：末尾改为 \n，与官方 adb 客户端行为一致。
     *
     * AdbRSAPublicKey struct (all little-endian 32-bit words):
     *   uint32  len        — modulus word count (64 for 2048-bit)
     *   uint32  n0inv      — -n[0]^-1 mod 2^32
     *   uint32[64] n       — modulus, little-endian words
     *   uint32[64] rr      — R^2 mod n (Montgomery constant)
     *   uint32  exponent   — public exponent (65537)
     *
     * Reference: platform/system/core/libcrypto_utils/android_pubkey.cpp
     */
    fun encodePublicKey(keyPair: KeyPair): ByteArray {
        val pub = keyPair.public as RSAPublicKey
        val modulus  = pub.modulus
        val exponent = pub.publicExponent.toInt()

        val KEY_LENGTH_WORDS = 64
        val KEY_LENGTH_BYTES = KEY_LENGTH_WORDS * 4

        val r32   = java.math.BigInteger.ONE.shiftLeft(32)
        val n0inv = (r32 - modulus.modInverse(r32)).toLong().and(0xFFFFFFFFL).toInt()

        val nBytes   = ByteArray(KEY_LENGTH_BYTES)
        val modBytes = modulus.toByteArray()
        val stripped = if (modBytes[0] == 0.toByte()) modBytes.copyOfRange(1, modBytes.size) else modBytes
        val srcStart = maxOf(0, stripped.size - KEY_LENGTH_BYTES)
        val dstStart = KEY_LENGTH_BYTES - (stripped.size - srcStart)
        System.arraycopy(stripped, srcStart, nBytes, dstStart, stripped.size - srcStart)
        nBytes.reverse()

        val R       = java.math.BigInteger.ONE.shiftLeft(KEY_LENGTH_WORDS * 32)
        val rr      = R.multiply(R).mod(modulus)
        val rrBytes = ByteArray(KEY_LENGTH_BYTES)
        val rrRaw   = rr.toByteArray()
        val rrStripped = if (rrRaw[0] == 0.toByte()) rrRaw.copyOfRange(1, rrRaw.size) else rrRaw
        val rSrcStart  = maxOf(0, rrStripped.size - KEY_LENGTH_BYTES)
        val rDstStart  = KEY_LENGTH_BYTES - (rrStripped.size - rSrcStart)
        System.arraycopy(rrStripped, rSrcStart, rrBytes, rDstStart, rrStripped.size - rSrcStart)
        rrBytes.reverse()

        val buf = java.nio.ByteBuffer.allocate(4 + 4 + KEY_LENGTH_BYTES + KEY_LENGTH_BYTES + 4)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
        buf.putInt(KEY_LENGTH_WORDS)
        buf.putInt(n0inv)
        buf.put(nBytes)
        buf.put(rrBytes)
        buf.putInt(exponent)

        val b64 = Base64.encodeToString(buf.array(), Base64.NO_WRAP)

        // FIX(Bug-B): 末尾必须是 \n，不能是 \0
        // adbd 用 \n 分行存储 adb_keys，\0 会导致公钥持久化后无法被正确读取
        return "$b64 CableBee\n".toByteArray(Charsets.UTF_8)
    }
}
