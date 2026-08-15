package app.lavender3512.darktunnel

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

private val Bg       = Color(0xFF07080B)
private val Surface1 = Color(0xFF101218)
private val Stroke   = Color(0xFF292D37)
private val Muted    = Color(0xFF8F96A5)
private val Accent   = Color(0xFFB9E7B0)
private val Danger   = Color(0xFFFF807B)

private val darkScheme = darkColorScheme(
    background = Bg, surface = Surface1, surfaceVariant = Color(0xFF171A21),
    primary = Color.White, onPrimary = Color.Black,
    onSurface = Color.White, onSurfaceVariant = Muted,
)

class MainActivity : ComponentActivity() {
    private val vm by viewModels<MainViewModel>()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vm.init(this)
        handleIntent(intent)
        setContent { DarkTunnelApp(vm) }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }
    // Handles darktunnel://activate?d=TOKEN and darktunnel://subscription?t=TOKEN
    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        val scheme = data.scheme?.lowercase() ?: return
        val host = data.host?.lowercase() ?: return
        if (scheme == "darktunnel" && (host == "activate" || host == "subscription"))
            vm.activate(data.toString())
    }
}

@Composable
fun DarkTunnelApp(vm: MainViewModel) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var showServers by rememberSaveable { mutableStateOf(false) }
    var token by rememberSaveable { mutableStateOf("") }
    val vpnLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) vm.finishConnect() else vm.cancelPendingConnect()
    }
    MaterialTheme(colorScheme = darkScheme) {
        when {
            !ui.activated -> ActivationScreen(ui, token, { token = it }, {
                val cb = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                token = cb.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
            }) { vm.activate(token) }
            showServers -> ServersScreen(ui, { showServers = false }, { vm.select(it); showServers = false }, vm::refresh)
            else -> HomeScreen(ui, { showServers = true }, vm::refresh, {
                if (vm.requestConnect()) {
                    val i = VpnService.prepare(ctx)
                    if (i != null) vpnLauncher.launch(i) else vm.finishConnect()
                }
            }, vm::disconnect)
        }
    }
}

@Composable
private fun BrandIcon(size: Int = 64) {
    Surface(Modifier.size(size.dp), RoundedCornerShape((size * 0.28f).dp), Color(0xFF090A0E), shadowElevation = 10.dp) {
        Image(painterResource(R.drawable.ic_brand), "DarkTunnel",
            Modifier.fillMaxSize().padding((size * 0.08f).dp))
    }
}

@Composable
fun ActivationScreen(ui: UiState, token: String, onToken: (String) -> Unit, onPaste: () -> Unit, onActivate: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF03040A), Color(0xFF070D10), Color(0xFF050609))))) {
        Box(Modifier.size(280.dp).offset(x = 120.dp, y = (-100).dp).blur(80.dp)
            .background(Accent.copy(alpha = 0.10f), CircleShape).align(Alignment.TopEnd))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(64.dp))
            Box(contentAlignment = Alignment.Center) {
                Box(Modifier.size(96.dp).background(Color.White.copy(alpha = 0.05f), CircleShape))
                Box(Modifier.size(72.dp).background(Accent.copy(alpha = 0.10f), CircleShape))
                BrandIcon(52)
            }
            Spacer(Modifier.height(20.dp))
            Text("DarkTunnel", fontSize = 34.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text("Безопасный доступ к вашим VPN-серверам", color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(34.dp))
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Color(0xFF0C0F17).copy(alpha = 0.94f),
                border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.10f))) {
                Column(Modifier.padding(20.dp)) {
                    Text("АКТИВАЦИЯ", color = Accent, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.4.sp)
                    Spacer(Modifier.height(5.dp))
                    Text("Вставьте код или ссылку из Telegram", fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                    Text("Подойдут и darktunnel:// ссылки, и обычный код.", color = Muted, fontSize = 13.sp)
                    Spacer(Modifier.height(16.dp))
                    OutlinedTextField(value = token, onValueChange = onToken, singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("Код или ссылка активации", color = Color(0xFF5F6572), fontSize = 14.sp) },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        shape = RoundedCornerShape(17.dp),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent,
                            unfocusedBorderColor = Stroke, cursorColor = Accent,
                            focusedTextColor = Color.White, unfocusedTextColor = Color.White))
                    Spacer(Modifier.height(12.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(onClick = onPaste, modifier = Modifier.weight(1f).height(52.dp),
                            shape = RoundedCornerShape(14.dp),
                            border = androidx.compose.foundation.BorderStroke(1.dp, Stroke),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White.copy(alpha = 0.82f))) {
                            Text("Вставить", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                        }
                        Button(onClick = onActivate, enabled = token.isNotBlank() && !ui.loading,
                            modifier = Modifier.weight(1.7f).height(52.dp), shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color.Black,
                                disabledContainerColor = Accent.copy(alpha = 0.40f), disabledContentColor = Color.Black.copy(alpha = 0.4f))) {
                            if (ui.loading) CircularProgressIndicator(Modifier.size(19.dp), color = Color.Black, strokeWidth = 2.dp)
                            else Text("Активировать", fontSize = 14.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    ui.error?.let { err ->
                        Spacer(Modifier.height(12.dp))
                        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(14.dp), Danger.copy(alpha = 0.09f)) {
                            Text(err, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(12.dp))
                        }
                    }
                }
            }
            Spacer(Modifier.height(18.dp))
            Text("Токен привязывается к этому устройству", color = Color(0xFF5F6570), fontSize = 11.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(40.dp))
        }
    }
}

@Composable
fun HomeScreen(ui: UiState, onServers: () -> Unit, onRefresh: () -> Unit, onConnect: () -> Unit, onDisconnect: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                BrandIcon(48); Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("DarkTunnel", fontSize = 21.sp, fontWeight = FontWeight.Bold)
                    Text(if (ui.connected) "Соединение защищено" else "Готов к подключению",
                        color = if (ui.connected) Accent else Muted, fontSize = 12.sp)
                }
                TextButton(onClick = onRefresh, enabled = !ui.loading) { Text("↻", fontSize = 25.sp, color = Color.White) }
                TextButton(onClick = onServers) { Text("⚙", fontSize = 22.sp, color = Color.White) }
            }
            Spacer(Modifier.height(18.dp))
            ui.selected?.let { server ->
                Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Surface1, tonalElevation = 5.dp) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(52.dp).clip(CircleShape).background(Color(0xFF20242C)), Alignment.Center) {
                                Text(server.flag, fontSize = 26.sp)
                            }
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(if (server.city.isBlank()) server.name else server.city, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                                Text("AmneziaWG · ${server.host}", color = Muted, fontSize = 12.sp)
                            }
                            Box(Modifier.size(10.dp).clip(CircleShape).background(if (server.online) Accent else Color(0xFFFFB454)))
                        }
                        HorizontalDivider(color = Stroke)
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            StatLabel("ПИНГ", ui.ping); StatLabel("ПОРТ", server.port.toString()); StatLabel("СТАТУС", if (ui.connected) "ON" else "READY")
                        }
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallCard("${ui.servers.size}", "серверов", Modifier.weight(1f))
                SmallCard(if (ui.connected) "Защищён" else "Выключен", "VPN", Modifier.weight(1f), if (ui.connected) Accent else Color.White)
            }
            Spacer(Modifier.weight(1f))
            ui.error?.let { err ->
                Surface(Modifier.fillMaxWidth(), RoundedCornerShape(16.dp), Danger.copy(alpha = 0.08f)) {
                    Text(err, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(13.dp))
                }
                Spacer(Modifier.height(10.dp))
            }
            Button(onClick = if (ui.connected) onDisconnect else onConnect, enabled = !ui.loading,
                modifier = Modifier.fillMaxWidth().height(62.dp), shape = RoundedCornerShape(21.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (ui.connected) Color(0xFF20242B) else Color.White,
                    contentColor = if (ui.connected) Color.White else Color.Black,
                    disabledContainerColor = if (ui.connected) Color(0xFF20242B) else Color.White,
                    disabledContentColor = if (ui.connected) Color.White.copy(0.5f) else Color.Black.copy(0.5f))) {
                if (ui.loading) CircularProgressIndicator(Modifier.size(21.dp),
                    color = if (ui.connected) Color.White else Color.Black, strokeWidth = 2.dp)
                else Text(if (ui.connected) "Отключить VPN" else "Подключить VPN", fontSize = 17.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
fun ServersScreen(ui: UiState, onBack: () -> Unit, onSelect: (Server) -> Unit, onRefresh: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Bg).padding(18.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Серверы", fontSize = 29.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton(onClick = onBack) { Text("Готово", color = Accent, fontWeight = FontWeight.SemiBold) }
        }
        Spacer(Modifier.height(4.dp))
        Text("Выберите точку подключения", color = Muted, fontSize = 13.sp)
        Spacer(Modifier.height(18.dp))
        Surface(Modifier.fillMaxWidth().clickable {
            ui.servers.filter { it.online && !it.amneziaConfig.isNullOrBlank() }
                .minByOrNull { it.latencyMs ?: Int.MAX_VALUE }?.let(onSelect)
        }, RoundedCornerShape(22.dp), Surface1) {
            Row(Modifier.padding(17.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(42.dp).clip(CircleShape).background(Color(0xFF20242C)), Alignment.Center) {
                    Text("✦", color = Accent, fontSize = 20.sp)
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Автовыбор", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    Text("Минимальная задержка", color = Muted, fontSize = 12.sp)
                }
                Text("✓", color = Accent, fontSize = 20.sp)
            }
        }
        Spacer(Modifier.height(24.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("ДОСТУПНЫЕ", color = Muted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onRefresh, enabled = !ui.loading) { Text("Обновить", color = Color.White) }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(ui.servers) { server ->
                Surface(Modifier.fillMaxWidth().clickable { onSelect(server) }, RoundedCornerShape(19.dp), Surface1) {
                    Row(Modifier.padding(15.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(server.flag, fontSize = 25.sp); Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(if (server.city.isBlank()) server.name else server.city, fontWeight = FontWeight.SemiBold)
                            Text(if (server.online) "AmneziaWG" else "Недоступен", color = Muted, fontSize = 12.sp)
                        }
                        Text(server.latencyMs?.let { "$it мс" } ?: "—", color = Muted, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

@Composable private fun StatLabel(label: String, value: String) {
    Column {
        Text(label, color = Muted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
        Spacer(Modifier.height(3.dp))
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable private fun SmallCard(value: String, label: String, modifier: Modifier, valueColor: Color = Color.White) {
    Surface(modifier, RoundedCornerShape(20.dp), Surface1) {
        Column(Modifier.padding(16.dp)) {
            Text(value, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = valueColor)
            Spacer(Modifier.height(3.dp))
            Text(label, color = Muted, fontSize = 12.sp)
        }
    }
}
