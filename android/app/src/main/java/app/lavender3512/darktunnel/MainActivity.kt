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
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

// ── Palette ──────────────────────────────────────────────────────────────────
private val Bg       = Color(0xFF07080B)
private val Panel    = Color(0xFF10131A)
private val Stroke   = Color(0xFF1E2330)
private val Muted    = Color(0xFF6B7385)
private val Accent   = Color(0xFF6087A0)   // iOS blue-grey accent
private val AccentBg = Color(0xFF131B24)
private val Danger   = Color(0xFFFF6B6B)
private val WarnBg   = Color(0xFF1E1608)
private val WarnFg   = Color(0xFFD4A843)

private val DarkScheme = darkColorScheme(
    background       = Bg,
    surface          = Panel,
    primary          = Color.White,
    onPrimary        = Color.Black,
    onSurface        = Color.White,
    onSurfaceVariant = Muted,
)

// ── Activity ─────────────────────────────────────────────────────────────────
class MainActivity : ComponentActivity() {
    private val vm by viewModels<MainViewModel>()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vm.init(this)
        handleIntent(intent)
        setContent { MaterialTheme(colorScheme = DarkScheme) { DarkTunnelApp(vm) } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent) }
    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme?.lowercase() == "darktunnel")
            vm.activate(data.toString())
    }
}

// ── Screen enum ──────────────────────────────────────────────────────────────
private enum class Screen { HOME, SETTINGS }

// ── Root ─────────────────────────────────────────────────────────────────────
@Composable
fun DarkTunnelApp(vm: MainViewModel) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var screen by rememberSaveable { mutableStateOf(Screen.HOME) }
    var token  by rememberSaveable { mutableStateOf("") }

    val vpnLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) vm.finishConnect() else vm.cancelPendingConnect()
    }

    when {
        !ui.activated -> ActivationScreen(ui, token, { token = it },
            onPaste = {
                val cb = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                token = cb.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
            },
            onActivate = { vm.activate(token) })
        screen == Screen.SETTINGS -> SettingsScreen(ui, vm, onBack = { screen = Screen.HOME })
        else -> HomeScreen(ui,
            onSettings  = { screen = Screen.SETTINGS },
            onRefresh   = vm::refresh,
            onConnect   = {
                if (vm.requestConnect()) {
                    val intent = VpnService.prepare(ctx)
                    if (intent != null) vpnLauncher.launch(intent) else vm.finishConnect()
                }
            },
            onDisconnect = vm::disconnect,
            onVkLink    = { vm.setVkLink(it) }
        )
    }
}

// ── ACTIVATION ───────────────────────────────────────────────────────────────
@Composable
fun ActivationScreen(ui: UiState, token: String, onToken: (String)->Unit, onPaste: ()->Unit, onActivate: ()->Unit) {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF030508), Bg, Color(0xFF060D12)))).padding(horizontal = 20.dp)) {
        Column(Modifier.fillMaxWidth().align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
            // Icon
            Surface(Modifier.size(88.dp), RoundedCornerShape(24.dp), Color(0xFF0D1017), shadowElevation = 12.dp) {
                Box(contentAlignment = Alignment.Center) {
                    Text("⟳", fontSize = 42.sp, color = Accent)
                }
            }
            Spacer(Modifier.height(20.dp))
            Text("DarkTunnel", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Spacer(Modifier.height(6.dp))
            Text("Безопасный доступ к VPN-серверам", color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(32.dp))

            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Panel) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("АКТИВАЦИЯ", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Accent, letterSpacing = 1.4.sp)
                    Spacer(Modifier.height(2.dp))
                    Text("Вставьте код или ссылку из Telegram", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    Text("Подойдут и darktunnel:// ссылки, и обычный код.", color = Muted, fontSize = 12.sp)
                    Spacer(Modifier.height(8.dp))

                    OutlinedTextField(
                        value = token, onValueChange = onToken, singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("Код или ссылка активации", color = Color(0xFF434B5C), fontSize = 13.sp) },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        shape = RoundedCornerShape(17.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Accent, unfocusedBorderColor = Stroke,
                            cursorColor = Accent, focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                        ),
                    )
                    Spacer(Modifier.height(4.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = onPaste, modifier = Modifier.weight(1f)) {
                            Text("Вставить", color = Accent, fontWeight = FontWeight.SemiBold)
                        }
                        Button(
                            onClick = onActivate, enabled = token.isNotBlank() && !ui.loading,
                            modifier = Modifier.weight(1.8f).height(52.dp), shape = RoundedCornerShape(16.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black,
                                disabledContainerColor = Color.White.copy(alpha = 0.3f), disabledContentColor = Color.Black.copy(alpha = 0.4f)),
                        ) {
                            if (ui.loading) CircularProgressIndicator(Modifier.size(19.dp), color = Color.Black, strokeWidth = 2.dp)
                            else Text("Активировать", fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    ui.error?.let { err ->
                        Spacer(Modifier.height(4.dp))
                        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(14.dp), Danger.copy(alpha = 0.08f)) {
                            Text(err, color = Danger, fontSize = 12.sp, modifier = Modifier.padding(12.dp))
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
            Text("Токен привязывается к этому устройству", color = Color(0xFF3D4555), fontSize = 11.sp, textAlign = TextAlign.Center)
        }
    }
}

// ── HOME ──────────────────────────────────────────────────────────────────────
@Composable
fun HomeScreen(ui: UiState, onSettings: ()->Unit, onRefresh: ()->Unit, onConnect: ()->Unit, onDisconnect: ()->Unit, onVkLink: (String)->Unit) {
    Box(Modifier.fillMaxSize().background(Bg)) {
        // Map-like dark gradient background (no real map on Android to keep APK small)
        Box(Modifier.fillMaxSize().background(
            Brush.verticalGradient(listOf(Color(0xFF060A0F), Color(0xFF0A0E16), Color(0xFF080C12)))
        ))

        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 20.dp)) {

            // ── Header panel (matches iOS header card) ──
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(24.dp), Panel) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // Shield icon
                        Box(Modifier.size(40.dp).clip(CircleShape).background(AccentBg), contentAlignment = Alignment.Center) {
                            Text("◑", fontSize = 18.sp, color = Accent)
                        }
                        Spacer(Modifier.width(11.dp))
                        Column(Modifier.weight(1f)) {
                            Text("DarkTunnel", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
                            Text(if (ui.activated) "Подписка активна" else "Требуется активация", fontSize = 11.sp, color = Muted)
                        }
                        IconButton(onClick = onSettings, modifier = Modifier.size(38.dp)) {
                            Surface(Modifier.fillMaxSize(), CircleShape, Panel.copy(alpha = 0.92f)) {
                                Box(contentAlignment = Alignment.Center) { Text("⚙", fontSize = 17.sp, color = Color.White) }
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        MetricCard("📅", ui.daysLeft, "до окончания", Modifier.weight(1f))
                        MetricCard("🖥", "${ui.servers.size}", "серверов", Modifier.weight(1f))
                        // Refresh button
                        Surface(Modifier.size(44.dp), CircleShape, AccentBg) {
                            IconButton(onClick = onRefresh, enabled = !ui.isRefreshing) {
                                if (ui.isRefreshing) CircularProgressIndicator(Modifier.size(18.dp), color = Accent, strokeWidth = 2.dp)
                                else Text("↻", fontSize = 18.sp, color = Accent)
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(8.dp))

            // ── Announcement banner ──
            ui.announcement?.let { ann ->
                Surface(Modifier.fillMaxWidth(), RoundedCornerShape(14.dp), WarnBg) {
                    Row(Modifier.padding(horizontal = 11.dp, vertical = 8.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Surface(Modifier.size(28.dp), CircleShape, WarnFg.copy(alpha = 0.16f)) {
                            Box(contentAlignment = Alignment.Center) { Text("📢", fontSize = 13.sp) }
                        }
                        Spacer(Modifier.width(9.dp))
                        Text(ann, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }
                Spacer(Modifier.height(8.dp))
                Surface(Modifier.fillMaxWidth(), RoundedCornerShape(14.dp), WarnBg,
                    border = androidx.compose.foundation.BorderStroke(1.dp, WarnFg.copy(alpha = 0.75f))) {
                    Row(Modifier.padding(11.dp).fillMaxWidth(), verticalAlignment = Alignment.Top) {
                        Text("⚠", fontSize = 13.sp, color = WarnFg)
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text("Основной сервер имеет недостаток", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.White)
                            Text(ann, color = Muted, fontSize = 11.sp, maxLines = 2)
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            Spacer(Modifier.weight(1f))

            // ── Connection panel (matches iOS connectionPanel) ──
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Panel) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {

                    // Status row
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                Text(if (ui.connected) "✓" else "◯", fontSize = 14.sp, color = if (ui.connected) Color(0xFF4CAF50) else Muted)
                                Text(when (ui.vpnState) {
                                    VpnState.CONNECTED    -> "Подключено"
                                    VpnState.CONNECTING   -> "Подключение…"
                                    VpnState.DISCONNECTED -> "VPN выключен"
                                }, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                            }
                            Spacer(Modifier.height(3.dp))
                            Text(
                                if (ui.autoSelect) "Автовыбор" else (ui.selected?.city?.takeIf { it.isNotBlank() } ?: ui.selected?.name ?: "Нет сервера"),
                                fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color.White
                            )
                            Text(
                                ui.error ?: when (ui.vpnState) {
                                    VpnState.CONNECTING -> when (ui.transport) {
                                        TransportMode.VK_BYPASS -> "Подключаем VK обход"
                                        else -> "Подключаем AmneziaWG"
                                    }
                                    VpnState.CONNECTED -> "Соединение защищено"
                                    else -> "Проверяем доступность сети"
                                },
                                fontSize = 12.sp, color = if (ui.error != null) Danger else Muted, maxLines = 2
                            )
                        }
                        Text(when (ui.transport) {
                            TransportMode.VK_BYPASS   -> "VK обход"
                            TransportMode.AMNEZIA_WG  -> "AmneziaWG"
                            TransportMode.AUTOMATIC   -> "Авто"
                        }, fontSize = 11.sp, color = Muted, fontWeight = FontWeight.SemiBold)
                    }

                    // Ping pills (matches iOS pingPanel)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PingPill("📍", ui.selected?.flag ?: "🌐", ui.selected?.country?.takeIf { it.isNotBlank() } ?: "Сервер", Modifier.weight(1f))
                        PingPill("⏱", ui.ping, if (ui.connected) "пинг · 7 сек" else "пинг сервера", Modifier.weight(1f))
                        PingPill("📡", "AmneziaWG", "сеть", Modifier.weight(1f))
                    }

                    HorizontalDivider(color = Stroke)

                    // VK call link field
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("ССЫЛКА НА VK-ЗВОНОК", fontSize = 9.sp, fontWeight = FontWeight.Bold, color = Muted, letterSpacing = 1.sp)
                        var vkText by rememberSaveable { mutableStateOf(ui.vkCallLink) }
                        LaunchedEffect(ui.vkCallLink) { vkText = ui.vkCallLink }
                        OutlinedTextField(
                            value = vkText, onValueChange = { vkText = it; onVkLink(it) },
                            singleLine = true, modifier = Modifier.fillMaxWidth(),
                            placeholder = { Text("https://vk.ru/call/join/…", color = Color(0xFF3A4050), fontSize = 12.sp) },
                            textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                            shape = RoundedCornerShape(14.dp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = Accent.copy(alpha = 0.6f), unfocusedBorderColor = Stroke,
                                cursorColor = Accent, focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                            ),
                        )
                    }

                    // Connect button
                    Button(
                        onClick = if (ui.connected) onDisconnect else onConnect,
                        enabled = !ui.loading && !ui.connecting,
                        modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color.White, contentColor = Color.Black,
                            disabledContainerColor = Panel, disabledContentColor = Muted,
                        ),
                    ) {
                        if (ui.loading || ui.connecting)
                            CircularProgressIndicator(Modifier.size(21.dp), color = if (ui.connected) Color.White else Color.Black, strokeWidth = 2.dp)
                        else Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(if (ui.connected) "⏻" else "⚡", fontSize = 16.sp)
                            Text(when (ui.vpnState) {
                                VpnState.CONNECTED    -> "Отключиться"
                                VpnState.CONNECTING   -> "Отмена"
                                VpnState.DISCONNECTED -> "Подключиться"
                            }, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
}

// ── SETTINGS ─────────────────────────────────────────────────────────────────
@Composable
fun SettingsScreen(ui: UiState, vm: MainViewModel, onBack: ()->Unit) {
    Column(Modifier.fillMaxSize().background(Bg)) {
        // Top bar
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Настройки", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Color.White, modifier = Modifier.weight(1f))
            Surface(Modifier.size(36.dp), CircleShape, Panel) {
                IconButton(onClick = onBack) { Text("✕", fontSize = 14.sp, color = Muted, modifier = Modifier.wrapContentSize()) }
            }
        }

        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(18.dp),
            contentPadding = PaddingValues(bottom = 32.dp)) {

            // СКОРОСТЬ
            item {
                SettingsSection("СКОРОСТЬ") {
                    SettingsOption("⏱", "Стандарт", "5 соединений — режим по умолчанию", ui.speedMode == SpeedMode.BALANCED) { vm.setSpeed(SpeedMode.BALANCED) }
                    HorizontalDivider(color = Stroke.copy(alpha = 0.5f), modifier = Modifier.padding(start = 52.dp))
                    SettingsOption("⚡", "Максимум", "10 соединений — включается только вручную", ui.speedMode == SpeedMode.MAXIMUM) { vm.setSpeed(SpeedMode.MAXIMUM) }
                }
            }

            // СЕРВЕР
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(Modifier.fillMaxWidth().padding(start = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("СЕРВЕР", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Muted, letterSpacing = 1.2.sp, modifier = Modifier.weight(1f))
                        if (ui.isRefreshing)
                            CircularProgressIndicator(Modifier.size(14.dp), color = Muted, strokeWidth = 1.5.dp)
                        else
                            Text("пинг обновлён автоматически", fontSize = 10.sp, color = Color(0xFF3A4050))
                    }

                    // Auto-select
                    Surface(Modifier.fillMaxWidth(), RoundedCornerShape(20.dp), Panel) {
                        SettingsOption("✦", "Автовыбор", "Выбираем сервер с минимальной задержкой", ui.autoSelect) { vm.selectAuto() }
                    }

                    // Server list
                    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        ui.servers.forEach { server ->
                            Surface(Modifier.fillMaxWidth().clickable { vm.select(server) }, RoundedCornerShape(20.dp), Panel) {
                                Row(Modifier.padding(horizontal = 14.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Text(server.flag, fontSize = 22.sp, modifier = Modifier.width(28.dp))
                                    Spacer(Modifier.width(12.dp))
                                    Column(Modifier.weight(1f)) {
                                        Text(server.country.ifBlank { server.name }, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                                        Text(server.city.ifBlank { server.host }, fontSize = 11.sp, color = Muted)
                                    }
                                    Spacer(Modifier.width(6.dp))
                                    // Latency badge
                                    val lat = server.latencyMs ?: 0
                                    val latColor = when { lat <= 0 -> Muted; lat < 70 -> Color(0xFF4CAF50); lat < 130 -> Color(0xFFFFB454); else -> Color(0xFFFF7043) }
                                    Surface(shape = RoundedCornerShape(50), color = latColor.copy(alpha = 0.14f)) {
                                        Text(if (lat > 0) "$lat мс" else "—", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = latColor, modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp))
                                    }
                                    Spacer(Modifier.width(8.dp))
                                    val selected = !ui.autoSelect && ui.selected?.id == server.id
                                    Text(if (selected) "●" else "○", fontSize = 18.sp, color = if (selected) Color.White else Muted)
                                }
                            }
                        }
                    }
                }
            }

            // ТРАНСПОРТ
            item {
                SettingsSection("ТРАНСПОРТ") {
                    SettingsOption("✦", "Автоматически", "Wi-Fi → AmneziaWG · мобильная сеть → Google/VK проверка",
                        ui.transport == TransportMode.AUTOMATIC) { vm.setTransport(TransportMode.AUTOMATIC) }
                    HorizontalDivider(color = Stroke.copy(alpha = 0.5f), modifier = Modifier.padding(start = 52.dp))
                    SettingsOption("◑", "AmneziaWG", "Всегда использовать AmneziaWG",
                        ui.transport == TransportMode.AMNEZIA_WG) { vm.setTransport(TransportMode.AMNEZIA_WG) }
                    HorizontalDivider(color = Stroke.copy(alpha = 0.5f), modifier = Modifier.padding(start = 52.dp))
                    SettingsOption("📞", "VK обход", "Всегда использовать обход через VK-звонок",
                        ui.transport == TransportMode.VK_BYPASS) { vm.setTransport(TransportMode.VK_BYPASS) }
                }
            }

            // ПОДПИСКА
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("ПОДПИСКА", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Muted, letterSpacing = 1.2.sp, modifier = Modifier.padding(start = 5.dp))
                    Surface(Modifier.fillMaxWidth(), RoundedCornerShape(20.dp), Panel) {
                        Row(Modifier.padding(horizontal = 14.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("👤", fontSize = 18.sp, modifier = Modifier.width(28.dp))
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text("Моя подписка", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                                Text("Срок: ${ui.daysLeft} дней · ${ui.servers.size} серверов", fontSize = 11.sp, color = Muted)
                            }
                            Text("›", fontSize = 18.sp, color = Muted)
                        }
                    }
                }
            }
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
@Composable
private fun MetricCard(icon: String, value: String, label: String, modifier: Modifier) {
    Row(modifier.padding(horizontal = 11.dp, vertical = 9.dp).background(Color.White.copy(alpha = 0.045f), RoundedCornerShape(14.dp)).padding(horizontal = 11.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(icon, fontSize = 14.sp)
        Spacer(Modifier.width(8.dp))
        Column {
            Text(value, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            Text(label, fontSize = 10.sp, color = Muted)
        }
    }
}

@Composable
private fun PingPill(icon: String, title: String, subtitle: String, modifier: Modifier) {
    Row(modifier.background(Color.White.copy(alpha = 0.045f), RoundedCornerShape(13.dp)).padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(icon, fontSize = 11.sp, color = Accent)
        Spacer(Modifier.width(6.dp))
        Column {
            Text(title, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, fontSize = 9.sp, color = Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.()->Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Muted, letterSpacing = 1.2.sp, modifier = Modifier.padding(start = 5.dp))
        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(22.dp), Panel) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 3.dp)) { content() }
        }
    }
}

@Composable
private fun SettingsOption(icon: String, title: String, subtitle: String, selected: Boolean, onClick: ()->Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(icon, fontSize = 18.sp, modifier = Modifier.width(28.dp), textAlign = TextAlign.Center)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            Text(subtitle, fontSize = 11.sp, color = Muted)
        }
        Spacer(Modifier.width(8.dp))
        Text(if (selected) "●" else "○", fontSize = 18.sp, color = if (selected) Color.White else Muted)
    }
}
