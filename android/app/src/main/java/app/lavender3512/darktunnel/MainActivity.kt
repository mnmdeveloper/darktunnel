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
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.platform.LocalContext

private val Bg = Color(0xFF07080B)
private val Surface1 = Color(0xFF101218)
private val Surface2 = Color(0xFF171A21)
private val Stroke = Color(0xFF292D37)
private val Muted = Color(0xFF8F96A5)
private val Accent = Color(0xFFB9E7B0)
private val Danger = Color(0xFFFF807B)

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

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme.equals("darktunnel", true) &&
            (data.host.equals("activate", true) || data.host.equals("subscription", true))) {
            vm.activate(data.toString())
        }
    }
}

@Composable
fun DarkTunnelApp(vm: MainViewModel) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var settings by rememberSaveable { mutableStateOf(false) }
    var token by rememberSaveable { mutableStateOf("") }

    val vpnPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) vm.finishConnect()
        else vm.cancelPendingConnect()
    }

    MaterialTheme(colorScheme = darkScheme) {
        when {
            !ui.activated -> ActivationScreen(ui, token, { token = it }, {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                token = clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
            }) { vm.activate(token) }
            settings -> SettingsScreen(ui, { settings = false }, { vm.select(it); settings = false }, vm::refresh)
            else -> HomeScreen(ui, { settings = true }, vm::refresh, {
                if (vm.requestConnect()) {
                    val intent = VpnService.prepare(context)
                    if (intent != null) vpnPermission.launch(intent) else vm.finishConnect()
                }
            }, vm::disconnect)
        }
    }
}

private val darkScheme = androidx.compose.material3.darkColorScheme(
    background = Bg,
    surface = Surface1,
    surfaceVariant = Surface2,
    primary = Color.White,
    onPrimary = Color.Black,
    onSurface = Color.White,
    onSurfaceVariant = Muted
)

@Composable
private fun BrandIcon(size: Int = 64) {
    Surface(Modifier.size(size.dp), RoundedCornerShape((size * 0.28f).dp), Color(0xFF090A0E), shadowElevation = 10.dp) {
        androidx.compose.foundation.Image(
            painterResource(app.lavender3512.darktunnel.R.drawable.ic_brand),
            "DarkTunnel",
            Modifier.fillMaxSize().padding((size * 0.08f).dp)
        )
    }
}

@Composable
fun ActivationScreen(ui: UiState, token: String, onToken: (String) -> Unit, onPaste: () -> Unit, onActivate: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF050609), Bg, Color(0xFF0B1010)))).padding(20.dp)) {
        Column(Modifier.fillMaxWidth().align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
            BrandIcon(78)
            Spacer(Modifier.height(18.dp))
            Text("DarkTunnel", fontSize = 32.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(7.dp))
            Text("Быстрый доступ к защищённому интернету", color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(28.dp))
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Surface1, tonalElevation = 4.dp) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("Вход по подписке", fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
                    Text("Вставьте ссылку, которую вы получили после оформления подписки.", color = Muted, fontSize = 13.sp)
                    OutlinedTextField(
                        value = token,
                        onValueChange = onToken,
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("darktunnel://subscription?t=…", color = Color(0xFF5F6572), fontSize = 13.sp) },
                        textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 14.sp),
                        shape = RoundedCornerShape(17.dp),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent, unfocusedBorderColor = Stroke, cursorColor = Accent, focusedTextColor = Color.White, unfocusedTextColor = Color.White)
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        TextButton(onClick = onPaste, Modifier.weight(1f)) { Text("Вставить", color = Accent, fontWeight = FontWeight.SemiBold) }
                        Button(onClick = onActivate, enabled = token.isNotBlank() && !ui.loading, Modifier.weight(1.7f).height(52.dp), RoundedCornerShape(16.dp), colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) {
                            if (ui.loading) CircularProgressIndicator(Modifier.size(19.dp), color = Color.Black, strokeWidth = 2.dp) else Text("Войти", fontSize = 16.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    ui.error?.let { Surface(Modifier.fillMaxWidth(), RoundedCornerShape(14.dp), Danger.copy(alpha = 0.09f)) { Text(it, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(12.dp)) } }
                }
            }
            Spacer(Modifier.height(18.dp))
            Text("Поддерживаются ссылки darktunnel://subscription и обычные коды доступа.", color = Color(0xFF5F6570), fontSize = 11.sp, textAlign = TextAlign.Center)
        }
    }
}

@Composable
fun HomeScreen(ui: UiState, onSettings: () -> Unit, onRefresh: () -> Unit, onConnect: () -> Unit, onDisconnect: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                BrandIcon(48)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("DarkTunnel", fontSize = 21.sp, fontWeight = FontWeight.Bold)
                    Text(if (ui.connected) "Соединение защищено" else "Готов к подключению", color = if (ui.connected) Accent else Muted, fontSize = 12.sp)
                }
                TextButton(onClick = onRefresh, enabled = !ui.loading) { Text("↻", fontSize = 25.sp, color = Color.White) }
                TextButton(onClick = onSettings) { Text("⚙", fontSize = 22.sp, color = Color.White) }
            }
            Spacer(Modifier.height(18.dp))
            ui.selected?.let { server ->
                Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Surface1, tonalElevation = 5.dp) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(52.dp).clip(CircleShape).background(Color(0xFF20242C)), Alignment.Center) { Text(server.flag, fontSize = 26.sp) }
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(if (server.city.isBlank()) server.name else server.city, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                                Text("AmneziaWG • ${server.host}", color = Muted, fontSize = 12.sp)
                            }
                            Box(Modifier.size(10.dp).clip(CircleShape).background(if (server.online) Accent else Color(0xFFFFB454)))
                        }
                        HorizontalDivider(color = Stroke)
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Stat("ПИНГ", ui.ping); Stat("ПОРТ", server.port.toString()); Stat("СТАТУС", if (ui.connected) "ON" else "READY")
                        }
                    }
                }
            }
            Spacer(Modifier.height(18.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallCard("${ui.servers.size}", "серверов", Modifier.weight(1f))
                SmallCard(if (ui.connected) "Защищён" else "Выключен", "VPN", Modifier.weight(1f))
            }
            Spacer(Modifier.weight(1f))
            ui.error?.let { Surface(Modifier.fillMaxWidth(), RoundedCornerShape(16.dp), Danger.copy(alpha = 0.08f)) { Text(it, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(13.dp)) }; Spacer(Modifier.height(10.dp)) }
            Button(onClick = if (ui.connected) onDisconnect else onConnect, enabled = !ui.loading, modifier = Modifier.fillMaxWidth().height(62.dp), shape = RoundedCornerShape(21.dp), colors = ButtonDefaults.buttonColors(containerColor = if (ui.connected) Color(0xFF20242B) else Color.White, contentColor = if (ui.connected) Color.White else Color.Black)) {
                if (ui.loading) CircularProgressIndicator(Modifier.size(21.dp), color = if (ui.connected) Color.White else Color.Black, strokeWidth = 2.dp) else Text(if (ui.connected) "Отключить VPN" else "Подключить VPN", fontSize = 17.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable private fun Stat(label: String, value: String) { Column { Text(label, color = Muted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp); Spacer(Modifier.height(3.dp)); Text(value, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) } }

@Composable private fun SmallCard(value: String, label: String, modifier: Modifier) { Surface(modifier, RoundedCornerShape(20.dp), Surface1) { Column(Modifier.padding(16.dp)) { Text(value, fontSize = 18.sp, fontWeight = FontWeight.Bold); Spacer(Modifier.height(3.dp)); Text(label, color = Muted, fontSize = 12.sp) } } }

@Composable
fun SettingsScreen(ui: UiState, onBack: () -> Unit, onSelect: (Server) -> Unit, onRefresh: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Bg).padding(18.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) { Text("Серверы", fontSize = 29.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f)); TextButton(onClick = onBack) { Text("Готово", color = Accent, fontWeight = FontWeight.SemiBold) } }
        Spacer(Modifier.height(6.dp)); Text("Выберите точку подключения", color = Muted, fontSize = 13.sp); Spacer(Modifier.height(18.dp))
        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(22.dp), Surface1) {
            Row(Modifier.fillMaxWidth().clickable { ui.servers.minByOrNull { it.latencyMs ?: Int.MAX_VALUE }?.let(onSelect) }.padding(17.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(42.dp).clip(CircleShape).background(Color(0xFF20242C)), Alignment.Center) { Text("✦", color = Accent, fontSize = 20.sp) }
                Spacer(Modifier.width(12.dp)); Column(Modifier.weight(1f)) { Text("Автовыбор", fontSize = 17.sp, fontWeight = FontWeight.SemiBold); Text("Минимальная задержка", color = Muted, fontSize = 12.sp) }; Text("✓", color = Accent, fontSize = 20.sp)
            }
        }
        Spacer(Modifier.height(24.dp)); Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) { Text("ДОСТУПНЫЕ", color = Muted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp, modifier = Modifier.weight(1f)); TextButton(onClick = onRefresh, enabled = !ui.loading) { Text("Обновить", color = Color.White) } }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(ui.servers) { server ->
                Surface(Modifier.fillMaxWidth().clickable { onSelect(server) }, RoundedCornerShape(19.dp), Surface1) {
                    Row(Modifier.padding(15.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(server.flag, fontSize = 25.sp); Spacer(Modifier.width(12.dp)); Column(Modifier.weight(1f)) { Text(if (server.city.isBlank()) server.name else server.city, fontWeight = FontWeight.SemiBold); Text(if (server.online) "AmneziaWG" else "Недоступен", color = Muted, fontSize = 12.sp) }; Text(server.latencyMs?.let { "$it мс" } ?: "—", color = Muted, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}
