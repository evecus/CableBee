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
    const val SYNC = 0x434e5953u  // SYNC
    const val CNXN = 0x4e584e43u  // CNXN - CONNECT
    const val AUTH = 0x48545541u  // AUTH
    const val OPEN = 0x4e45504fu  // OPEN
    const val OKAY = 0x59414b4fu  // OKAY
    const val CLSE = 0x45534c43u  // CLSE
    const val WRTE = 0x45545257u  // WRTE

    // AUTH types
    const val AUTH_TOKEN     = 1u
    const val AUTH_SIGNATURE = 2u
    const val AUTH_RSAPUBLICKEY = 3u

    // Protocol version
    const val VERSION    = 0x01000000u
    const val MAX_PAYLOAD = 1_048_576u      // 1MB (1024 * 1024)
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
            buf.int  // checksum (skip verify for perf)
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
     * Persisting the key means the device only shows the "Allow USB debugging" dialog once.
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
        // Generate fresh pair and persist
        val kpg = KeyPairGenerator.getInstance("RSA")
        kpg.initialize(2048)
        val kp = kpg.generateKeyPair()
        filesDir.mkdirs()
        privFile.writeBytes(kp.private.encoded)
        pubFile.writeBytes(kp.public.encoded)
        return kp
    }

    /** Generate a new in-memory key pair (fallback, not persisted). */
    fun generateKeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("RSA")
        kpg.initialize(2048)
        return kpg.generateKeyPair()
    }

    /**
     * Sign an AUTH token with our private key using RSASSA-PKCS1-v1_5 / SHA-1.
     * ADB actually uses raw PKCS#1 v1.5 signing on the 20-byte SHA-1 hash.
     */
    fun sign(keyPair: KeyPair, token: ByteArray): ByteArray {
        val sig = java.security.Signature.getInstance("SHA1withRSA")
        sig.initSign(keyPair.private)
        sig.update(token)
        return sig.sign()
    }

    /**
     * Encode the public key in the exact ADB wire format expected by adbd:
     *   BASE64( AdbRSAPublicKey ) + " CableBee\0"
     *
     * AdbRSAPublicKey (little-endian, all fields 32-bit unless noted):
     *   uint32 len          — number of 32-bit words in the modulus (KEY_LENGTH_WORDS = 64 for 2048-bit)
     *   uint32 n0inv        — -n[0]^-1 mod 2^32  (Montgomery constant)
     *   uint32[64] n        — modulus, little-endian words
     *   uint32[64] rr       — R^2 mod n (Montgomery constant), little-endian words
     *   uint32 exponent     — public exponent (always 65537)
     *
     * Reference: platform/system/core/libcrypto_utils/android_pubkey.cpp
     */
    fun encodePublicKey(keyPair: KeyPair): ByteArray {
        val pub = keyPair.public as RSAPublicKey
        val modulus  = pub.modulus              // BigInteger, positive
        val exponent = pub.publicExponent.toInt()

        val KEY_LENGTH_WORDS = 64               // 2048 bits / 32 bits per word
        val KEY_LENGTH_BYTES = KEY_LENGTH_WORDS * 4

        // --- n0inv = -n[0]^-1 mod 2^32 ---
        val r32 = java.math.BigInteger.ONE.shiftLeft(32)
        val n0  = modulus.mod(r32).toLong()
        // Modular inverse of n0 mod 2^32
        var inv = 1L
        for (i in 1..31) inv = inv * inv * n0 % (1L shl 32) // using Hensel lifting via BigInteger
        val n0inv = (r32 - modulus.modInverse(r32)).toLong().and(0xFFFFFFFFL).toInt()

        // --- n[]: modulus in little-endian 32-bit words ---
        val nBytes = ByteArray(KEY_LENGTH_BYTES)
        val modBytes = modulus.toByteArray()
        // modBytes may have a leading 0x00 sign byte — strip it
        val stripped = if (modBytes[0] == 0.toByte()) modBytes.copyOfRange(1, modBytes.size) else modBytes
        // Copy big-endian bytes into nBytes reversed (little-endian)
        val srcStart = maxOf(0, stripped.size - KEY_LENGTH_BYTES)
        val dstStart = KEY_LENGTH_BYTES - (stripped.size - srcStart)
        System.arraycopy(stripped, srcStart, nBytes, dstStart, stripped.size - srcStart)
        nBytes.reverse()  // now little-endian

        // --- rr[]: R^2 mod n, where R = 2^(KEY_LENGTH_WORDS*32) ---
        val R   = java.math.BigInteger.ONE.shiftLeft(KEY_LENGTH_WORDS * 32)
        val rr  = R.multiply(R).mod(modulus)
        val rrBytes = ByteArray(KEY_LENGTH_BYTES)
        val rrRaw = rr.toByteArray()
        val rrStripped = if (rrRaw[0] == 0.toByte()) rrRaw.copyOfRange(1, rrRaw.size) else rrRaw
        val rSrcStart = maxOf(0, rrStripped.size - KEY_LENGTH_BYTES)
        val rDstStart = KEY_LENGTH_BYTES - (rrStripped.size - rSrcStart)
        System.arraycopy(rrStripped, rSrcStart, rrBytes, rDstStart, rrStripped.size - rSrcStart)
        rrBytes.reverse()  // little-endian

        // --- Assemble struct ---
        val buf = java.nio.ByteBuffer.allocate(4 + 4 + KEY_LENGTH_BYTES + KEY_LENGTH_BYTES + 4)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
        buf.putInt(KEY_LENGTH_WORDS)
        buf.putInt(n0inv)
        buf.put(nBytes)
        buf.put(rrBytes)
        buf.putInt(exponent)

        val b64 = Base64.encodeToString(buf.array(), Base64.NO_WRAP)
        return "$b64 CableBee\u0000".toByteArray(Charsets.UTF_8)
    }
}
