package app.lavender3512.darktunnel

data class Server(val id:String,val name:String,val country:String,val city:String,val flag:String,val host:String,val port:Int,val online:Boolean,val latencyMs:Int?,val amneziaConfig:String?)
data class Activation(val expiresAt:String,val refreshToken:String,val server:Server)

data class UiState(val activated:Boolean=false,val loading:Boolean=false,val connected:Boolean=false,val servers:List<Server> = emptyList(),val selected:Server?=null,val error:String?=null,val ping:String="—")
