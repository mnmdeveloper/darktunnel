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

// ── Colour palette (matches iOS exactly) ──────────────────────────────────────
private val Bg       = Color(0xFF07080B)
private val Surface1 = Color(0xFF101218)
private val Surface2 = Color(0xFF171A21)
private val Stroke   = Color(0xFF292D37)
private val Muted    = Color(0xFF8F96A5)
private val Accent   = Color(0xFFB9E7B0)   // iOS mint-green
private val Danger   = Color(0xFFFF807B)
private val AccentDim= Color(0xFF1A2B1A)   // glow behind icon

private val darkScheme = darkColorScheme(
    background       = Bg,
    surface          = Surface1,
    surfaceVariant   = Surface2,
    primary          = Color.White,
    onPrimary        = Color.Black,
    onSurface        = Color.White,
    onSurfaceVariant = Muted,
)

// ── Activity ──────────────────────────────────────────────────────────────────
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
        val scheme = data.scheme?.lowercase() ?: return
        val host   = data.host?.lowercase()   ?: return
        if (scheme == "darktunnel" && (host == "activate" || host == "subscription"))
            vm.activate(data.toString())
    }
}

// ── Root composable ───────────────────────────────────────────────────────────
@Composable
fun DarkTunnelApp(vm: MainViewModel) {
    val ui  by vm.ui.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var showServers by rememberSaveable { mutableStateOf(false) }
    var token       by rememberSaveable { mutableStateOf("") }

    val vpnLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) vm.finishConnect()
        else vm.cancelPendingConnect()
    }

    MaterialTheme(colorScheme = darkScheme) {
        when {
            !ui.activated -> ActivationScreen(
                ui      = ui,
                token   = token,
                onToken = { token = it },
                onPaste = {
                    val cb = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    token = cb.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
                },
                onActivate = { vm.activate(token) }
            )
            showServers -> ServersScreen(
                ui       = ui,
                onBack   = { showServers = false },
                onSelect = { vm.select(it); showServers = false },
                onRefresh= vm::refresh
            )
            else -> HomeScreen(
                ui           = ui,
                onServers    = { showServers = true },
                onRefresh    = vm::refresh,
                onConnect    = {
                    if (vm.requestConnect()) {
                        val intent = VpnService.prepare(ctx)
                        if (intent != null) vpnLauncher.launch(intent)
                        else vm.finishConnect()
                    }
                },
                onDisconnect = vm::disconnect
            )
        }
    }
}

// ── Brand icon (same rounded square as iOS) ───────────────────────────────────
@Composable
private fun BrandIcon(size: Int = 64) {
    Surface(
        modifier       = Modifier.size(size.dp),
        shape          = RoundedCornerShape((size * 0.28f).dp),
        color          = Color(0xFF090A0E),
        shadowElevation= 10.dp,
    ) {
        Image(
            painter            = painterResource(R.drawable.ic_brand),
            contentDescription = "DarkTunnel",
            modifier           = Modifier
                .fillMaxSize()
                .padding((size * 0.08f).dp),
        )
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// ACTIVATION SCREEN  –  mirrors iOS BackendActivationView exactly
// ═════════════════════════════════════════════════════════════════════════════
@Composable
fun ActivationScreen(
    ui: UiState,
    token: String,
    onToken: (String) -> Unit,
    onPaste: () -> Unit,
    onActivate: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(Color(0xFF03040A), Color(0xFF070D10), Color(0xFF050609))
                )
            )
    ) {
        // Accent glow blob (top-right, like iOS)
        Box(
            modifier = Modifier
                .size(280.dp)
                .offset(x = 120.dp, y = (-100).dp)
                .blur(80.dp)
                .background(Accent.copy(alpha = 0.10f), CircleShape)
                .align(Alignment.TopEnd)
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(64.dp))

            // Icon with glow rings (iOS has shield.checkered; we use brand icon)
            Box(contentAlignment = Alignment.Center) {
                Box(
                    modifier = Modifier
                        .size(96.dp)
                        .background(Color.White.copy(alpha = 0.05f), CircleShape)
                )
                Box(
                    modifier = Modifier
                        .size(72.dp)
                        .background(Accent.copy(alpha = 0.10f), CircleShape)
                )
                BrandIcon(52)
            }

            Spacer(Modifier.height(20.dp))

            Text(
                text       = "DarkTunnel",
                fontSize   = 34.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text      = "Безопасный доступ к вашим VPN-серверам",
                color     = Muted,
                fontSize  = 14.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(34.dp))

            // Card – mirrors iOS panel
            Surface(
                modifier      = Modifier.fillMaxWidth(),
                shape         = RoundedCornerShape(28.dp),
                color         = Color(0xFF0C0F17).copy(alpha = 0.94f),
                tonalElevation= 0.dp,
            ) {
                Box {
                    // card border
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape    = RoundedCornerShape(28.dp),
                        color    = Color.Transparent,
                        border   = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.10f)),
                    ) {}

                    Column(
                        modifier = Modifier.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(0.dp),
                    ) {
                        // Label "АКТИВАЦИЯ"
                        Text(
                            text          = "АКТИВАЦИЯ",
                            color         = Accent,
                            fontSize      = 11.sp,
                            fontWeight    = FontWeight.Bold,
                            letterSpacing = 1.4.sp,
                        )
                        Spacer(Modifier.height(5.dp))
                        Text(
                            text       = "Вставьте код или ссылку из Telegram",
                            fontSize   = 19.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text     = "Подойдут и darktunnel:// ссылки, и обычный код.",
                            color    = Muted,
                            fontSize = 13.sp,
                        )
                        Spacer(Modifier.height(16.dp))

                        // Input field
                        OutlinedTextField(
                            value         = token,
                            onValueChange = onToken,
                            singleLine    = true,
                            modifier      = Modifier.fillMaxWidth(),
                            placeholder   = {
                                Text(
                                    "Код или ссылка активации",
                                    color    = Color(0xFF5F6572),
                                    fontSize = 14.sp,
                                )
                            },
                            textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                            shape     = RoundedCornerShape(17.dp),
                            colors    = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor   = Accent,
                                unfocusedBorderColor = Stroke,
                                cursorColor          = Accent,
                                focusedTextColor     = Color.White,
                                unfocusedTextColor   = Color.White,
                            ),
                            leadingIcon = {
                                Text("🔑", fontSize = 17.sp, modifier = Modifier.padding(start = 4.dp))
                            }
                        )

                        Spacer(Modifier.height(12.dp))

                        // Buttons row
                        Row(
                            modifier            = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            // Paste
                            OutlinedButton(
                                onClick  = onPaste,
                                modifier = Modifier
                                    .weight(1f)
                                    .height(52.dp),
                                shape    = RoundedCornerShape(14.dp),
                                border   = androidx.compose.foundation.BorderStroke(1.dp, Stroke),
                                colors   = ButtonDefaults.outlinedButtonColors(
                                    contentColor = Color.White.copy(alpha = 0.82f),
                                ),
                            ) {
                                Text("Вставить", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                            }

                            // Activate
                            Button(
                                onClick  = onActivate,
                                enabled  = token.isNotBlank() && !ui.loading,
                                modifier = Modifier
                                    .weight(1.7f)
                                    .height(52.dp),
                                shape    = RoundedCornerShape(14.dp),
                                colors   = ButtonDefaults.buttonColors(
                                    containerColor = Accent,
                                    contentColor   = Color.Black,
                                    disabledContainerColor = Accent.copy(alpha = 0.40f),
                                    disabledContentColor   = Color.Black.copy(alpha = 0.4f),
                                ),
                            ) {
                                if (ui.loading)
                                    CircularProgressIndicator(
                                        modifier    = Modifier.size(19.dp),
                                        color       = Color.Black,
                                        strokeWidth = 2.dp,
                                    )
                                else
                                    Row(
                                        verticalAlignment    = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    ) {
                                        Text("→", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                                        Text("Активировать", fontSize = 14.sp, fontWeight = FontWeight.Bold)
                                    }
                            }
                        }

                        // Error
                        ui.error?.let { err ->
                            Spacer(Modifier.height(12.dp))
                            Surface(
                                modifier = Modifier.fillMaxWidth(),
                                shape    = RoundedCornerShape(14.dp),
                                color    = Danger.copy(alpha = 0.09f),
                            ) {
                                Row(
                                    modifier = Modifier.padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Text("⚠", color = Danger, fontSize = 14.sp)
                                    Text(err, color = Danger, fontSize = 13.sp)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(18.dp))
            Row(
                verticalAlignment    = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("🔒", fontSize = 11.sp)
                Text(
                    "Токен привязывается к этому устройству",
                    color    = Color(0xFF5F6570),
                    fontSize = 11.sp,
                    textAlign = TextAlign.Center,
                )
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// HOME SCREEN  –  mirrors iOS main connected/disconnected view
// ═════════════════════════════════════════════════════════════════════════════
@Composable
fun HomeScreen(
    ui: UiState,
    onServers: () -> Unit,
    onRefresh: () -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Bg)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 18.dp, vertical = 16.dp),
        ) {
            // ── Header ──
            Row(
                modifier         = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BrandIcon(48)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("DarkTunnel", fontSize = 21.sp, fontWeight = FontWeight.Bold)
                    Text(
                        text     = if (ui.connected) "Соединение защищено" else "Готов к подключению",
                        color    = if (ui.connected) Accent else Muted,
                        fontSize = 12.sp,
                    )
                }
                IconBtn("↻", onClick = onRefresh, enabled = !ui.loading)
                IconBtn("⚙", onClick = onServers)
            }

            Spacer(Modifier.height(18.dp))

            // ── Server card ──
            ui.selected?.let { server ->
                Surface(
                    modifier       = Modifier.fillMaxWidth(),
                    shape          = RoundedCornerShape(28.dp),
                    color          = Surface1,
                    tonalElevation = 5.dp,
                ) {
                    Column(
                        modifier = Modifier.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Row(
                            modifier         = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // Flag circle
                            Box(
                                modifier        = Modifier
                                    .size(52.dp)
                                    .clip(CircleShape)
                                    .background(Color(0xFF20242C)),
                                contentAlignment = Alignment.Center,
                            ) { Text(server.flag, fontSize = 26.sp) }

                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    text       = if (server.city.isBlank()) server.name else server.city,
                                    fontSize   = 24.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                                Text(
                                    "AmneziaWG · ${server.host}",
                                    color    = Muted,
                                    fontSize = 12.sp,
                                )
                            }
                            // Online dot
                            Box(
                                modifier = Modifier
                                    .size(10.dp)
                                    .clip(CircleShape)
                                    .background(if (server.online) Accent else Color(0xFFFFB454))
                            )
                        }

                        HorizontalDivider(color = Stroke)

                        Row(
                            modifier              = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            StatLabel("ПИНГ",   ui.ping)
                            StatLabel("ПОРТ",   server.port.toString())
                            StatLabel("СТАТУС", if (ui.connected) "ON" else "READY")
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            // ── Small cards row ──
            Row(
                modifier              = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SmallCard("${ui.servers.size}", "серверов", Modifier.weight(1f))
                SmallCard(
                    value    = if (ui.connected) "Защищён" else "Выключен",
                    label    = "VPN",
                    modifier = Modifier.weight(1f),
                    valueColor = if (ui.connected) Accent else Color.White,
                )
            }

            Spacer(Modifier.weight(1f))

            // ── Error ──
            ui.error?.let { err ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape    = RoundedCornerShape(16.dp),
                    color    = Danger.copy(alpha = 0.08f),
                ) {
                    Text(
                        err,
                        color    = Danger,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(13.dp),
                    )
                }
                Spacer(Modifier.height(10.dp))
            }

            // ── Connect button ──
            Button(
                onClick  = if (ui.connected) onDisconnect else onConnect,
                enabled  = !ui.loading,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(62.dp),
                shape    = RoundedCornerShape(21.dp),
                colors   = ButtonDefaults.buttonColors(
                    containerColor = if (ui.connected) Color(0xFF20242B) else Color.White,
                    contentColor   = if (ui.connected) Color.White else Color.Black,
                    disabledContainerColor = if (ui.connected) Color(0xFF20242B) else Color.White,
                    disabledContentColor   = if (ui.connected) Color.White.copy(0.5f) else Color.Black.copy(0.5f),
                ),
            ) {
                if (ui.loading)
                    CircularProgressIndicator(
                        modifier    = Modifier.size(21.dp),
                        color       = if (ui.connected) Color.White else Color.Black,
                        strokeWidth = 2.dp,
                    )
                else
                    Text(
                        text       = if (ui.connected) "Отключить VPN" else "Подключить VPN",
                        fontSize   = 17.sp,
                        fontWeight = FontWeight.Bold,
                    )
            }
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// SERVERS SCREEN  –  mirrors iOS SettingsScreen / server list
// ═════════════════════════════════════════════════════════════════════════════
@Composable
fun ServersScreen(
    ui: UiState,
    onBack: () -> Unit,
    onSelect: (Server) -> Unit,
    onRefresh: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Bg)
            .padding(18.dp),
    ) {
        // Header
        Row(
            modifier         = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Серверы",
                fontSize   = 29.sp,
                fontWeight = FontWeight.Bold,
                modifier   = Modifier.weight(1f),
            )
            TextButton(onClick = onBack) {
                Text("Готово", color = Accent, fontWeight = FontWeight.SemiBold)
            }
        }

        Spacer(Modifier.height(4.dp))
        Text("Выберите точку подключения", color = Muted, fontSize = 13.sp)
        Spacer(Modifier.height(18.dp))

        // Auto-select card
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .clickable {
                    ui.servers
                        .filter { it.online && !it.amneziaConfig.isNullOrBlank() }
                        .minByOrNull { it.latencyMs ?: Int.MAX_VALUE }
                        ?.let(onSelect)
                },
            shape = RoundedCornerShape(22.dp),
            color = Surface1,
        ) {
            Row(
                modifier         = Modifier.padding(17.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier        = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF20242C)),
                    contentAlignment = Alignment.Center,
                ) { Text("✦", color = Accent, fontSize = 20.sp) }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Автовыбор", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    Text("Минимальная задержка", color = Muted, fontSize = 12.sp)
                }
                Text("✓", color = Accent, fontSize = 20.sp)
            }
        }

        Spacer(Modifier.height(24.dp))

        Row(
            modifier         = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "ДОСТУПНЫЕ",
                color         = Muted,
                fontSize      = 11.sp,
                fontWeight    = FontWeight.Bold,
                letterSpacing = 1.5.sp,
                modifier      = Modifier.weight(1f),
            )
            TextButton(onClick = onRefresh, enabled = !ui.loading) {
                Text("Обновить", color = Color.White, fontSize = 14.sp)
            }
        }

        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(ui.servers) { server ->
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(server) },
                    shape = RoundedCornerShape(19.dp),
                    color = Surface1,
                ) {
                    Row(
                        modifier         = Modifier.padding(15.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(server.flag, fontSize = 25.sp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                text       = if (server.city.isBlank()) server.name else server.city,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text     = if (server.online) "AmneziaWG" else "Недоступен",
                                color    = Muted,
                                fontSize = 12.sp,
                            )
                        }
                        Text(
                            text     = server.latencyMs?.let { "$it мс" } ?: "—",
                            color    = Muted,
                            fontSize = 12.sp,
                        )
                    }
                }
            }
        }
    }
}

// ── Small reusable composables ─────────────────────────────────────────────────
@Composable
private fun StatLabel(label: String, value: String) {
    Column {
        Text(
            text          = label,
            color         = Muted,
            fontSize      = 9.sp,
            fontWeight    = FontWeight.Bold,
            letterSpacing = 1.sp,
        )
        Spacer(Modifier.height(3.dp))
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SmallCard(
    value: String,
    label: String,
    modifier: Modifier,
    valueColor: Color = Color.White,
) {
    Surface(modifier, RoundedCornerShape(20.dp), Surface1) {
        Column(Modifier.padding(16.dp)) {
            Text(value, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = valueColor)
            Spacer(Modifier.height(3.dp))
            Text(label, color = Muted, fontSize = 12.sp)
        }
    }
}

@Composable
private fun IconBtn(icon: String, onClick: () -> Unit, enabled: Boolean = true) {
    TextButton(onClick = onClick, enabled = enabled) {
        Text(icon, fontSize = 22.sp, color = if (enabled) Color.White else Muted)
    }
}
