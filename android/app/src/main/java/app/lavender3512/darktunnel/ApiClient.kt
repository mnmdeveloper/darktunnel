package app.lavender3512.darktunnel

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Base64
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.TimeUnit

class ApiClient(private val context: Context) {
    private val prefs = context.getSharedPreferences("darktunnel", Context.MODE_PRIVATE)
    private val secure = SecureStore(context)
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()
    private val base = "https://api.31-77-148-80.sslip.io"

    // ── Device identity ──────────────────────────────────────────────────────
    private fun installationId(): String =
        prefs.getString("installation_id", null)?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString().lowercase()
                .also { prefs.edit().putString("installation_id", it).apply() }

    private fun publicKey(): String =
        prefs.getString("public_key", null)?.takeIf { it.isNotBlank() }
            ?: ByteArray(32).also { SecureRandom().nextBytes(it) }
                .let { Base64.encodeToString(it, Base64.NO_WRAP) }
                .also { prefs.edit().putString("public_key", it).apply() }

    private fun deviceToken(): String? =
        secure.getString("refresh_token")?.takeIf { it.isNotBlank() }

    // ── Public API ───────────────────────────────────────────────────────────
    fun isActivated(): Boolean = !deviceToken().isNullOrBlank()

    /**
     * Accepts:
     *   darktunnel://activate?d=TOKEN   (from Telegram — same as iOS)
     *   plain activation code/token     (raw string)
     *
     * darktunnel://subscription?t=... is a subscription management link,
     * NOT an activation link — same distinction as iOS.
     */
    fun activate(rawInput: String): Result<Activation> = runCatching {
        val value = rawInput.trim()
        require(value.isNotEmpty()) { "Вставьте код или ссылку активации из Telegram" }

        val token = normalizeActivationToken(value)
            ?: throw IllegalArgumentException("Не удалось распознать ссылку или код активации")

        redeemActivation(token)
    }

    fun servers(): Result<List<Server>> = runCatching {
        val token = deviceToken()
            ?: throw IllegalStateException("Нет активной подписки")
        val url = "$base/v1/subscription/servers?installation_id=${Uri.encode(installationId())}"
        val req = Request.Builder()
            .url(url)
            .header("X-Device-Token", token)
            .header("Accept", "application/json")
            .get()
            .build()
        http.newCall(req).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful) {
                if (response.code == 401 || response.code == 403)
                    secure.remove("refresh_token")
                throw IllegalStateException(
                    "${apiError(text, "Сессия подписки недействительна")} (HTTP ${response.code})"
                )
            }
            val arr = parseObject(text, "Список серверов некорректен")
                .getAsJsonArray("servers")
                ?: throw IllegalStateException("Сервер не вернул список серверов")
            arr.mapNotNull { runCatching { parseServer(it.asJsonObject) }.getOrNull() }
                .filter { it.id.isNotBlank() && it.host.isNotBlank() && it.port in 1..65535 }
                .also { if (it.isEmpty()) throw IllegalStateException("Нет доступных серверов") }
        }
    }

    fun clear() { secure.clear(); prefs.edit().clear().apply() }

    // ── Activation ───────────────────────────────────────────────────────────
    private fun redeemActivation(token: String): Activation {
        val body = mapOf(
            "token"           to token,
            "installation_id" to installationId(),
            "public_key"      to publicKey(),
            "app_version"     to BuildConfig.VERSION_NAME,
            "ios_version"     to ""          // field name kept for API compat
        )
        val json = com.google.gson.Gson().toJson(body)
            .toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url("$base/v1/activation/redeem")
            .post(json)
            .header("Accept", "application/json")
            .build()
        return http.newCall(req).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful)
                throw IllegalStateException(
                    "${apiError(text, "Не удалось активировать")} (HTTP ${response.code})"
                )
            val obj = parseObject(text, "Сервер вернул некорректный ответ")
            val refresh = obj["refresh_token"]?.asString?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: throw IllegalStateException("Сервер не выдал токен устройства")
            val expires = obj["subscription_expires_at"]?.asString.orEmpty()
            val serverObj = obj.getAsJsonObject("server")
                ?: throw IllegalStateException("В ответе нет данных сервера")
            val server = parseServer(serverObj)
            secure.putString("refresh_token", refresh)
            secure.putString("activation_token", token)
            prefs.edit().putString("expires_at", expires).apply()
            Activation(expires, refresh, server)
        }
    }

    // ── Token normalization (mirrors iOS normalizeActivationToken) ─────────
    private fun normalizeActivationToken(raw: String): String? {
        var value = raw.trim().trim('<', '>', '"', '\'', '`')
        if (value.isEmpty()) return null

        // Extract from darktunnel://activate?d=TOKEN
        val activateMarker = value.indexOf("darktunnel://activate", ignoreCase = true)
        if (activateMarker >= 0) {
            val candidate = value.substring(activateMarker).takeWhile { !it.isWhitespace() }
            val uri = runCatching { Uri.parse(candidate) }.getOrNull()
            if (uri != null) {
                val t = listOf("d", "token", "code")
                    .firstNotNullOfOrNull { uri.getQueryParameter(it)?.trim()?.takeIf(String::isNotEmpty) }
                if (t != null) return t
            }
        }

        // Percent-decoded fallback
        val decoded = Uri.decode(value)
        if (decoded != value) {
            val t = normalizeActivationToken(decoded)
            if (!t.isNullOrEmpty()) return t
        }

        // Plain token — same as iOS: just return it as-is
        return value.takeIf { it.isNotBlank() }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────
    private fun parseObject(text: String, fallback: String): JsonObject =
        runCatching { JsonParser.parseString(text).asJsonObject }
            .getOrElse { throw IllegalStateException("$fallback. Попробуйте ещё раз.") }

    private fun apiError(text: String, fallback: String): String =
        runCatching {
            val o = JsonParser.parseString(text).asJsonObject
            o["detail"]?.asString ?: o["message"]?.asString
        }.getOrNull()?.takeIf { it.isNotBlank() } ?: fallback

    private fun parseServer(s: JsonObject) = Server(
        id          = s["id"]?.asString.orEmpty(),
        name        = s["name"]?.asString.orEmpty(),
        country     = s["country_name"]?.asString.orEmpty(),
        city        = s["city"]?.asString.orEmpty(),
        flag        = flag(s["country_code"]?.asString.orEmpty()),
        host        = s["host"]?.asString.orEmpty(),
        port        = s["port"]?.asInt ?: 0,
        online      = s["online"]?.asBoolean ?: true,
        latencyMs   = s["latency_ms"]?.takeUnless { it.isJsonNull }?.asInt,
        amneziaConfig = s["amnezia_config"]?.takeUnless { it.isJsonNull }?.asString
    )

    private fun flag(code: String): String {
        if (code.length != 2) return "🌐"
        return code.uppercase().map {
            Character.toChars(127397 + it.code).concatToString()
        }.joinToString("")
    }
}
