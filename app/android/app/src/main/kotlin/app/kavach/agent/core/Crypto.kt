package app.kavach.agent.core

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/** Device identity (non-exportable P-256 in Keystore) and parent-PIN verification. */
object Crypto {
    private const val DEVICE_KEY = "kavach_device"
    private const val DB_KEY = "kavach_db"
    private val ks get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    /** Fresh keypair per pairing; returns X.509 SPKI public key, base64. */
    fun newDeviceKey(): String {
        ks.deleteEntry(DEVICE_KEY)
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(DEVICE_KEY, KeyProperties.PURPOSE_SIGN)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
        // StrongBox when the phone has it (design §8 Security); fall back silently.
        val pair = runCatching {
            if (android.os.Build.VERSION.SDK_INT >= 28) spec.setIsStrongBoxBacked(true)
            gen.initialize(spec.build()); gen.generateKeyPair()
        }.getOrElse {
            if (android.os.Build.VERSION.SDK_INT >= 28) spec.setIsStrongBoxBacked(false)
            gen.initialize(spec.build()); gen.generateKeyPair()
        }
        return Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP)
    }

    fun sign(message: String): String {
        val key = ks.getKey(DEVICE_KEY, null) as PrivateKey
        val s = Signature.getInstance("SHA256withECDSA").apply { initSign(key); update(message.toByteArray()) }
        return Base64.encodeToString(s.sign(), Base64.NO_WRAP)
    }

    fun sha256Hex(s: String): String = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    fun nonce(): String = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

    /** Constant-time PBKDF2 check against the server-made hash in the policy (ACC-8). */
    fun pinMatches(pin: String, salt: ByteArray, hash: ByteArray, iter: Int): Boolean {
        val spec = PBEKeySpec(pin.toCharArray(), salt, iter, hash.size * 8)
        val got = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        return MessageDigest.isEqual(got, hash)
    }

    /** AES key that wraps the SQLCipher passphrase. */
    fun dbWrapKey(): SecretKey {
        (ks.getKey(DB_KEY, null) as? SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(KeyGenParameterSpec.Builder(DB_KEY, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return g.generateKey()
    }
}
