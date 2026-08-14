package app.lavender3512.darktunnel

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
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

private val Bg = Color(0xFF080A0F)
private val Panel = Color(0xFF151820)
private val Panel2 = Color(0xFF1C2029)
private val Secondary = Color(0xFF9BA1AE)
private val Accent = Color(0xFFB9E7B0)

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
    private fun handleIntent(intent: Intent) {
        intent.data?.takeIf { it.scheme.equals("darktunnel", true) && it.host.equals("activate", true) }
            ?.getQueryParameter("d")?.takeIf { it.isNotBlank() }?.let(vm::activate)
    }
}

@Composable
fun DarkTunnelApp(vm: MainViewModel) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var settings by remember { mutableStateOf(false) }
    var token by remember { mutableStateOf("") }
    val vpnPermission = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { vm.finishConnect() }
    MaterialTheme(colorScheme = darkScheme) {
        when {
            !ui.activated -> ActivationScreen(ui, token, { token = it }, { vm.activate(token) })
            settings -> SettingsScreen(ui, { settings = false }, { vm.select(it); settings = false }, vm::refresh)
            else -> HomeScreen(ui, { settings = true }, vm::refresh, {
                if (vm.requestConnect() != null) {
                    val intent = VpnService.prepare(context)
                    if (intent != null) vpnPermission.launch(intent) else vm.finishConnect()
                }
            }, vm::disconnect)
        }
    }
}

private val darkScheme = darkColorScheme(
    background = Bg, surface = Panel, surfaceVariant = Panel2,
    primary = Color.White, onPrimary = Color.Black,
    onSurface = Color.White, onSurfaceVariant = Secondary
)

@Composable
private fun BrandMark(size: Int = 54) {
    Canvas(Modifier.size(size.dp)) {
        val c = Offset(size.width / 2f, size.height / 2f)
        val r = size.minDimension * .31f
        fun diamond(radius: Float, stroke: Float, color: Color) {
            val p = androidx.compose.ui.graphics.Path().apply {
                moveTo(c.x, c.y - radius); lineTo(c.x + radius, c.y); lineTo(c.x, c.y + radius); lineTo(c.x - radius, c.y); close()
            }
            drawPath(p, color, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
        }
        diamond(r, 3.2f, Color.White)
        diamond(r * .56f, 3.2f, Color(0xFF7E8795))
    }
}

@Composable
fun ActivationScreen(ui: UiState, token: String, onToken: (String) -> Unit, onActivate: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF06070A), Bg)))) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 22.dp).align(Alignment.Center),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            BrandMark(64)
            Spacer(Modifier.height(18.dp))
            Text("DarkTunnel", color = Color.White, fontSize = 31.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text("Приватный доступ в интернет", color = Secondary, fontSize = 15.sp)
            Spacer(Modifier.height(30.dp))
            Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(28.dp), color = Panel) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("Активация", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                    Text("Вставьте приглашение из Telegram", color = Secondary, fontSize = 14.sp)
                    OutlinedTextField(
                        value = token,
                        onValueChange = onToken,
                        singleLine = true,
                        textStyle = LocalTextStyle.current.copy(color = Color.White, fontSize = 15.sp),
                        placeholder = { Text("darktunnel://activate?d=…", color = Color(0xFF606674), fontSize = 14.sp) },
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(17.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Color(0xFF6F7786), unfocusedBorderColor = Color(0xFF343945),
                            cursorColor = Color.White, focusedTextColor = Color.White, unfocusedTextColor = Color.White
                        )
                    )
                    Button(
                        onClick = onActivate,
                        enabled = token.isNotBlank() && !ui.loading,
                        modifier = Modifier.fillMaxWidth().height(54.dp),
                        shape = RoundedCornerShape(17.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)
                    ) {
                        if (ui.loading) CircularProgressIndicator(Modifier.size(19.dp), color = Color.Black, strokeWidth = 2.dp)
                        else Text("Активировать", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    }
                    ui.error?.let { Text(it, color = Color(0xFFFF807B), fontSize = 13.sp) }
                }
            }
        }
    }
}

@Composable
fun HomeScreen(ui: UiState, onSettings: () -> Unit, onRefresh: () -> Unit, onConnect: () -> Unit, onDisconnect: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Bg)) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(Brush.verticalGradient(listOf(Color(0xFF0D1418), Bg)))
            for (i in 0..8) drawLine(Color(0x101FAF96), Offset(0f, size.height * i / 9f), Offset(size.width, size.height * (i + 1) / 10f), 2f)
        }
        Column(Modifier.fillMaxSize().padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    BrandMark(38); Spacer(Modifier.width(10.dp))
                    Column {
                        Text("DarkTunnel", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Text(if (ui.connected) "Подключено" else "Готов к подключению", color = Secondary, fontSize = 13.sp)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = onRefresh) { Text("↻", color = Color.White, fontSize = 26.sp) }
                    TextButton(onClick = onSettings) { Text("⚙", color = Color.White, fontSize = 24.sp) }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Metric("${ui.servers.size}", "серверов", Modifier.weight(1f))
                Metric(if (ui.connected) "ON" else "OFF", "статус", Modifier.weight(1f))
            }
            ui.selected?.let { ServerCard(it, ui.ping) }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = if (ui.connected) onDisconnect else onConnect,
                modifier = Modifier.fillMaxWidth().height(60.dp), shape = RoundedCornerShape(20.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)
            ) { Text(if (ui.connected) "Отключиться" else "Подключиться", fontSize = 18.sp, fontWeight = FontWeight.SemiBold) }
            ui.error?.let { Text(it, color = Color(0xFFFF807B), fontSize = 13.sp) }
        }
    }
}

@Composable
fun Metric(value: String, label: String, modifier: Modifier) {
    Surface(modifier, shape = RoundedCornerShape(20.dp), color = Color(0xCC171A21)) {
        Column(Modifier.padding(17.dp)) {
            Text(value, color = Color.White, fontSize = 23.sp, fontWeight = FontWeight.Bold)
            Text(label, color = Secondary, fontSize = 13.sp)
        }
    }
}

@Composable
fun ServerCard(server: Server, ping: String) {
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(25.dp), color = Color(0xEE171A21)) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Column(Modifier.weight(1f)) {
                    Text(if (server.online) "●  Сервер доступен" else "●  Сервер недоступен", color = if (server.online) Accent else Color(0xFFFFB454), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(5.dp))
                    Text(if (server.city.isBlank()) server.name else server.city, color = Color.White, fontSize = 27.sp, fontWeight = FontWeight.Bold)
                    Text("AmneziaWG", color = Secondary, fontSize = 14.sp)
                }
                Text(server.flag, fontSize = 28.sp)
            }
            HorizontalDivider(color = Color(0x22FFFFFF))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Пинг  $ping", color = Secondary, fontSize = 13.sp)
                Text("${server.port}", color = Secondary, fontSize = 13.sp)
            }
        }
    }
}

@Composable
fun SettingsScreen(ui: UiState, onBack: () -> Unit, onSelect: (Server) -> Unit, onRefresh: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Bg).padding(18.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("Настройки", color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold)
            TextButton(onClick = onBack) { Text("✕", color = Color.White, fontSize = 24.sp) }
        }
        Spacer(Modifier.height(18.dp))
        Text("СЕРВЕР", color = Secondary, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.8.sp)
        Surface(Modifier.fillMaxWidth().padding(top = 8.dp), shape = RoundedCornerShape(23.dp), color = Panel) {
            Row(Modifier.fillMaxWidth().clickable { ui.servers.firstOrNull()?.let(onSelect) }.padding(18.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Column(Modifier.weight(1f)) {
                    Text("Автовыбор", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                    Text("Минимальная задержка • AmneziaWG", color = Secondary, fontSize = 13.sp)
                }
                Text("✓", color = Accent, fontSize = 23.sp)
            }
        }
        Spacer(Modifier.height(22.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("ДОСТУПНЫЕ СЕРВЕРЫ", color = Secondary, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.8.sp)
            TextButton(onClick = onRefresh) { Text("Обновить", color = Color.White) }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
            items(ui.servers) { s ->
                Surface(Modifier.fillMaxWidth().clickable { onSelect(s) }, shape = RoundedCornerShape(19.dp), color = Panel) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(s.flag, fontSize = 24.sp); Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(if (s.city.isBlank()) s.name else s.city, color = Color.White, fontWeight = FontWeight.SemiBold)
                            Text(if (s.online) "AmneziaWG" else "Недоступен", color = Secondary, fontSize = 13.sp)
                        }
                        Text(s.latencyMs?.let { "$it мс" } ?: "—", color = Secondary, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}
