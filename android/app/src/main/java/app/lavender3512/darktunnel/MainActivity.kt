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
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
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

// ── Палитра — точно как iOS ──────────────────────────────────────────────────
private val Bg        = Color(0xFF0B0D12)
private val Card      = Color(0xFF13161E)
private val CardInner = Color(0xFF1A1E28)
private val Divider   = Color(0xFF21263A)
private val Txt       = Color.White
private val Muted     = Color(0xFF717A92)
private val Accent    = Color(0xFF4E7FA8)   // blue-grey, iOS accent
private val Green     = Color(0xFF3CB87A)
private val WarnBg    = Color(0xFF1C1508)
private val WarnBdr   = Color(0xFFC49A2A)
private val WarnTxt   = Color(0xFFE8C040)
private val Danger    = Color(0xFFFF5A5A)

private val Theme = darkColorScheme(
    background = Bg, surface = Card,
    primary = Txt, onPrimary = Color.Black,
    onSurface = Txt, onSurfaceVariant = Muted,
)

class MainActivity : ComponentActivity() {
    private val vm by viewModels<MainViewModel>()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vm.init(this)
        handleIntent(intent)
        setContent { MaterialTheme(colorScheme = Theme) { App(vm) } }
    }
    override fun onNewIntent(i: Intent) { super.onNewIntent(i); setIntent(i); handleIntent(i) }
    private fun handleIntent(i: Intent?) {
        val d = i?.data ?: return
        if (d.scheme?.lowercase() == "darktunnel") vm.activate(d.toString())
    }
}

@Composable
fun App(vm: MainViewModel) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var screen by remember { mutableIntStateOf(0) }
    var token  by remember { mutableStateOf("") }
    val vpnLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) vm.finishConnect() else vm.cancelPendingConnect()
    }
    when {
        !ui.activated  -> ActivationScreen(ui, token, { token = it },
            onPaste    = { val cb = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager; token = cb.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty() },
            onActivate = { vm.activate(token) })
        screen == 1    -> SettingsScreen(ui, vm) { screen = 0 }
        else           -> HomeScreen(ui,
            onSettings   = { screen = 1 },
            onRefresh    = vm::refresh,
            onConnect    = { if (vm.requestConnect()) { val i = VpnService.prepare(ctx); if (i != null) vpnLauncher.launch(i) else vm.finishConnect() } },
            onDisconnect = vm::disconnect,
            onVkLink     = vm::setVkLink)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ACTIVATION
// ─────────────────────────────────────────────────────────────────────────────
@Composable
fun ActivationScreen(ui: UiState, token: String, onToken: (String)->Unit, onPaste: ()->Unit, onActivate: ()->Unit) {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF060709), Bg))).padding(horizontal = 22.dp)) {
        Column(Modifier.fillMaxWidth().align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {

            // Иконка
            Surface(Modifier.size(96.dp), RoundedCornerShape(26.dp), CardInner, shadowElevation = 16.dp) {
                Box(contentAlignment = Alignment.Center) {
                    Text("⟳", fontSize = 46.sp, color = Accent)
                }
            }
            Spacer(Modifier.height(22.dp))
            Text("DarkTunnel", fontSize = 36.sp, fontWeight = FontWeight.Bold, color = Txt)
            Spacer(Modifier.height(6.dp))
            Text("Быстрый доступ к защищённому интернету", color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(30.dp))

            // Карточка — как iOS
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(26.dp), Card) {
                Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("Вход по подписке", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Txt)
                    Text("Вставьте ссылку, которую вы получили после оформления подписки.", color = Muted, fontSize = 13.sp)

                    OutlinedTextField(
                        value = token, onValueChange = onToken, singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("darktunnel://subscription?t=…", color = Color(0xFF3E4557), fontSize = 12.sp) },
                        textStyle = TextStyle(color = Txt, fontSize = 14.sp),
                        shape = RoundedCornerShape(18.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Green, unfocusedBorderColor = Divider,
                            cursorColor = Green, focusedTextColor = Txt, unfocusedTextColor = Txt,
                        ),
                    )

                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = onPaste, modifier = Modifier.weight(1f)) {
                            Text("Вставить", color = Green, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                        }
                        Button(
                            onClick = onActivate, enabled = token.isNotBlank() && !ui.loading,
                            modifier = Modifier.weight(2f).height(54.dp), shape = RoundedCornerShape(17.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Txt, contentColor = Color.Black,
                                disabledContainerColor = Txt.copy(alpha = 0.25f), disabledContentColor = Color.Black.copy(alpha = 0.4f)),
                        ) {
                            if (ui.loading) CircularProgressIndicator(Modifier.size(20.dp), color = Color.Black, strokeWidth = 2.dp)
                            else Text("Войти", fontSize = 17.sp, fontWeight = FontWeight.Bold)
                        }
                    }

                    ui.error?.let { err ->
                        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(14.dp), Danger.copy(alpha = 0.09f)) {
                            Text(err, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(13.dp))
                        }
                    }
                }
            }

            Spacer(Modifier.height(18.dp))
            Text("Поддерживаются ссылки darktunnel://subscription и обычные коды доступа.", color = Color(0xFF3E4557), fontSize = 11.sp, textAlign = TextAlign.Center)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME
// ─────────────────────────────────────────────────────────────────────────────
@Composable
fun HomeScreen(ui: UiState, onSettings: ()->Unit, onRefresh: ()->Unit, onConnect: ()->Unit, onDisconnect: ()->Unit, onVkLink: (String)->Unit) {
    Column(Modifier.fillMaxSize().background(Bg).padding(horizontal = 16.dp).padding(top = 16.dp, bottom = 24.dp)) {

        // ── Шапка как iOS ──
        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(22.dp), Card) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // Логотип
                    Surface(Modifier.size(46.dp), RoundedCornerShape(13.dp), CardInner) {
                        Box(contentAlignment = Alignment.Center) { Text("⟳", fontSize = 22.sp, color = Muted) }
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("DarkTunnel", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Txt)
                        Text(if (ui.activated) "Подписка активна" else "Не активировано", fontSize = 12.sp, color = Muted)
                    }
                    IconButton(onClick = onSettings) {
                        Surface(Modifier.size(36.dp), CircleShape, CardInner) {
                            Box(contentAlignment = Alignment.Center) { Text("⚙", fontSize = 18.sp, color = Txt) }
                        }
                    }
                }

                // Метрики — как iOS
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    MetricTile(Modifier.weight(1f), "📅", ui.daysLeft, "до окончания")
                    MetricTile(Modifier.weight(1f), "🖥", "${ui.servers.size}", "серверов")
                    Surface(Modifier.size(50.dp), CircleShape, CardInner) {
                        IconButton(onClick = onRefresh, enabled = !ui.isRefreshing, modifier = Modifier.fillMaxSize()) {
                            if (ui.isRefreshing) CircularProgressIndicator(Modifier.size(18.dp), color = Muted, strokeWidth = 2.dp)
                            else Text("↻", fontSize = 20.sp, color = Muted)
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(10.dp))

        // ── Анонс — как iOS ──
        ui.announcement?.let { ann ->
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(16.dp), WarnBg,
                border = BorderStroke(1.dp, WarnBdr.copy(alpha = 0.9f))) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.Top) {
                    Surface(Modifier.size(32.dp), CircleShape, WarnTxt.copy(alpha = 0.15f)) {
                        Box(contentAlignment = Alignment.Center) { Text("📢", fontSize = 16.sp) }
                    }
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text("⚠ Основной сервер имеет недостаток ⚠", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Txt)
                        Text(ann, color = Muted, fontSize = 11.sp)
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
        }

        Spacer(Modifier.weight(1f))

        // ── Панель подключения — как iOS ──
        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(28.dp), Card) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {

                // Статус + название
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                            Box(Modifier.size(8.dp).clip(CircleShape).background(
                                when (ui.vpnState) { VpnState.CONNECTED -> Green; VpnState.CONNECTING -> WarnTxt; else -> Color(0xFF3A4055) }
                            ))
                            Text(when (ui.vpnState) { VpnState.CONNECTED -> "VPN включён"; VpnState.CONNECTING -> "Подключение…"; else -> "VPN выключен" },
                                fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Muted)
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            if (ui.autoSelect) "Автовыбор"
                            else ui.selected?.city?.takeIf { it.isNotBlank() } ?: ui.selected?.name ?: "Нет сервера",
                            fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Txt
                        )
                        Text(
                            ui.error ?: when (ui.vpnState) {
                                VpnState.CONNECTING   -> if (ui.transport == TransportMode.VK_BYPASS) "Подключаем VK обход" else "Подключаем AmneziaWG"
                                VpnState.CONNECTED    -> "Соединение защищено"
                                else                  -> "Проверяем доступность сети"
                            },
                            fontSize = 12.sp, color = if (ui.error != null) Danger else Muted, maxLines = 2
                        )
                    }
                    Text(when (ui.transport) { TransportMode.VK_BYPASS -> "VK обход"; TransportMode.AMNEZIA_WG -> "AmneziaWG"; else -> "AmneziaWG" },
                        fontSize = 11.sp, color = Muted)
                }

                // Пинг-плашки — как iOS
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PingPill(Modifier.weight(1f), "📍", ui.selected?.flag ?: "🌐",
                        if (ui.autoSelect) "Основно…" else (ui.selected?.country?.takeIf { it.isNotBlank() } ?: "Сервер"))
                    PingPill(Modifier.weight(1f), "⏱", ui.ping, if (ui.connected) "пинг · авто" else "пинг сер…")
                    PingPill(Modifier.weight(1f), "📡", "Amnezia…", "сеть")
                }

                HorizontalDivider(color = Divider)

                // VK-звонок
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text("ССЫЛКА НА VK-ЗВОНОК", fontSize = 9.sp, fontWeight = FontWeight.Bold, color = Muted, letterSpacing = 1.1.sp)
                    var vkText by remember { mutableStateOf(ui.vkCallLink) }
                    LaunchedEffect(ui.vkCallLink) { if (vkText != ui.vkCallLink) vkText = ui.vkCallLink }
                    OutlinedTextField(
                        value = vkText, onValueChange = { vkText = it; onVkLink(it) },
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        leadingIcon = { Text("🔗", fontSize = 16.sp, modifier = Modifier.padding(start = 6.dp)) },
                        placeholder = { Text("https://vk.ru/call/join/…", color = Color(0xFF383F52), fontSize = 13.sp) },
                        textStyle = TextStyle(color = Txt, fontSize = 13.sp),
                        shape = RoundedCornerShape(15.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Accent.copy(alpha = 0.7f), unfocusedBorderColor = Divider,
                            cursorColor = Accent, focusedTextColor = Txt, unfocusedTextColor = Txt,
                        ),
                    )
                }

                // Кнопка подключения
                Button(
                    onClick = if (ui.connected) onDisconnect else onConnect,
                    enabled = ui.vpnState != VpnState.CONNECTING && !ui.loading,
                    modifier = Modifier.fillMaxWidth().height(58.dp), shape = RoundedCornerShape(20.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Txt, contentColor = Color.Black,
                        disabledContainerColor = Card, disabledContentColor = Muted,
                    ),
                ) {
                    if (ui.loading || ui.vpnState == VpnState.CONNECTING)
                        CircularProgressIndicator(Modifier.size(22.dp), color = Color.Black, strokeWidth = 2.dp)
                    else Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(if (ui.connected) "⏻" else "⚡", fontSize = 18.sp)
                        Text(when (ui.vpnState) { VpnState.CONNECTED -> "Отключить VPN"; else -> "Подключиться" },
                            fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS
// ─────────────────────────────────────────────────────────────────────────────
@Composable
fun SettingsScreen(ui: UiState, vm: MainViewModel, onBack: ()->Unit) {
    Column(Modifier.fillMaxSize().background(Bg)) {
        // Шапка
        Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Настройки", fontSize = 30.sp, fontWeight = FontWeight.Bold, color = Txt, modifier = Modifier.weight(1f))
            Surface(Modifier.size(34.dp), CircleShape, Card) {
                IconButton(onClick = onBack) { Text("✕", fontSize = 14.sp, color = Muted) }
            }
        }

        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp), contentPadding = PaddingValues(bottom = 36.dp)) {

            // СКОРОСТЬ
            item {
                SectionBlock("СКОРОСТЬ") {
                    SectionRow("⏱", "Стандарт", "5 соединений — режим по умолчанию", ui.speedMode == SpeedMode.BALANCED) { vm.setSpeed(SpeedMode.BALANCED) }
                    HorizontalDivider(Modifier.padding(start = 50.dp), color = Divider)
                    SectionRow("⚡", "Максимум", "10 соединений — включается только вручную", ui.speedMode == SpeedMode.MAXIMUM) { vm.setSpeed(SpeedMode.MAXIMUM) }
                }
            }

            // СЕРВЕР
            item {
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    SectionLabel("СЕРВЕР", trailing = {
                        if (ui.isRefreshing) CircularProgressIndicator(Modifier.size(13.dp), color = Muted, strokeWidth = 1.5.dp)
                        else Text("*", fontSize = 18.sp, color = Muted)
                    })
                    // Автовыбор
                    Surface(Modifier.fillMaxWidth(), RoundedCornerShape(20.dp), Card) {
                        SectionRow("✦", "Автовыбор", "Выбираем сервер с минимальной задержкой", ui.autoSelect) { vm.selectAuto() }
                    }
                    // Серверы
                    ui.servers.forEach { srv ->
                        Surface(Modifier.fillMaxWidth().clickable { vm.select(srv) }, RoundedCornerShape(20.dp), Card) {
                            Row(Modifier.padding(horizontal = 15.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                // Флаг в кружке
                                Surface(Modifier.size(40.dp), CircleShape, CardInner) {
                                    Box(contentAlignment = Alignment.Center) { Text(srv.flag, fontSize = 20.sp) }
                                }
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(srv.country.ifBlank { srv.name }, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Txt)
                                    Text(srv.city.ifBlank { srv.host }, fontSize = 12.sp, color = Muted)
                                }
                                // Переключатель — как iOS Toggle
                                val sel = !ui.autoSelect && ui.selected?.id == srv.id
                                Surface(Modifier.size(height = 28.dp, width = 46.dp), RoundedCornerShape(50),
                                    if (sel) Accent.copy(alpha = 0.2f) else CardInner,
                                    border = BorderStroke(1.dp, if (sel) Accent else Divider)) {
                                    Box(Modifier.fillMaxSize().padding(horizontal = 4.dp), contentAlignment = if (sel) Alignment.CenterEnd else Alignment.CenterStart) {
                                        Surface(Modifier.size(20.dp), CircleShape, if (sel) Accent else Muted) {}
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ТРАНСПОРТ
            item {
                SectionBlock("ТРАНСПОРТ") {
                    SectionRow("✦", "Автоматически", "Wi-Fi → AmneziaWG · мобильная сеть → Google/VK проверка", ui.transport == TransportMode.AUTOMATIC) { vm.setTransport(TransportMode.AUTOMATIC) }
                    HorizontalDivider(Modifier.padding(start = 50.dp), color = Divider)
                    SectionRow("◑", "AmneziaWG", "Всегда использовать AmneziaWG", ui.transport == TransportMode.AMNEZIA_WG) { vm.setTransport(TransportMode.AMNEZIA_WG) }
                    HorizontalDivider(Modifier.padding(start = 50.dp), color = Divider)
                    SectionRow("📞", "VK обход", "Всегда использовать обход через VK-звонок", ui.transport == TransportMode.VK_BYPASS) { vm.setTransport(TransportMode.VK_BYPASS) }
                }
            }

            // ПОДПИСКА
            item {
                SectionBlock("ПОДПИСКА") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Surface(Modifier.size(36.dp), CircleShape, CardInner) {
                            Box(contentAlignment = Alignment.Center) { Text("👤", fontSize = 17.sp) }
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text("Моя подписка", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Txt)
                            Text("Срок: ${ui.daysLeft} · ${ui.servers.size} серверов", fontSize = 12.sp, color = Muted)
                        }
                        Text("›", fontSize = 20.sp, color = Muted)
                    }
                }
            }
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
@Composable
private fun MetricTile(modifier: Modifier, icon: String, value: String, label: String) {
    Surface(modifier.height(50.dp), RoundedCornerShape(14.dp), CardInner) {
        Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(icon, fontSize = 15.sp)
            Spacer(Modifier.width(8.dp))
            Column {
                Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Txt)
                Text(label, fontSize = 10.sp, color = Muted)
            }
        }
    }
}

@Composable
private fun PingPill(modifier: Modifier, icon: String, title: String, subtitle: String) {
    Surface(modifier.height(52.dp), RoundedCornerShape(14.dp), CardInner) {
        Row(Modifier.padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(icon, fontSize = 12.sp, color = Accent)
            Spacer(Modifier.width(5.dp))
            Column {
                Text(title, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Txt, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, fontSize = 9.sp, color = Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun SectionLabel(title: String, trailing: @Composable ()->Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(start = 5.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Muted, letterSpacing = 1.2.sp, modifier = Modifier.weight(1f))
        trailing()
    }
}

@Composable
private fun SectionBlock(title: String, content: @Composable ColumnScope.()->Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        SectionLabel(title)
        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(22.dp), Card) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 2.dp), content = content)
        }
    }
}

@Composable
private fun SectionRow(icon: String, title: String, subtitle: String, selected: Boolean, onClick: ()->Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
        Surface(Modifier.size(34.dp), CircleShape, CardInner) {
            Box(contentAlignment = Alignment.Center) { Text(icon, fontSize = 16.sp) }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Txt)
            Text(subtitle, fontSize = 11.sp, color = Muted, maxLines = 2)
        }
        Spacer(Modifier.width(10.dp))
        // Чекбокс iOS-стиля
        Surface(Modifier.size(24.dp), CircleShape, if (selected) Txt else CardInner,
            border = BorderStroke(1.5.dp, if (selected) Txt else Divider)) {
            if (selected) Box(contentAlignment = Alignment.Center) {
                Text("✓", fontSize = 12.sp, color = Color.Black, fontWeight = FontWeight.Bold)
            }
        }
    }
}
