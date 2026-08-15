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
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
    private val base = "https://api.31-77-148-80.sslip.io"

    private fun installationId(): String = prefs.getString("installation_id", null)
        ?.takeIf { it.isNotBlank() }
        ?: UUID.randomUUID().toString().lowercase()
            .also { prefs.edit().putString("installation_id", it).apply() }

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

    fun activate(rawToken: String): Result<Activation> = runCatching {
        val value = rawToken.trim()
        require(value.isNotEmpty()) { "Вставьте ссылку подписки или код доступа" }

        // Try subscription link first
        val subscriptionToken = extractSubscriptionToken(value)
        if (subscriptionToken != null) {
            return@runCatching trySubscriptionThenActivation(subscriptionToken)
        }

        // Try plain activation link
        val activationToken = extractActivationToken(value)
        if (activationToken != null) {
            return@runCatching redeemActivation(activationToken)
        }

        // Plain token - try both endpoints
        trySubscriptionThenActivation(value)
    }

    private fun trySubscriptionThenActivation(token: String): Activation {
        return try {
            redeemSubscription(token)
        } catch (e: Exception) {
            // If subscription endpoint fails (404 = not deployed yet, or wrong token type),
            // fall back to the activation endpoint which iOS uses
            try {
                redeemActivation(token)
            } catch (e2: Exception) {
                // Throw the more meaningful error
                throw e2
            }
        }
    }

    private fun body(token: String) = gson.toJson(mapOf(
        "token" to token,
        "installation_id" to installationId(),
        "public_key" to publicKey(),
        "app_version" to BuildConfig.VERSION_NAME,
        "android_version" to Build.VERSION.RELEASE
    )).toRequestBody("application/json".toMediaType())

    private fun redeemActivation(token: String): Activation {
        require(token.isNotEmpty()) { "Вставьте код или ссылку подписки" }
        val req = Request.Builder()
            .url("$base/v1/activation/redeem")
            .post(body(token))
            .header("Accept", "application/json")
            .build()
        return executeActivationRequest(req, token)
    }

    private fun redeemSubscription(token: String): Activation {
        require(token.isNotEmpty()) { "Ссылка подписки пустая" }
        val req = Request.Builder()
            .url("$base/v1/subscription/access/redeem")
            .post(body(token))
            .header("Accept", "application/json")
            .build()
        return executeActivationRequest(req, token)
    }

    private fun executeActivationRequest(request: Request, storedToken: String): Activation {
        return http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty().trim()
            if (!response.isSuccessful) {
                throw IllegalStateException("${apiError(text, "Не удалось войти по подписке")} (HTTP ${response.code})")
            }
            val obj = parseObject(text, "Сервер вернул некорректный ответ")
            val serverObj = obj.getAsJsonObject("server")
                ?: throw IllegalStateException("В ответе нет данных сервера")
            val server = parseServer(serverObj)
            require(server.host.isNotBlank()) { "Сервер имеет некорректный адрес" }
            require(server.port in 1..65535) { "Сервер имеет некорректный порт" }
            val refresh = obj["refresh_token"]?.asString?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: throw IllegalStateException("Сервер не выдал токен устройства")
            val expires = obj["subscription_expires_at"]?.asString.orEmpty()
            secure.putString("refresh_token", refresh)
            secure.putString("activation_token", storedToken)
            prefs.edit().putString("expires_at", expires).apply()
            Activation(expires, refresh, server)
        }
    }

    fun servers(): Result<List<Server>> = runCatching {
        val token = secret("refresh_token") ?: throw IllegalStateException("Нет активной подписки")
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
                if (response.code == 401 || response.code == 403) secure.remove("refresh_token")
                throw IllegalStateException("${apiError(text, "Сессия подписки недействительна")} (HTTP ${response.code})")
            }
            val obj = parseObject(text, "Список серверов имеет некорректный формат")
            val parsed = obj.getAsJsonArray("servers")?.mapNotNull { element ->
                runCatching { parseServer(element.asJsonObject) }.getOrNull()
            } ?: emptyList()
            val servers = parsed.filter {
                it.id.isNotBlank() && it.host.isNotBlank() &&
                it.port in 1..65535 && !it.amneziaConfig.isNullOrBlank()
            }
            if (servers.isEmpty()) throw IllegalStateException("Подписка активна, но AmneziaWG-серверов пока нет")
            servers
        }
    }

    fun clear() { secure.clear(); prefs.edit().clear().apply() }

    private fun extractSubscriptionToken(raw: String): String? {
        val marker = "darktunnel://subscription"
        val idx = raw.indexOf(marker, ignoreCase = true)
        val candidate = if (idx >= 0) raw.substring(idx).takeWhile { !it.isWhitespace() }
                        else if (raw.startsWith("darktunnel://", ignoreCase = true)) raw else null
        candidate ?: return null
        return fromUri(candidate, "subscription", listOf("t", "token", "code", "d"))
    }

    private fun extractActivationToken(raw: String): String? {
        val marker = "darktunnel://activate"
        val idx = raw.indexOf(marker, ignoreCase = true)
        val candidate = if (idx >= 0) raw.substring(idx).takeWhile { !it.isWhitespace() } else null
        candidate ?: return null
        return fromUri(candidate, "activate", listOf("d", "token", "code"))
    }

    private fun fromUri(candidate: String, expectedHost: String, keys: List<String>): String? {
        val uri = runCatching { Uri.parse(candidate) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()
        if ((scheme == "darktunnel" && (host == expectedHost || host == null)) ||
            scheme == "http" || scheme == "https") {
            return keys.firstNotNullOfOrNull {
                uri.getQueryParameter(it)?.trim()?.takeIf(String::isNotEmpty)
            }
        }
        return null
    }

    private fun parseObject(text: String, fallback: String): JsonObject =
        runCatching { JsonParser.parseString(text).asJsonObject }
            .getOrElse { throw IllegalStateException("$fallback. Попробуйте ещё раз.") }

    private fun apiError(text: String, fallback: String): String =
        runCatching {
            val o = JsonParser.parseString(text).asJsonObject
            o["detail"]?.asString ?: o["message"]?.asString
        }.getOrNull()?.takeIf { it.isNotBlank() } ?: fallback

    private fun parseServer(s: JsonObject) = Server(
        id = s["id"]?.asString.orEmpty(),
        name = s["name"]?.asString.orEmpty(),
        country = s["country_name"]?.asString.orEmpty(),
        city = s["city"]?.asString.orEmpty(),
        flag = flag(s["country_code"]?.asString.orEmpty()),
        host = s["host"]?.asString.orEmpty(),
        port = s["port"]?.asInt ?: 0,
        online = s["online"]?.asBoolean ?: true,
        latencyMs = s["latency_ms"]?.takeUnless { it.isJsonNull }?.asInt,
        amneziaConfig = s["amnezia_config"]?.takeUnless { it.isJsonNull }?.asString
    )

    private fun flag(code: String): String {
        if (code.length != 2) return "🌐"
        return code.uppercase().map { Character.toChars(127397 + it.code).concatToString() }.joinToString("")
    }
}
