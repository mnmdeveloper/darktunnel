package app.lavender3512.darktunnel

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.platform.LocalContext

class MainActivity:ComponentActivity(){
    private val vm by viewModels<MainViewModel>()
    override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState);vm.init(this);handleIntent(intent);setContent{DarkTunnelApp(vm)}}
    override fun onNewIntent(intent:Intent){super.onNewIntent(intent);setIntent(intent);handleIntent(intent)}
    private fun handleIntent(intent:Intent){intent.data?.takeIf{it.scheme=="darktunnel"&&it.host=="activate"}?.let{url->val token=url.getQueryParameter("d");if(!token.isNullOrBlank())vm.activate(token)}}
}

@Composable fun DarkTunnelApp(vm:MainViewModel){
    val ui by vm.ui.collectAsStateWithLifecycle(); val context=LocalContext.current; var settings by remember{mutableStateOf(false)}; var activationToken by remember{mutableStateOf("")}
    val vpnPermission=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()){vm.finishConnect()}
    MaterialTheme(colorScheme=darkScheme){
        if(!ui.activated) ActivationScreen(ui,activationToken,{activationToken=it},{vm.activate(activationToken)})
        else if(settings) SettingsScreen(ui,{settings=false},{vm.select(it);settings=false},{vm.refresh()})
        else HomeScreen(ui,{settings=true},{vm.refresh()},{val cfg=vm.requestConnect();if(cfg!=null){val intent=VpnService.prepare(context);if(intent!=null)vpnPermission.launch(intent)else vm.finishConnect()}},{vm.disconnect()})
    }
}

private val darkScheme=darkColorScheme(background=Color(0xFF08090D),surface=Color(0xFF15171D),surfaceVariant=Color(0xFF20232B),primary=Color.White,onPrimary=Color.Black,onSurface=Color.White,onSurfaceVariant=Color(0xFFA8ABB5))

@Composable fun ActivationScreen(ui:UiState,token:String,onToken:(String)->Unit,onActivate:()->Unit){Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF050609),Color(0xFF11151D)))),contentAlignment=Alignment.Center){Column(Modifier.padding(26.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(18.dp)){Text("◈",fontSize=58.sp,fontWeight=FontWeight.Bold);Text("DarkTunnel",fontSize=32.sp,fontWeight=FontWeight.Bold);Text("Вставьте приглашение из Telegram",color=Color(0xFFA8ABB5));OutlinedTextField(value=token,onValueChange=onToken,singleLine=true,placeholder={Text("darktunnel://activate?d=…")},modifier=Modifier.fillMaxWidth());Button(onClick=onActivate,enabled=token.isNotBlank()&&!ui.loading,modifier=Modifier.fillMaxWidth()){if(ui.loading)CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp)else Text("Активировать")};ui.error?.let{Text(it,color=Color(0xFFFF7B72),fontSize=13.sp)}}}}

@Composable fun HomeScreen(ui:UiState,onSettings:()->Unit,onRefresh:()->Unit,onConnect:()->Unit,onDisconnect:()->Unit){Box(Modifier.fillMaxSize()){MapBackdrop();Column(Modifier.fillMaxSize().padding(horizontal=18.dp,vertical=16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){Column{Text("DarkTunnel",fontSize=24.sp,fontWeight=FontWeight.Bold);Text(if(ui.connected)"Подключено" else "Подписка активна",color=Color(0xFFA8ABB5))};Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){TextButton(onClick=onRefresh){Text("↻",fontSize=28.sp)};TextButton(onClick=onSettings){Text("⚙",fontSize=25.sp)}}};Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(10.dp)){Metric("365 дн.","до окончания",Modifier.weight(1f));Metric(ui.servers.size.toString(),"серверов",Modifier.weight(1f))};Spacer(Modifier.height(130.dp));ui.selected?.let{server->ServerCard(server,ui.ping)};Spacer(Modifier.weight(1f));Button(onClick=if(ui.connected)onDisconnect else onConnect,modifier=Modifier.fillMaxWidth().height(58.dp),shape=RoundedCornerShape(18.dp),colors=ButtonDefaults.buttonColors(containerColor=if(ui.connected)Color(0xFFE8E8EA) else Color.White,contentColor=Color.Black)){Text(if(ui.connected)"Отключиться" else "Подключиться",fontSize=18.sp,fontWeight=FontWeight.SemiBold)};ui.error?.let{Text(it,color=Color(0xFFFF7B72),fontSize=13.sp,modifier=Modifier.padding(bottom=4.dp))}}}}

@Composable fun MapBackdrop(){Canvas(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF0B1017),Color(0xFF07100F))))){val w=size.width;val h=size.height;for(i in 0..11){drawLine(Color(0x151B9C83),Offset(0f,h*(i/12f)),Offset(w,h*((i+2)/12f)),3f)};for(i in 0..7){drawCircle(Color(0x1200A58C),w*(i/8f),h*(0.22f+(i%3)*0.18f),18f)};drawLine(Color(0x2268B7A0),Offset(w*.05f,h*.55f),Offset(w*.38f,h*.42f),5f);drawLine(Color(0x2268B7A0),Offset(w*.38f,h*.42f),Offset(w*.75f,h*.5f),5f)}}

@Composable fun Metric(value:String,label:String,modifier:Modifier){Surface(modifier,shape=RoundedCornerShape(22.dp),color=Color(0xB8171A20)){Column(Modifier.padding(18.dp)){Text(value,fontSize=24.sp,fontWeight=FontWeight.Bold);Text(label,color=Color(0xFFA8ABB5))}}}
@Composable fun ServerCard(server:Server,ping:String){Surface(Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp),color=Color(0xE9161A21)){Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){Column{Text(if(server.online)"✓ Подключение доступно" else "⚠ Сервер недоступен",color=if(server.online)Color.White else Color(0xFFFFB454),fontWeight=FontWeight.SemiBold);Text(if(server.city.isBlank())server.name else server.city,fontSize=27.sp,fontWeight=FontWeight.Bold);Text("AmneziaWG",color=Color(0xFFA8ABB5))};Text(server.flag,fontSize=28.sp)};HorizontalDivider(color=Color(0x22FFFFFF));Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){Text("Пинг  $ping",color=Color(0xFFA8ABB5));Text("${server.port}",color=Color(0xFFA8ABB5))}}}}

@Composable fun SettingsScreen(ui:UiState,onBack:()->Unit,onSelect:(Server)->Unit,onRefresh:()->Unit){Column(Modifier.fillMaxSize().background(Color(0xFF08090D)).padding(18.dp)){Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){Text("Настройки",fontSize=30.sp,fontWeight=FontWeight.Bold);TextButton(onClick=onBack){Text("✕",fontSize=26.sp)}};Spacer(Modifier.height(18.dp));Text("СКОРОСТЬ",color=Color(0xFF8D919C),fontWeight=FontWeight.Bold,letterSpacing=2.sp);Surface(Modifier.fillMaxWidth().padding(top=8.dp),shape=RoundedCornerShape(24.dp),color=Color(0xFF181A1F)){Column(Modifier.padding(18.dp)){Text("Стандарт",fontSize=20.sp,fontWeight=FontWeight.SemiBold);Text("5 соединений — режим по умолчанию",color=Color(0xFFA8ABB5));Spacer(Modifier.height(14.dp));Text("Максимум",fontSize=20.sp,fontWeight=FontWeight.SemiBold);Text("10 соединений — вручную",color=Color(0xFFA8ABB5))}};Spacer(Modifier.height(24.dp));Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){Text("СЕРВЕР",color=Color(0xFF8D919C),fontWeight=FontWeight.Bold,letterSpacing=2.sp);TextButton(onClick=onRefresh){Text("Обновить")}};Surface(Modifier.fillMaxWidth().padding(top=8.dp),shape=RoundedCornerShape(24.dp),color=Color(0xFF181A1F)){Column(Modifier.padding(vertical=8.dp)){Row(Modifier.fillMaxWidth().clickable{ui.servers.firstOrNull()?.let(onSelect)}.padding(18.dp),horizontalArrangement=Arrangement.SpaceBetween){Column{Text("Автовыбор",fontSize=20.sp,fontWeight=FontWeight.SemiBold);Text("Онлайн AmneziaWG • минимальная задержка",color=Color(0xFFA8ABB5))};Text("✓",fontSize=24.sp)}}};Spacer(Modifier.height(20.dp));Text("ДОСТУПНЫЕ СЕРВЕРЫ",color=Color(0xFF8D919C),fontWeight=FontWeight.Bold,letterSpacing=2.sp);LazyColumn(verticalArrangement=Arrangement.spacedBy(8.dp),modifier=Modifier.padding(top=8.dp)){items(ui.servers){s->Surface(Modifier.fillMaxWidth().clickable{onSelect(s)},shape=RoundedCornerShape(18.dp),color=Color(0xFF181A1F)){Row(Modifier.padding(16.dp),verticalAlignment=Alignment.CenterVertically){Text(s.flag,fontSize=24.sp);Spacer(Modifier.width(12.dp));Column(Modifier.weight(1f)){Text(if(s.city.isBlank())s.name else s.city,fontWeight=FontWeight.SemiBold);Text(if(s.online)"AmneziaWG" else "Недоступен",color=Color(0xFFA8ABB5),fontSize=13.sp)};Text(s.latencyMs?.let{"$it мс"}?:"—",color=if(s.online)Color(0xFFFFA73A)else Color(0xFF777B84))}}}}}}
