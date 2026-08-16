package app.lavender3512.darktunnel

data class Server(
    val id: String,
    val name: String,
    val country: String,
    val city: String,
    val flag: String,
    val host: String,
    val port: Int,
    val online: Boolean,
    val latencyMs: Int?,
    val amneziaConfig: String?,
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
)

data class Activation(val expiresAt: String, val refreshToken: String, val server: Server)

enum class TransportMode { AUTOMATIC, AMNEZIA_WG, VK_BYPASS }
enum class SpeedMode { BALANCED, MAXIMUM }
enum class VpnState { DISCONNECTED, CONNECTING, CONNECTED }

data class UiState(
    val activated: Boolean = false,
    val loading: Boolean = false,
    val vpnState: VpnState = VpnState.DISCONNECTED,
    val servers: List<Server> = emptyList(),
    val selected: Server? = null,
    val error: String? = null,
    val ping: String = "—",
    val transport: TransportMode = TransportMode.AUTOMATIC,
    val speedMode: SpeedMode = SpeedMode.BALANCED,
    val vkCallLink: String = "",
    val autoSelect: Boolean = true,
    val daysLeft: String = "—",
    val announcement: String? = null,
    val isRefreshing: Boolean = false,
) {
    val connected get() = vpnState == VpnState.CONNECTED
    val connecting get() = vpnState == VpnState.CONNECTING
}
