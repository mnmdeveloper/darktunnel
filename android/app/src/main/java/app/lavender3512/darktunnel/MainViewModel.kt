package app.lavender3512.darktunnel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetAddress

class MainViewModel : ViewModel() {
    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()
    private var api: ApiClient? = null
    private var awg: AwgController? = null
    private var pendingConfig: String? = null

    fun init(context: Context) {
        if (api != null) return
        api = ApiClient(context)
        awg = AwgController(context)
        _ui.value = _ui.value.copy(activated = api!!.isActivated(), connected = awg!!.isConnected())
        if (api!!.isActivated()) refresh()
    }

    fun activate(token: String, onDone: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val r = withContext(Dispatchers.IO) { api!!.activate(token.trim()) }
            r.onSuccess {
                _ui.value = _ui.value.copy(activated = true, loading = false)
                refresh()
                onDone(true)
            }.onFailure {
                _ui.value = _ui.value.copy(loading = false, error = it.message ?: "Ошибка активации")
                onDone(false)
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val r = withContext(Dispatchers.IO) { api!!.servers() }
            val list = r.getOrElse { withContext(Dispatchers.IO) { api!!.publicServers() }.getOrElse { emptyList() } }
            if (list.isEmpty()) {
                _ui.value = _ui.value.copy(loading = false, error = r.exceptionOrNull()?.message ?: "Нет серверов")
            } else {
                val best = choose(list)
                _ui.value = _ui.value.copy(loading = false, servers = list, selected = best, ping = best?.latencyMs?.let { "$it мс" } ?: "—")
            }
        }
    }

    private fun choose(list: List<Server>): Server? = list
        .filter { it.online && !it.amneziaConfig.isNullOrBlank() }
        .minByOrNull { it.latencyMs ?: Int.MAX_VALUE }

    fun select(server: Server) {
        _ui.value = _ui.value.copy(selected = server, ping = server.latencyMs?.let { "$it мс" } ?: "—")
    }

    fun requestConnect(): String? {
        val s = _ui.value.selected ?: choose(_ui.value.servers)
        if (s == null) return null
        if (s.amneziaConfig.isNullOrBlank()) {
            _ui.value = _ui.value.copy(error = "У выбранного сервера нет конфигурации AmneziaWG")
            return null
        }
        pendingConfig = s.amneziaConfig
        return pendingConfig
    }

    fun finishConnect() {
        val config = pendingConfig ?: return
        pendingConfig = null
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val r = withContext(Dispatchers.IO) { awg!!.connect(config) }
            r.onSuccess { _ui.value = _ui.value.copy(loading = false, connected = true) }
                .onFailure { _ui.value = _ui.value.copy(loading = false, error = it.message ?: "Не удалось подключиться") }
        }
    }

    fun disconnect() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { awg?.disconnect() }
            _ui.value = _ui.value.copy(connected = false)
        }
    }

    fun ping(server: Server) {
        viewModelScope.launch(Dispatchers.IO) {
            val start = System.nanoTime()
            val ms = runCatching { InetAddress.getByName(server.host).isReachable(1800) }
                .fold({ if (it) ((System.nanoTime() - start) / 1_000_000).toInt() else 0 }, { 0 })
            if (ms > 0) {
                val currentSelected = _ui.value.selected
                val list = _ui.value.servers.map { if (it.id == server.id) it.copy(latencyMs = ms) else it }
                val selected = if (currentSelected?.id == server.id) currentSelected.copy(latencyMs = ms) else currentSelected
                _ui.value = _ui.value.copy(servers = list, selected = selected, ping = "$ms мс")
            }
        }
    }
}
