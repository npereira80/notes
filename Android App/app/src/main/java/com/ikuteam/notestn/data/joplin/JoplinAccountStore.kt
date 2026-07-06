package com.ikuteam.notestn.data.joplin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class JoplinAccount(val email: String, val sessionId: String, val userId: String)

/**
 * Persists the Joplin Cloud session (email + session id + user id) to disk, encrypted
 * with an Android Keystore AES-GCM key. This avoids the now-deprecated
 * androidx.security:security-crypto (EncryptedSharedPreferences) without pulling in
 * a heavier replacement (e.g. Tink) just to protect one short string.
 *
 * A true app-wide singleton (see `init`/`shared` below) — not just "one instance per
 * screen". Compose Navigation's `viewModel()` scopes to the current back-stack entry,
 * so Settings and Login previously each got their own JoplinAccountViewModel and thus
 * their own JoplinAccountStore with its own in-memory StateFlow: logging in updated
 * Login's copy on disk, but Settings' already-composed copy never heard about it,
 * making a successful login look like it silently did nothing.
 */
class JoplinAccountStore private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("joplin_account", Context.MODE_PRIVATE)

    private val _account = MutableStateFlow(loadAccount())
    val account: StateFlow<JoplinAccount?> = _account

    fun save(account: JoplinAccount) {
        prefs.edit()
            .putString(KEY_EMAIL, account.email)
            .putString(KEY_USER_ID, account.userId)
            .putString(KEY_SESSION_ID, encrypt(account.sessionId))
            .apply()
        _account.value = account
    }

    fun clear() {
        prefs.edit().clear().apply()
        _account.value = null
    }

    private fun loadAccount(): JoplinAccount? {
        val email = prefs.getString(KEY_EMAIL, null) ?: return null
        val userId = prefs.getString(KEY_USER_ID, null) ?: return null
        val encryptedSessionId = prefs.getString(KEY_SESSION_ID, null) ?: return null
        val sessionId = runCatching { decrypt(encryptedSessionId) }.getOrNull() ?: return null
        return JoplinAccount(email = email, sessionId = sessionId, userId = userId)
    }

    // MARK: - Android Keystore AES-GCM helpers

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return keyGenerator.generateKey()
    }

    private fun encrypt(plainText: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, getOrCreateKey()) }
        val cipherText = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        // Store iv + ciphertext together since GCM needs the same iv to decrypt.
        val combined = cipher.iv + cipherText
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        val iv = combined.copyOfRange(0, GCM_IV_LENGTH)
        val cipherText = combined.copyOfRange(GCM_IV_LENGTH, combined.size)
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        }
        return String(cipher.doFinal(cipherText), Charsets.UTF_8)
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "joplin_account_session_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_LENGTH = 12
        private const val GCM_TAG_LENGTH_BITS = 128
        private const val KEY_EMAIL = "email"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_SESSION_ID = "session_id"

        @Volatile
        private var instance: JoplinAccountStore? = null

        fun init(context: Context) {
            if (instance == null) {
                synchronized(this) {
                    if (instance == null) instance = JoplinAccountStore(context)
                }
            }
        }

        val shared: JoplinAccountStore
            get() = instance ?: throw IllegalStateException(
                "JoplinAccountStore.init(context) must be called before use — see NotesTNApplication.onCreate()."
            )
    }
}
