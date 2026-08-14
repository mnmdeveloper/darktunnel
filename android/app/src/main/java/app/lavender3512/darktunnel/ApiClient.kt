package app.lavender3512.darktunnel

import android.content.Context
import android.net.Uri
import android.util.Base64
import com.google.gson.Gson
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
    private val gson = Gson()
    private val http = OkHttpClient.Builder().connectTimeout(7, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS).build()
    private val base = "https://api.31-77-148-80.sslip.io"

    private fun installationId(): String = prefs.getString("installation_id", null)
        ?: UUID.randomUUID().toString().lowercase().also { prefs.edit().putString("installation_id", it).apply() }

    private fun publicKey(): String = prefs.getString("public_key", null)
        ?: ByteArray(32).also { SecureRandom().nextBytes(it) }
            .let { Base64.encodeToString(it, Base64.NO_WRAP) }
            .also { prefs.edit().putString("public_key", it).apply() }

    fun isActivated(): Boolean = !prefs.getString("refresh_token", null).isNullOrBlank()
    fun activationToken(): String? = prefs.getString("activation_token", null)

    fun activate(rawToken: String): Result<Activation> = runCatching {
        val token = normalizeActivationToken(rawToken)
        require(token.isNotEmpty()) { "Вставьте ссылку или код активации" }
        val body = gson.toJson(mapOf(
            "token" to token,
            "installation_id" to installationId(),
            "public_key" to publicKey(),
            "app_version" to "0.1.1",
            "android_version" to android.os.Build.VERSION.RELEASE
        )).toRequestBody("application/json".toMediaType())
        val req = Request.Builder().url("$base/v1/activation/redeem").post(body).header("Accept", "application/json").build()
        http.newCall(req).execute().use { r ->
            val text = r.body?.string().orEmpty().trim()
            if (!r.isSuccessful) throw IllegalStateException("${activationError(text)} (HTTP ${r.code})")
            val o = parseObject(text, "Сервер активации вернул некорректный ответ")
            val s = o.getAsJsonObject("server") ?: throw IllegalStateException("В ответе активации нет сервера")
            val server = parseServer(s)
            val refresh = o["refresh_token"]?.asString?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("Сервер не выдал токен устройства")
            val expires = o["subscription_expires_at"]?.asString.orEmpty()
            prefs.edit().putString("refresh_token", refresh).putString("activation_token", token).putString("expires_at", expires).apply()
            Activation(expires, refresh, server)
        }
    }

    fun servers(): Result<List<Server>> = runCatching {
        val token = prefs.getString("refresh_token", null) ?: throw IllegalStateException("Нет активации")
        val req = Request.Builder().url("$base/v1/subscription/servers?installation_id=${installationId()}").header("X-Device-Token", token).get().build()
        http.newCall(req).execute().use { r ->
            val text = r.body?.string().orEmpty().trim()
            if (!r.isSuccessful) throw IllegalStateException("${apiError(text, "Серверы недоступны")} (HTTP ${r.code})")
            val o = parseObject(text, "Список серверов имеет некорректный формат")
            o.getAsJsonArray("servers")?.map { parseServer(it.asJsonObject) } ?: emptyList()
        }
    }

    fun publicServers(): Result<List<Server>> = runCatching {
        val req = Request.Builder().url("$base/v1/servers").get().build()
        http.newCall(req).execute().use { r ->
            val text = r.body?.string().orEmpty().trim()
            if (!r.isSuccessful) throw IllegalStateException("${apiError(text, "Список серверов недоступен")} (HTTP ${r.code})")
            val o = parseObject(text, "Список серверов имеет некорректный формат")
            o.getAsJsonArray("servers")?.map { parseServer(it.asJsonObject) } ?: emptyList()
        }
    }

    fun clear() { prefs.edit().clear().apply() }

    private fun normalizeActivationToken(raw: String): String {
        val value = raw.trim()
        if (value.startsWith("darktunnel://", ignoreCase = true)) {
            return Uri.parse(value).getQueryParameter("d")?.trim().orEmpty()
        }
        return value
    }

    private fun parseObject(text: String, fallback: String): JsonObject = runCatching {
        JsonParser.parseString(text).asJsonObject
    }.getOrElse {
        throw IllegalStateException("$fallback. Попробуйте ещё раз.")
    }

    private fun apiError(text: String, fallback: String): String = runCatching {
        JsonParser.parseString(text).asJsonObject.get("detail")?.asString
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: fallback

    private fun activationError(text: String): String = runCatching {
        JsonParser.parseString(text).asJsonObject.get("detail")?.asString
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: "Не удалось активировать приглашение"

    private fun parseServer(s: JsonObject) = Server(
        s["id"]?.asString.orEmpty(), s["name"]?.asString.orEmpty(), s["country_name"]?.asString.orEmpty(),
        s["city"]?.asString.orEmpty(), flag(s["country_code"]?.asString.orEmpty()), s["host"]?.asString.orEmpty(),
        s["port"]?.asInt ?: 0, s["online"]?.asBoolean ?: false,
        s["latency_ms"]?.takeUnless { it.isJsonNull }?.asInt,
        s["amnezia_config"]?.takeUnless { it.isJsonNull }?.asString
    )

    private fun flag(code: String): String {
        if (code.length != 2) return "🌐"
        return code.uppercase().map { Character.toChars(127397 + it.code).concatToString() }.joinToString("")
    }
}
