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
     * Encode the public key in the exact ADB wire format expected by adbd.
     * Strictly follows AOSP platform/system/core/libcrypto_utils/android_pubkey.cpp
     *
     * Wire format: BASE64( AdbRSAPublicKey ) + " CableBee\0"
     *
     * AdbRSAPublicKey (all little-endian):
     *   uint32  len      = KEY_LENGTH_WORDS (64 for RSA-2048)
     *   uint32  n0inv    = -n[0]^{-1} mod 2^32   (Montgomery param)
     *   uint32[64] n     = modulus, little-endian 32-bit words
     *   uint32[64] rr    = R^2 mod n, R = 2^2048  (Montgomery param)
     *   uint32  exponent = 65537
     */
    fun encodePublicKey(keyPair: KeyPair): ByteArray {
        val pub      = keyPair.public as RSAPublicKey
        val modulus  = pub.modulus
        val KEY_WORDS = 64
        val KEY_BYTES = KEY_WORDS * 4  // 256 bytes

        // ── n0inv = -n^{-1} mod 2^32 ──────────────────────────────────────
        val r32   = java.math.BigInteger.ONE.shiftLeft(32)
        val mask  = r32.subtract(java.math.BigInteger.ONE)
        val n0inv = r32.subtract(modulus.modInverse(r32)).and(mask).toLong().toInt()

        // ── BigInteger → little-endian 32-bit word array (256 bytes) ──────
        // BigInteger.toByteArray() is big-endian, may have a leading 0x00 sign byte.
        // We need exactly KEY_BYTES bytes, right-aligned (zero-padded on the left
        // for big-endian), then byte-reversed to get little-endian.
        fun bigIntToLeWords(bi: java.math.BigInteger): ByteArray {
            val be   = bi.toByteArray()
            // strip leading sign byte if present
            val trim = if (be[0] == 0.toByte()) be.copyOfRange(1, be.size) else be
            // allocate zeroed buffer, copy trim right-aligned (big-endian layout)
            val buf  = ByteArray(KEY_BYTES)  // zero-filled
            val len  = minOf(trim.size, KEY_BYTES)
            System.arraycopy(trim, trim.size - len, buf, KEY_BYTES - len, len)
            // byte-reverse to get little-endian
            buf.reverse()
            return buf
        }

        val nBytes  = bigIntToLeWords(modulus)

        // ── rr = R^2 mod n, R = 2^2048 ───────────────────────────────────
        val R       = java.math.BigInteger.ONE.shiftLeft(KEY_WORDS * 32)
        val rr      = R.multiply(R).mod(modulus)
        val rrBytes = bigIntToLeWords(rr)

        // ── assemble AdbRSAPublicKey struct ───────────────────────────────
        val struct = java.nio.ByteBuffer.allocate(4 + 4 + KEY_BYTES + KEY_BYTES + 4)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
        struct.putInt(KEY_WORDS)
        struct.putInt(n0inv)
        struct.put(nBytes)
        struct.put(rrBytes)
        struct.putInt(pub.publicExponent.toInt())

        // ── wire format: base64(struct) + " CableBee\0" ───────────────────
        val b64 = android.util.Base64.encodeToString(struct.array(), android.util.Base64.NO_WRAP)
        return "$b64 CableBee\u0000".toByteArray(Charsets.UTF_8)
    }
}
