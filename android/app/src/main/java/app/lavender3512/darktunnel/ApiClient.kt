package app.lavender3512.darktunnel

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Base64
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.TimeUnit

class ApiClient(private val context: Context) {
    private val prefs = context.getSharedPreferences("darktunnel", Context.MODE_PRIVATE)
    private val secure = SecureStore(context)
    private val gson = Gson()
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
    private val base = "https://api.31-77-148-80.sslip.io"

    private fun installationId(): String = prefs.getString("installation_id", null)
        ?.takeIf { it.isNotBlank() }
        ?: UUID.randomUUID().toString().lowercase().also { prefs.edit().putString("installation_id", it).apply() }

    private fun publicKey(): String = prefs.getString("public_key", null)
        ?.takeIf { it.isNotBlank() }
        ?: ByteArray(32).also { SecureRandom().nextBytes(it) }
            .let { Base64.encodeToString(it, Base64.NO_WRAP) }
            .also { prefs.edit().putString("public_key", it).apply() }

    private fun secret(name: String): String? {
        secure.getString(name)?.takeIf { it.isNotBlank() }?.let { return it }
        val legacy = prefs.getString(name, null)?.takeIf { it.isNotBlank() }
        if (legacy != null) { secure.putString(name, legacy); prefs.edit().remove(name).apply() }
        return legacy
    }

    fun isActivated(): Boolean = !secret("refresh_token").isNullOrBlank()
    fun activationToken(): String? = secret("activation_token")

    fun activate(rawToken: String): Result<Activation> = runCatching {
        val value = rawToken.trim()
        require(value.isNotEmpty()) { "Вставьте ссылку подписки или код доступа" }
        val subscriptionToken = extractSubscriptionToken(value)
        if (subscriptionToken != null) return@runCatching redeemSubscription(subscriptionToken)

        val plain = extractPlainToken(value)
        if (plain.isNotEmpty()) {
            try { return@runCatching redeemSubscription(plain) }
            catch (_: Throwable) { return@runCatching redeemActivation(plain) }
        }
        redeemActivation(normalizeActivationToken(value))
    }

    private fun requestBody(token: String) = gson.toJson(mapOf(
        "token" to token,
        "installation_id" to installationId(),
        "public_key" to publicKey(),
        "app_version" to BuildConfig.VERSION_NAME,
        "android_version" to Build.VERSION.RELEASE
    )).toRequestBody("application/json".toMediaType())

    private fun redeemActivation(token: String): Activation {
        require(token.isNotEmpty()) { "Вставьте код или ссылку подписки" }
        val request = Request.Builder().url("$base/v1/activation/redeem").post(requestBody(token))
            .header("Accept", "application/json").build()
        return executeActivationRequest(request, token)
    }

    private fun redeemSubscription(token: String): Activation {
        require(token.isNotEmpty()) { "Ссылка подписки пустая" }
        val request = Request.Builder().url("$base/v1/subscription/access/redeem").post(requestBody(token))
            .header("Accept", "application/json").build()
        return executeActivationRequest(request, token)
    }

    private fun executeActivationRequest(request: Request, storedToken: String): Activation {
        http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful) throw IllegalStateException("${activationError(text)} (HTTP ${response.code})")
            val objectResponse = parseObject(text, "Сервер авторизации вернул некорректный ответ")
            val serverObject = objectResponse.getAsJsonObject("server")
                ?: throw IllegalStateException("В ответе авторизации нет сервера")
            val server = parseServer(serverObject)
            validateServer(server)
            val refresh = objectResponse["refresh_token"]?.asString?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: throw IllegalStateException("Сервер не выдал токен устройства")
            val expires = objectResponse["subscription_expires_at"]?.asString.orEmpty()
            secure.putString("refresh_token", refresh)
            secure.putString("activation_token", storedToken)
            prefs.edit().putString("expires_at", expires).apply()
            Activation(expires, refresh, server)
        }
    }

    fun servers(): Result<List<Server>> = runCatching {
        val token = secret("refresh_token") ?: throw IllegalStateException("Нет активной подписки")
        val request = Request.Builder()
            .url("$base/v1/subscription/servers?installation_id=${Uri.encode(installationId())}")
            .header("X-Device-Token", token)
            .header("Accept", "application/json")
            .get()
            .build()
        http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful) {
                if (response.code == 401 || response.code == 403) secure.remove("refresh_token")
                throw IllegalStateException("${apiError(text, "Сессия подписки недействительна")} (HTTP ${response.code})")
            }
            val objectResponse = parseObject(text, "Список серверов имеет некорректный формат")
            val parsed = objectResponse.getAsJsonArray("servers")?.mapNotNull { element ->
                runCatching { parseServer(element.asJsonObject) }.getOrNull()
            } ?: emptyList()
            val servers = parsed.filter { server ->
                server.id.isNotBlank() &&
                    server.host.isNotBlank() &&
                    server.port in 1..65535 &&
                    !server.amneziaConfig.isNullOrBlank()
            }
            if (servers.isEmpty()) {
                throw IllegalStateException("Подписка активна, но готовых AmneziaWG-серверов пока нет")
            }
            servers
        }
    }

    fun clear() { secure.clear(); prefs.edit().clear().apply() }

    private fun extractSubscriptionToken(raw: String): String? {
        val marker = "darktunnel://subscription"
        val index = raw.indexOf(marker, ignoreCase = true)
        val candidate = if (index >= 0) raw.substring(index).takeWhile { !it.isWhitespace() && it != '<' && it != '>' && it != '"' && it != '\'' } else raw
        return fromUri(candidate, "subscription", listOf("t", "token", "code", "d"))
            ?: runCatching { Uri.decode(candidate) }.getOrNull()?.let { fromUri(it, "subscription", listOf("t", "token", "code", "d")) }
    }

    private fun extractPlainToken(raw: String): String {
        val decoded = runCatching { Uri.decode(raw) }.getOrDefault(raw).trim()
        Regex("(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{24,128}(?![A-Za-z0-9_-])").find(decoded)?.value?.let { return it }
        return decoded
    }

    private fun normalizeActivationToken(raw: String): String {
        var value = raw.trim().trim('<', '>', '"', '\'', '`')
        if (value.isEmpty()) return ""
        val marker = "darktunnel://activate"
        val markerIndex = value.indexOf(marker, ignoreCase = true)
        if (markerIndex >= 0) value = value.substring(markerIndex).takeWhile { !it.isWhitespace() && it != '<' && it != '>' && it != '"' && it != '\'' }
        fromUri(value, "activate", listOf("d", "token", "code"))?.let { return it }
        runCatching { Uri.decode(value) }.getOrNull()?.let { fromUri(it, "activate", listOf("d", "token", "code"))?.let { return it } }
        return value
    }

    private fun fromUri(candidate: String, expectedHost: String, keys: List<String>): String? {
        val uri = runCatching { Uri.parse(candidate) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()
        if (scheme == "darktunnel" && host == expectedHost) return keys.firstNotNullOfOrNull { uri.getQueryParameter(it)?.trim()?.takeIf(String::isNotEmpty) }
        if (scheme == "http" || scheme == "https") return keys.firstNotNullOfOrNull { uri.getQueryParameter(it)?.trim()?.takeIf(String::isNotEmpty) }
        return null
    }

    private fun parseObject(text: String, fallback: String): JsonObject = runCatching { JsonParser.parseString(text).asJsonObject }
        .getOrElse { throw IllegalStateException("$fallback. Попробуйте ещё раз.") }

    private fun apiError(text: String, fallback: String): String = runCatching { JsonParser.parseString(text).asJsonObject.get("detail")?.asString }
        .getOrNull()?.takeIf { it.isNotBlank() } ?: fallback

    private fun activationError(text: String): String = runCatching {
        val o = JsonParser.parseString(text).asJsonObject
        o.get("detail")?.asString ?: o.get("message")?.asString
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: "Не удалось войти по подписке"

    private fun parseServer(s: JsonObject) = Server(
        id = s["id"]?.asString.orEmpty(), name = s["name"]?.asString.orEmpty(),
        country = s["country_name"]?.asString.orEmpty(), city = s["city"]?.asString.orEmpty(),
        flag = flag(s["country_code"]?.asString.orEmpty()), host = s["host"]?.asString.orEmpty(),
        port = s["port"]?.asInt ?: 0, online = s["online"]?.asBoolean ?: false,
        latencyMs = s["latency_ms"]?.takeUnless { it.isJsonNull }?.asInt,
        amneziaConfig = s["amnezia_config"]?.takeUnless { it.isJsonNull }?.asString
    )

    private fun validateServer(server: Server) {
        require(server.id.isNotBlank()) { "Сервер имеет некорректный идентификатор" }
        require(server.host.isNotBlank()) { "Сервер имеет некорректный адрес" }
        require(server.port in 1..65535) { "Сервер имеет некорректный порт" }
        require(server.amneziaConfig?.isNotBlank() == true) { "У сервера нет конфигурации AmneziaWG" }
    }

    private fun flag(code: String): String {
        if (code.length != 2) return "🌐"
        return code.uppercase().map { Character.toChars(127397 + it.code).concatToString() }.joinToString("")
    }
}
