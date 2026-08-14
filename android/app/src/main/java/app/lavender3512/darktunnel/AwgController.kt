package app.lavender3512.darktunnel

import android.content.Context
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.backend.TunnelActionHandler
import org.amnezia.awg.config.Config
import java.io.ByteArrayInputStream

class AwgController(context: Context) {
    private val backend = GoBackend(context.applicationContext, object : TunnelActionHandler {
        override fun runPreUp(s: Collection<String>) = Unit
        override fun runPostUp(s: Collection<String>) = Unit
        override fun runPreDown(s: Collection<String>) = Unit
        override fun runPostDown(s: Collection<String>) = Unit
    })
    private val tunnel = AppTunnel()

    @Synchronized
    fun connect(configText: String): Result<Unit> = runCatching {
        val normalized = configText.trim()
        require(normalized.isNotEmpty()) { "Конфигурация VPN пуста" }
        require(normalized.contains("[Interface]", ignoreCase = true)) { "В конфигурации нет Interface" }
        require(normalized.contains("[Peer]", ignoreCase = true)) { "В конфигурации нет Peer" }

        val config = Config.parse(ByteArrayInputStream(normalized.toByteArray(Charsets.UTF_8)))
        if (backend.getState(tunnel) == Tunnel.State.UP) {
            backend.setState(tunnel, Tunnel.State.DOWN, null)
        }
        backend.setState(tunnel, Tunnel.State.UP, config)
        check(backend.getState(tunnel) == Tunnel.State.UP) { "VPN-движок не перешёл в состояние UP" }
    }

    @Synchronized
    fun disconnect(): Result<Unit> = runCatching {
        if (backend.getState(tunnel) != Tunnel.State.DOWN) {
            backend.setState(tunnel, Tunnel.State.DOWN, null)
        }
    }

    @Synchronized
    fun isConnected(): Boolean = runCatching {
        backend.getState(tunnel) == Tunnel.State.UP
    }.getOrDefault(false)

    private class AppTunnel : Tunnel {
        override fun getName() = "DarkTunnel"
        override fun onStateChange(newState: Tunnel.State) = Unit
        override fun isIpv4ResolutionPreferred() = true
        override fun isMetered() = false
    }
}
