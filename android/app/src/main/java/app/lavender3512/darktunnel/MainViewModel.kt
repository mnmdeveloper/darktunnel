package app.lavender3512.darktunnel

import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainViewModel : ViewModel() {
    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    private var api: ApiClient? = null
    private var awg: AwgController? = null
    private var pendingConfig: String? = null
    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        if (api != null) return
        api = ApiClient(context.applicationContext)
        awg = AwgController(context.applicationContext)
        prefs = context.getSharedPreferences("darktunnel_ui", Context.MODE_PRIVATE)
        val transport = when (prefs!!.getString("transport", "AUTO")) {
            "AWG" -> TransportMode.AMNEZIA_WG
            "VK"  -> TransportMode.VK_BYPASS
            else  -> TransportMode.AUTOMATIC
        }
        val speed = if (prefs!!.getString("speed", "BAL") == "MAX") SpeedMode.MAXIMUM else SpeedMode.BALANCED
        val subInfo = api!!.subscriptionInfo()
        _ui.value = _ui.value.copy(
            activated  = api!!.isActivated(),
            vpnState   = if (awg!!.isConnected()) VpnState.CONNECTED else VpnState.DISCONNECTED,
            transport  = transport,
            speedMode  = speed,
            vkCallLink = prefs!!.getString("vk_link", "").orEmpty(),
            autoSelect = prefs!!.getBoolean("auto_select", true),
            daysLeft   = subInfo.daysLeft,
        )
        if (api!!.isActivated()) refresh()
        startPingLoop()
    }

    fun activate(token: String) {
        val clean = token.trim()
        if (clean.isEmpty()) { _ui.value = _ui.value.copy(error = "Вставьте код или ссылку активации"); return }
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            withContext(Dispatchers.IO) { api!!.activate(clean) }
                .onSuccess { activation ->
                    val subInfo = api!!.subscriptionInfo()
                    _ui.value = _ui.value.copy(
                        activated = true, loading = false, error = null,
                        selected = activation.server, servers = listOf(activation.server),
                        daysLeft = subInfo.daysLeft,
                    )
                    refresh()
                }
                .onFailure { _ui.value = _ui.value.copy(loading = false, error = it.message ?: "Не удалось активировать") }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(isRefreshing = true, error = null)
            val subInfo = withContext(Dispatchers.IO) { api!!.subscriptionInfo() }
            withContext(Dispatchers.IO) { api!!.servers() }
                .onSuccess { list ->
                    val cur = _ui.value.selected?.id
                    val sel = if (_ui.value.autoSelect) chooseBest(list)
                              else list.firstOrNull { it.id == cur } ?: chooseBest(list)
                    _ui.value = _ui.value.copy(
                        activated = true, isRefreshing = false, loading = false,
                        servers = list, selected = sel,
                        daysLeft = subInfo.daysLeft,
                        error = if (list.isEmpty()) "Серверов пока нет" else null,
                    )
                    measurePing(sel)
                }
                .onFailure { err ->
                    val msg = err.message ?: "Не удалось загрузить серверы"
                    if (msg.contains("HTTP 401") || msg.contains("HTTP 403")) {
                        api!!.clear(); awg?.disconnect(); pendingConfig = null
                        _ui.value = UiState(activated = false, error = "Сессия истекла. Активируйте заново.")
                    } else {
                        _ui.value = _ui.value.copy(isRefreshing = false, loading = false, error = msg)
                    }
                }
        }
    }

    fun select(server: Server) {
        prefs?.edit()?.putBoolean("auto_select", false)?.apply()
        _ui.value = _ui.value.copy(selected = server, autoSelect = false, error = null)
        measurePing(server)
    }

    fun selectAuto() {
        prefs?.edit()?.putBoolean("auto_select", true)?.apply()
        val best = chooseBest(_ui.value.servers)
        _ui.value = _ui.value.copy(autoSelect = true, selected = best)
        measurePing(best)
    }

    fun setTransport(t: TransportMode) {
        prefs?.edit()?.putString("transport", when (t) { TransportMode.AMNEZIA_WG -> "AWG"; TransportMode.VK_BYPASS -> "VK"; else -> "AUTO" })?.apply()
        _ui.value = _ui.value.copy(transport = t, error = null)
    }

    fun setSpeed(s: SpeedMode) {
        prefs?.edit()?.putString("speed", if (s == SpeedMode.MAXIMUM) "MAX" else "BAL")?.apply()
        _ui.value = _ui.value.copy(speedMode = s)
    }

    fun setVkLink(link: String) {
        prefs?.edit()?.putString("vk_link", link)?.apply()
        _ui.value = _ui.value.copy(vkCallLink = link)
    }

    fun requestConnect(): Boolean {
        val server = _ui.value.selected ?: chooseBest(_ui.value.servers)
        if (server == null) { _ui.value = _ui.value.copy(error = "Нет доступного сервера"); return false }
        if (!server.online) { _ui.value = _ui.value.copy(error = "Сервер недоступен"); return false }
        val config = server.amneziaConfig?.trim().orEmpty()
        if (config.isEmpty()) { _ui.value = _ui.value.copy(error = "Нет конфигурации AmneziaWG"); return false }
        if (_ui.value.transport == TransportMode.VK_BYPASS && _ui.value.vkCallLink.isBlank()) {
            _ui.value = _ui.value.copy(error = "Добавьте ссылку VK-звонка для режима VK обход"); return false
        }
        pendingConfig = config
        _ui.value = _ui.value.copy(selected = server, error = null)
        return true
    }

    fun finishConnect() {
        val config = pendingConfig ?: return
        pendingConfig = null
        viewModelScope.launch {
            _ui.value = _ui.value.copy(vpnState = VpnState.CONNECTING, loading = true, error = null)
            withContext(Dispatchers.IO) { awg!!.connect(config) }
                .onSuccess { _ui.value = _ui.value.copy(loading = false, vpnState = VpnState.CONNECTED, error = null) }
                .onFailure { _ui.value = _ui.value.copy(loading = false, vpnState = VpnState.DISCONNECTED, error = it.message ?: "Не удалось подключиться") }
        }
    }

    fun cancelPendingConnect() { pendingConfig = null; _ui.value = _ui.value.copy(loading = false, vpnState = VpnState.DISCONNECTED) }

    fun disconnect() {
        pendingConfig = null
        viewModelScope.launch {
            withContext(Dispatchers.IO) { awg!!.disconnect() }
                .onSuccess { _ui.value = _ui.value.copy(loading = false, vpnState = VpnState.DISCONNECTED, ping = "—", error = null) }
                .onFailure { _ui.value = _ui.value.copy(loading = false, error = it.message) }
        }
    }

    private fun measurePing(server: Server?) {
        server ?: return
        viewModelScope.launch {
            val ms = withContext(Dispatchers.IO) { api!!.ping(server.host, server.port) }
            _ui.value = _ui.value.copy(ping = if (ms != null) "$ms мс" else "—")
        }
    }

    private fun startPingLoop() {
        viewModelScope.launch {
            while (true) {
                delay(15_000)
                val sel = _ui.value.selected ?: continue
                val ms = withContext(Dispatchers.IO) { api!!.ping(sel.host, sel.port) }
                _ui.value = _ui.value.copy(ping = if (ms != null) "$ms мс" else "—")
            }
        }
    }

    private fun chooseBest(list: List<Server>): Server? =
        list.filter { it.online && !it.amneziaConfig.isNullOrBlank() }
            .minByOrNull { it.latencyMs ?: Int.MAX_VALUE }
            ?: list.firstOrNull { !it.amneziaConfig.isNullOrBlank() }
}
