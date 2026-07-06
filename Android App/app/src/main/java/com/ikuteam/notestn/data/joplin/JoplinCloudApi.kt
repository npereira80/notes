package com.ikuteam.notestn.data.joplin

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Client for Joplin Cloud's sync API (the "JoplinServer" protocol — Joplin Cloud is
 * just a hosted instance of Joplin Server). Phase 1 only needs login; item sync
 * (api/items, api/batch_items, delta cursor) is a later phase.
 *
 * Protocol reference: packages/lib/JoplinServerApi.ts in this repo's Joplin monorepo.
 */
object JoplinCloudApi {

    private const val BASE_URL = "https://api.joplincloud.com"
    private val JSON_MEDIA_TYPE = "application/json".toMediaType()
    private val json = Json { ignoreUnknownKeys = true }

    // Real Joplin clients send this on every request (see JoplinServerApi.ts's
    // exec_() — "Need server 2.6 for new lock support"). We don't do sync locks,
    // but the server may use this header to decide how much of its newer
    // processing (e.g. change-log registration for delta) to apply, so send it
    // too rather than looking like a legacy/unversioned client.
    private val client = OkHttpClient.Builder()
        .addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("X-API-MIN-VERSION", "2.6.0").build())
        }
        .build()

    @Serializable
    data class LoginResult(val id: String, val userId: String)

    @Serializable
    private data class LoginRequest(val email: String, val password: String)

    @Serializable
    private data class SessionResponse(val id: String, val user_id: String)

    @Serializable
    private data class ErrorResponse(val error: String? = null, val message: String? = null)

    sealed class LoginError : Exception() {
        object InvalidCredentials : LoginError()
        data class Other(override val message: String) : LoginError()
        data class Network(override val cause: Throwable) : LoginError()
    }

    /** POST api/sessions — email/password login, returns a session id used as the
     * X-API-AUTH header on every later sync request. */
    suspend fun login(email: String, password: String): Result<LoginResult> = withContext(Dispatchers.IO) {
        val body = json.encodeToString(LoginRequest.serializer(), LoginRequest(email, password))

        val request = Request.Builder()
            .url("$BASE_URL/api/sessions")
            .post(body.toRequestBody(JSON_MEDIA_TYPE))
            .build()

        try {
            client.newCall(request).execute().use { response ->
                val responseBody = response.body?.string().orEmpty()
                if (response.isSuccessful) {
                    val session = json.decodeFromString<SessionResponse>(responseBody)
                    Result.success(LoginResult(id = session.id, userId = session.user_id))
                } else if (response.code == 403 || response.code == 401) {
                    Result.failure(LoginError.InvalidCredentials)
                } else {
                    val error = runCatching { json.decodeFromString<ErrorResponse>(responseBody) }.getOrNull()
                    Result.failure(LoginError.Other(error?.message ?: error?.error ?: "Login failed (HTTP ${response.code})"))
                }
            }
        } catch (t: Throwable) {
            Result.failure(LoginError.Network(t))
        }
    }

    // MARK: - Sync (Phase 2, pull-only)

    @Serializable
    data class DeltaChange(
        val id: String,
        // The item's filename, e.g. "<32-char-id>.md" — this, not `id`/`item_id` (the
        // server's internal change-log row id), is what content fetches are keyed on.
        val item_name: String? = null,
        // Numeric ChangeType from Joplin's source: 1 = create, 2 = update, 3 = delete.
        val type: Int = 1,
    )

    @Serializable
    data class DeltaResponse(
        val items: List<DeltaChange> = emptyList(),
        val has_more: Boolean = false,
        val cursor: String? = null,
    )

    sealed class SyncApiError : Exception() {
        object Unauthorized : SyncApiError()
        data class Other(override val message: String) : SyncApiError()
        data class Network(override val cause: Throwable) : SyncApiError()
    }

    /** GET api/items/root:/:/delta — root:/:/  is the literal sentinel for "account
     * root" per file-api-driver-joplinServer.ts. Paginate with the returned cursor
     * until has_more is false. */
    suspend fun delta(sessionId: String, cursor: String?): Result<DeltaResponse> = withContext(Dispatchers.IO) {
        val url = "$BASE_URL/api/items/root:/:/delta" + if (cursor != null) "?cursor=$cursor" else ""
        authorizedGet(url, sessionId) { response -> json.decodeFromString<DeltaResponse>(response.body?.string().orEmpty()) }
    }

    /** GET api/items/root:/{itemName}:/content — raw serialized item text (title,
     * body, metadata footer — see JoplinItemParser). */
    suspend fun itemContent(sessionId: String, itemName: String): Result<String> = withContext(Dispatchers.IO) {
        val url = "$BASE_URL/api/items/root:/$itemName:/content"
        authorizedGet(url, sessionId) { response -> response.body?.string().orEmpty() }
    }

    /** GET api/items/root:/.resource/{resourceId}:/content — the resource's raw binary
     * blob, stored as a separate item from its `{resourceId}.md` metadata (see
     * Dirnames.Resources / resourceRemotePath() in packages/lib). Must be read as
     * bytes, not text, or the image data gets corrupted by string decoding. */
    suspend fun resourceBlob(sessionId: String, resourceId: String): Result<ByteArray> = withContext(Dispatchers.IO) {
        val url = "$BASE_URL/api/items/root:/.resource/$resourceId:/content"
        authorizedGet(url, sessionId) { response -> response.body?.bytes() ?: ByteArray(0) }
    }

    private val OCTET_STREAM = "application/octet-stream".toMediaType()

    /** PUT api/items/root:/{itemName}:/content — creates OR updates an item; Joplin
     * Server has no separate create call, a PUT at this path upserts whatever's there. */
    suspend fun putItemContent(sessionId: String, itemName: String, content: ByteArray): Result<Unit> =
        withContext(Dispatchers.IO) {
            val url = "$BASE_URL/api/items/root:/$itemName:/content"
            val request = Request.Builder()
                .url(url)
                .header("X-API-AUTH", sessionId)
                .put(content.toRequestBody(OCTET_STREAM))
                .build()
            executeForResult(request, url) { }
        }

    /** PUT api/items/root:/.resource/{resourceId}:/content — uploads a resource's raw
     * binary blob, the counterpart to resourceBlob()'s GET. Separate path from the
     * resource's own `{resourceId}.md` metadata item (pushed via putItemContent). */
    suspend fun putResourceBlob(sessionId: String, resourceId: String, content: ByteArray): Result<Unit> =
        withContext(Dispatchers.IO) {
            val url = "$BASE_URL/api/items/root:/.resource/$resourceId:/content"
            val request = Request.Builder()
                .url(url)
                .header("X-API-AUTH", sessionId)
                .put(content.toRequestBody(OCTET_STREAM))
                .build()
            executeForResult(request, url) { }
        }

    /** DELETE api/items/root:/{itemName}: — no `/content` suffix, unlike get/put. */
    suspend fun deleteItem(sessionId: String, itemName: String): Result<Unit> = withContext(Dispatchers.IO) {
        val url = "$BASE_URL/api/items/root:/$itemName:"
        val request = Request.Builder()
            .url(url)
            .header("X-API-AUTH", sessionId)
            .delete()
            .build()
        executeForResult(request, url) { }
    }

    private fun <T> executeForResult(request: Request, url: String, parse: (okhttp3.Response) -> T): Result<T> {
        return try {
            client.newCall(request).execute().use { response ->
                when {
                    // A delete for an item that's already gone (e.g. retried after a
                    // previous run succeeded but the local "pending delete" wasn't
                    // cleared) is not an error — treat 404 as success too.
                    response.isSuccessful || response.code == 404 -> Result.success(parse(response))
                    response.code == 401 || response.code == 403 -> Result.failure(SyncApiError.Unauthorized)
                    else -> Result.failure(SyncApiError.Other("Request failed (HTTP ${response.code}): $url"))
                }
            }
        } catch (t: Throwable) {
            Result.failure(SyncApiError.Network(t))
        }
    }

    private fun <T> authorizedGet(url: String, sessionId: String, parse: (okhttp3.Response) -> T): Result<T> {
        val request = Request.Builder()
            .url(url)
            .header("X-API-AUTH", sessionId)
            .get()
            .build()

        return try {
            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> Result.success(parse(response))
                    response.code == 401 || response.code == 403 -> Result.failure(SyncApiError.Unauthorized)
                    else -> Result.failure(SyncApiError.Other("Request failed (HTTP ${response.code}): $url"))
                }
            }
        } catch (t: Throwable) {
            Result.failure(SyncApiError.Network(t))
        }
    }
}
