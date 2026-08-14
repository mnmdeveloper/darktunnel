package app.lavender3512.darktunnel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
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

    fun init(context: Context) {
        if (api != null) return
        api = ApiClient(context.applicationContext)
        awg = AwgController(context.applicationContext)
        _ui.value = _ui.value.copy(
            activated = api!!.isActivated(),
            connected = awg!!.isConnected()
        )
        if (api!!.isActivated()) refresh()
    }

    fun activate(token: String) {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val result = withContext(Dispatchers.IO) { api!!.activate(token) }
            result.onSuccess {
                _ui.value = _ui.value.copy(activated = true, loading = false)
                refresh()
            }.onFailure {
                _ui.value = _ui.value.copy(
                    loading = false,
                    error = it.message ?: "Ошибка активации"
                )
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val result = withContext(Dispatchers.IO) { api!!.servers() }
            result.onSuccess { list ->
                val selectedId = _ui.value.selected?.id
                val selected = list.firstOrNull { it.id == selectedId }
                    ?: choose(list)
                _ui.value = _ui.value.copy(
                    loading = false,
                    servers = list,
                    selected = selected,
                    ping = selected?.latencyMs?.let { "$it мс" } ?: "—"
                )
            }.onFailure {
                _ui.value = _ui.value.copy(
                    loading = false,
                    activated = api!!.isActivated(),
                    error = it.message ?: "Не удалось загрузить серверы"
                )
            }
        }
    }

    private fun choose(list: List<Server>): Server? = list
        .filter { it.online && !it.amneziaConfig.isNullOrBlank() }
        .minByOrNull { it.latencyMs ?: Int.MAX_VALUE }
        ?: list.firstOrNull { !it.amneziaConfig.isNullOrBlank() }

    fun select(server: Server) {
        _ui.value = _ui.value.copy(
            selected = server,
            ping = server.latencyMs?.let { "$it мс" } ?: "—"
        )
    }

    fun requestConnect(): Boolean {
        if (_ui.value.connected) return false
        val server = _ui.value.selected ?: choose(_ui.value.servers)
        if (server == null) {
            _ui.value = _ui.value.copy(error = "Нет доступного VPN-сервера")
            return false
        }
        val config = server.amneziaConfig?.trim().orEmpty()
        if (config.isEmpty()) {
            _ui.value = _ui.value.copy(error = "У выбранного сервера нет конфигурации AmneziaWG")
            return false
        }
        pendingConfig = config
        _ui.value = _ui.value.copy(selected = server, error = null)
        return true
    }

    fun finishConnect() {
        val config = pendingConfig ?: return
        pendingConfig = null
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val result = withContext(Dispatchers.IO) { awg!!.connect(config) }
            result.onSuccess {
                _ui.value = _ui.value.copy(loading = false, connected = true)
            }.onFailure {
                _ui.value = _ui.value.copy(
                    loading = false,
                    connected = false,
                    error = it.message ?: "Не удалось подключиться к VPN"
                )
            }
        }
    }

    fun cancelPendingConnect() {
        pendingConfig = null
        _ui.value = _ui.value.copy(loading = false)
    }

    fun disconnect() {
        pendingConfig = null
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { awg!!.disconnect() }
            result.onSuccess {
                _ui.value = _ui.value.copy(connected = false, loading = false, error = null)
            }.onFailure {
                _ui.value = _ui.value.copy(
                    loading = false,
                    error = it.message ?: "Не удалось отключить VPN"
                )
            }
        }
    }

    fun syncConnectionState() {
        viewModelScope.launch(Dispatchers.IO) {
            val connected = awg?.isConnected() ?: false
            _ui.value = _ui.value.copy(connected = connected)
        }
    }

    fun ping(server: Server) {
        // Server latency comes from the backend health probe. We deliberately do
        // not perform a raw ICMP/Socket probe from the client because that can
        // measure a different route than the VPN endpoint and can leak metadata.
        select(server)
    }
}
