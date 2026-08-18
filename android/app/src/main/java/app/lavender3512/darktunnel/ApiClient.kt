package app.lavender3512.darktunnel

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Base64
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.TimeUnit

data class SubscriptionInfo(
    val daysLeft: String,
    val lifetime: Boolean,
    val expiresAt: String,
)

class ApiClient(private val context: Context) {
    private val prefs = context.getSharedPreferences("darktunnel", Context.MODE_PRIVATE)
    private val secure = SecureStore(context)
    private val gson = Gson()
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()
    val base = "https://api.31-77-148-80.sslip.io"

    private fun installationId(): String =
        prefs.getString("installation_id", null)?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString().lowercase()
                .also { prefs.edit().putString("installation_id", it).apply() }

    private fun publicKey(): String =
        prefs.getString("public_key", null)?.takeIf { it.isNotBlank() }
            ?: ByteArray(32).also { SecureRandom().nextBytes(it) }
                .let { Base64.encodeToString(it, Base64.NO_WRAP) }
                .also { prefs.edit().putString("public_key", it).apply() }

    fun deviceToken(): String? =
        secure.getString("refresh_token")?.takeIf { it.isNotBlank() }

    fun isActivated(): Boolean = !deviceToken().isNullOrBlank()

    fun subscriptionInfo(): SubscriptionInfo {
        val raw = prefs.getString("expires_at", "").orEmpty()
        val lifetime = prefs.getBoolean("lifetime", false)
        if (lifetime) return SubscriptionInfo("∞", true, "Навсегда")
        if (raw.isBlank()) return SubscriptionInfo("—", false, "—")
        return try {
            val exp = Instant.parse(raw)
            val now = Instant.now()
            val days = ChronoUnit.DAYS.between(now, exp)
            when {
                days < 0  -> SubscriptionInfo("Истекла", false, raw)
                days == 0L -> SubscriptionInfo("Сегодня", false, raw)
                else      -> SubscriptionInfo("$days дн.", false, raw)
            }
        } catch (e: Exception) {
            SubscriptionInfo("—", false, raw)
        }
    }

    fun activate(rawInput: String): Result<Activation> = runCatching {
        val value = rawInput.trim()
        require(value.isNotEmpty()) { "Вставьте код или ссылку активации из Telegram" }
        val token = normalizeToken(value)
            ?: throw IllegalArgumentException("Не удалось распознать ссылку или код")
        redeemActivation(token)
    }

    fun servers(): Result<List<Server>> = runCatching {
        val token = deviceToken() ?: throw IllegalStateException("Нет активной подписки")
        val url = "$base/v1/subscription/servers?installation_id=${Uri.encode(installationId())}"
        val req = Request.Builder().url(url)
            .header("X-Device-Token", token)
            .header("Accept", "application/json")
            .get().build()
        http.newCall(req).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful) {
                if (response.code == 401 || response.code == 403) secure.remove("refresh_token")
                throw IllegalStateException("${apiError(text, "Ошибка загрузки серверов")} (HTTP ${response.code})")
            }
            val arr = parseObject(text, "Некорректный список серверов").getAsJsonArray("servers")
                ?: throw IllegalStateException("Нет серверов в ответе")
            arr.mapNotNull { runCatching { parseServer(it.asJsonObject) }.getOrNull() }
                .filter { it.id.isNotBlank() && it.host.isNotBlank() && it.port in 1..65535 }
                .also { if (it.isEmpty()) throw IllegalStateException("Нет доступных серверов") }
        }
    }

    /** Measure real latency to server host:port via TCP */
    fun ping(host: String, port: Int): Int? = try {
        val start = System.currentTimeMillis()
        Socket().use { s ->
            s.connect(InetSocketAddress(host, port), 4000)
        }
        (System.currentTimeMillis() - start).toInt()
    } catch (e: Exception) { null }

    fun clear() { secure.clear(); prefs.edit().clear().apply() }

    private fun redeemActivation(token: String): Activation {
        val body = gson.toJson(mapOf(
            "token" to token,
            "installation_id" to installationId(),
            "public_key" to publicKey(),
            "app_version" to BuildConfig.VERSION_NAME,
            "ios_version" to "",
        )).toRequestBody("application/json".toMediaType())
        val req = Request.Builder().url("$base/v1/activation/redeem").post(body)
            .header("Accept", "application/json").build()
        return http.newCall(req).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful)
                throw IllegalStateException("${apiError(text, "Не удалось активировать")} (HTTP ${response.code})")
            val obj = parseObject(text, "Некорректный ответ сервера")
            val refresh = obj["refresh_token"]?.asString?.trim()?.takeIf { it.isNotEmpty() }
                ?: throw IllegalStateException("Сервер не выдал токен")
            val expires = obj["subscription_expires_at"]?.asString.orEmpty()
            val lifetime = obj["lifetime"]?.asBoolean ?: false
            val serverObj = obj.getAsJsonObject("server")
                ?: throw IllegalStateException("В ответе нет данных сервера")
            secure.putString("refresh_token", refresh)
            prefs.edit()
                .putString("expires_at", expires)
                .putBoolean("lifetime", lifetime)
                .apply()
            Activation(expires, refresh, parseServer(serverObj))
        }
    }

    private fun normalizeToken(raw: String): String? {
        val v = raw.trim().trim('<', '>', '"', '\'')
        if (v.isEmpty()) return null
        listOf("darktunnel://activate", "darktunnel://subscription").forEach { marker ->
            val idx = v.indexOf(marker, ignoreCase = true)
            if (idx >= 0) {
                val uri = runCatching { Uri.parse(v.substring(idx).takeWhile { !it.isWhitespace() }) }.getOrNull()
                if (uri != null) {
                    val t = listOf("d", "t", "token", "code")
                        .firstNotNullOfOrNull { uri.getQueryParameter(it)?.trim()?.takeIf(String::isNotEmpty) }
                    if (t != null) return t
                }
            }
        }
        return v.takeIf { it.isNotBlank() }
    }

    private fun parseObject(text: String, fallback: String): JsonObject =
        runCatching { JsonParser.parseString(text).asJsonObject }
            .getOrElse { throw IllegalStateException("$fallback. Попробуйте ещё раз.") }

    private fun apiError(text: String, fallback: String): String =
        runCatching { JsonParser.parseString(text).asJsonObject.let { it["detail"]?.asString ?: it["message"]?.asString } }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: fallback

    fun parseServer(s: JsonObject) = Server(
        id            = s["id"]?.asString.orEmpty(),
        name          = s["name"]?.asString.orEmpty(),
        country       = s["country_name"]?.asString.orEmpty(),
        city          = s["city"]?.asString.orEmpty(),
        flag          = flag(s["country_code"]?.asString.orEmpty()),
        host          = s["host"]?.asString.orEmpty(),
        port          = s["port"]?.asInt ?: 0,
        online        = s["online"]?.asBoolean ?: true,
        latencyMs     = s["latency_ms"]?.takeUnless { it.isJsonNull }?.asInt,
        amneziaConfig = s["amnezia_config"]?.takeUnless { it.isJsonNull }?.asString,
        latitude      = s["latitude"]?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
        longitude     = s["longitude"]?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
    )

    private fun flag(code: String): String {
        if (code.length != 2) return "🌐"
        return code.uppercase().map { Character.toChars(127397 + it.code).concatToString() }.joinToString("")
    }
}
