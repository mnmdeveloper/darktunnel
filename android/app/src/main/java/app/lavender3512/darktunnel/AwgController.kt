package app.lavender3512.darktunnel

import android.content.Context
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.backend.TunnelActionHandler
import org.amnezia.awg.config.Config
import java.io.ByteArrayInputStream

class AwgController(context:Context){
    private val backend=GoBackend(context,object:TunnelActionHandler{
        override fun runPreUp(s:java.util.Collection<*>){}
        override fun runPostUp(s:java.util.Collection<*>){}
        override fun runPreDown(s:java.util.Collection<*>){}
        override fun runPostDown(s:java.util.Collection<*>){}
    })
    private val tunnel=AppTunnel()
    @Synchronized fun connect(configText:String):Result<Unit>=runCatching{val config=Config.parse(ByteArrayInputStream(configText.toByteArray(Charsets.UTF_8)));backend.setState(tunnel,Tunnel.State.UP,config);Unit}
    @Synchronized fun disconnect(){runCatching{backend.setState(tunnel,Tunnel.State.DOWN,null)}}
    fun isConnected():Boolean=runCatching{backend.getState(tunnel)==Tunnel.State.UP}.getOrDefault(false)
    private class AppTunnel: Tunnel { override fun getName()="DarkTunnel";override fun onStateChange(newState:Tunnel.State){};override fun isIpv4ResolutionPreferred()=true;override fun isMetered()=false }
}
