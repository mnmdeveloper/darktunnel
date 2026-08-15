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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.platform.LocalContext

// ── Palette (matches iOS exactly) ──────────────────────────────────────────
private val Bg       = Color(0xFF07080B)
private val Surface1 = Color(0xFF101218)
private val Stroke   = Color(0xFF292D37)
private val Muted    = Color(0xFF8F96A5)
private val Accent   = Color(0xFFB9E7B0)   // iOS green accent
private val Danger   = Color(0xFFFF807B)

private val DarkScheme = darkColorScheme(
    background        = Bg,
    surface           = Surface1,
    surfaceVariant    = Color(0xFF171A21),
    primary           = Color.White,
    onPrimary         = Color.Black,
    onSurface         = Color.White,
    onSurfaceVariant  = Muted,
)

// ── Activity ────────────────────────────────────────────────────────────────
class MainActivity : ComponentActivity() {
    private val vm by viewModels<MainViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vm.init(this)
        handleIntent(intent)
        setContent { MaterialTheme(colorScheme = DarkScheme) { DarkTunnelApp(vm) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        val scheme = data.scheme?.lowercase()
        val host   = data.host?.lowercase()
        if (scheme == "darktunnel" && (host == "activate" || host == "subscription"))
            vm.activate(data.toString())
    }
}

// ── Root composable ─────────────────────────────────────────────────────────
@Composable
fun DarkTunnelApp(vm: MainViewModel) {
    val ui  by vm.ui.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var token        by rememberSaveable { mutableStateOf("") }

    val vpnLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { r ->
        if (r.resultCode == Activity.RESULT_OK) vm.finishConnect() else vm.cancelPendingConnect()
    }

    when {
        !ui.activated -> ActivationScreen(
            ui      = ui,
            token   = token,
            onToken = { token = it },
            onPaste = {
                val cb = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                token  = cb.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
            },
            onActivate = { vm.activate(token) }
        )

        showSettings -> SettingsScreen(
            ui       = ui,
            onBack   = { showSettings = false },
            onSelect = { vm.select(it); showSettings = false },
            onRefresh = vm::refresh
        )

        else -> HomeScreen(
            ui           = ui,
            onSettings   = { showSettings = true },
            onRefresh    = vm::refresh,
            onConnect    = {
                if (vm.requestConnect()) {
                    val intent = VpnService.prepare(ctx)
                    if (intent != null) vpnLauncher.launch(intent) else vm.finishConnect()
                }
            },
            onDisconnect = vm::disconnect
        )
    }
}

// ── Brand icon (same rounded-square style as iOS) ───────────────────────────
@Composable
private fun BrandIcon(size: Int = 64) {
    Surface(
        modifier        = Modifier.size(size.dp),
        shape           = RoundedCornerShape((size * 0.28f).dp),
        color           = Color(0xFF090A0E),
        shadowElevation = 10.dp,
    ) {
        Image(
            painter            = painterResource(R.drawable.ic_brand),
            contentDescription = "DarkTunnel",
            modifier           = Modifier
                .fillMaxSize()
                .padding((size * 0.10f).dp),
        )
    }
}

// ── ACTIVATION SCREEN ───────────────────────────────────────────────────────
// Matches iOS BackendActivationView exactly:
// dark gradient bg, centred card, outlined text field with accent focus border,
// "Вставить" text-button + white "Войти" button, error banner at bottom of card.
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
                    listOf(Color(0xFF050609), Bg, Color(0xFF0B1010))
                )
            )
            .padding(horizontal = 20.dp),
    ) {
        Column(
            modifier              = Modifier.fillMaxWidth().align(Alignment.Center),
            horizontalAlignment   = Alignment.CenterHorizontally,
        ) {
            // Logo + title
            BrandIcon(78)
            Spacer(Modifier.height(18.dp))
            Text("DarkTunnel", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Spacer(Modifier.height(6.dp))
            Text(
                "Быстрый доступ к защищённому интернету",
                color     = Muted,
                fontSize  = 14.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(28.dp))

            // Card — matches iOS panel
            Surface(
                modifier        = Modifier.fillMaxWidth(),
                shape           = RoundedCornerShape(28.dp),
                color           = Surface1,
                tonalElevation  = 4.dp,
            ) {
                Column(
                    modifier              = Modifier.padding(20.dp),
                    verticalArrangement   = Arrangement.spacedBy(14.dp),
                ) {
                    Text("Вход по подписке", fontSize = 21.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    Text(
                        "Вставьте ссылку, которую вы получили после оформления подписки.",
                        color    = Muted,
                        fontSize = 13.sp,
                    )

                    // Text field with accent focus border
                    OutlinedTextField(
                        value         = token,
                        onValueChange = onToken,
                        singleLine    = true,
                        modifier      = Modifier.fillMaxWidth(),
                        placeholder   = {
                            Text(
                                "darktunnel://subscription?t=…",
                                color    = Color(0xFF5F6572),
                                fontSize = 13.sp,
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
                    )

                    // Buttons row
                    Row(
                        modifier              = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment     = Alignment.CenterVertically,
                    ) {
                        TextButton(
                            onClick  = onPaste,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("Вставить", color = Accent, fontWeight = FontWeight.SemiBold)
                        }
                        Button(
                            onClick  = onActivate,
                            enabled  = token.isNotBlank() && !ui.loading,
                            modifier = Modifier.weight(1.7f).height(52.dp),
                            shape    = RoundedCornerShape(16.dp),
                            colors   = ButtonDefaults.buttonColors(
                                containerColor         = Color.White,
                                contentColor           = Color.Black,
                                disabledContainerColor = Color.White.copy(alpha = 0.35f),
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
                                Text("Войти", fontSize = 16.sp, fontWeight = FontWeight.Bold)
                        }
                    }

                    // Error banner
                    ui.error?.let { err ->
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape    = RoundedCornerShape(14.dp),
                            color    = Danger.copy(alpha = 0.09f),
                        ) {
                            Text(err, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(12.dp))
                        }
                    }
                }
            }

            Spacer(Modifier.height(18.dp))
            Text(
                "Поддерживаются ссылки darktunnel://subscription и обычные коды доступа.",
                color     = Color(0xFF5F6570),
                fontSize  = 11.sp,
                textAlign = TextAlign.Center,
            )
        }
    }
}

// ── HOME SCREEN ─────────────────────────────────────────────────────────────
@Composable
fun HomeScreen(
    ui: UiState,
    onSettings: () -> Unit,
    onRefresh: () -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
) {
    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 18.dp)
                .padding(top = 16.dp, bottom = 24.dp),
        ) {
            // ── Top bar ──
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                BrandIcon(48)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("DarkTunnel", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = Color.White)
                    Text(
                        if (ui.connected) "Соединение защищено" else "Готов к подключению",
                        color    = if (ui.connected) Accent else Muted,
                        fontSize = 12.sp,
                    )
                }
                IconTextButton("↻", onRefresh, enabled = !ui.loading)
                IconTextButton("⚙", onSettings)
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
                        modifier            = Modifier.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            // Flag circle
                            Box(
                                modifier          = Modifier.size(52.dp).clip(CircleShape).background(Color(0xFF20242C)),
                                contentAlignment  = Alignment.Center,
                            ) {
                                Text(server.flag, fontSize = 26.sp)
                            }
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    server.city.ifBlank { server.name },
                                    fontSize   = 24.sp,
                                    fontWeight = FontWeight.Bold,
                                    color      = Color.White,
                                )
                                Text("AmneziaWG • ${server.host}", color = Muted, fontSize = 12.sp)
                            }
                            // Online indicator dot
                            Box(
                                Modifier.size(10.dp).clip(CircleShape)
                                    .background(if (server.online) Accent else Color(0xFFFFB454))
                            )
                        }

                        HorizontalDivider(color = Stroke)

                        Row(
                            modifier              = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            StatCell("ПИНГ",   ui.ping)
                            StatCell("ПОРТ",   server.port.toString())
                            StatCell("СТАТУС", if (ui.connected) "ON" else "READY")
                        }
                    }
                }
            }

            Spacer(Modifier.height(18.dp))

            // ── Stats row ──
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallCard("${ui.servers.size}", "серверов", Modifier.weight(1f))
                SmallCard(if (ui.connected) "Защищён" else "Выключен", "VPN", Modifier.weight(1f))
            }

            Spacer(Modifier.weight(1f))

            // ── Error banner ──
            ui.error?.let { err ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape    = RoundedCornerShape(16.dp),
                    color    = Danger.copy(alpha = 0.08f),
                ) {
                    Text(err, color = Danger, fontSize = 13.sp, modifier = Modifier.padding(13.dp))
                }
                Spacer(Modifier.height(10.dp))
            }

            // ── Connect / Disconnect button ──
            val connected = ui.connected
            Button(
                onClick  = if (connected) onDisconnect else onConnect,
                enabled  = !ui.loading,
                modifier = Modifier.fillMaxWidth().height(62.dp),
                shape    = RoundedCornerShape(21.dp),
                colors   = ButtonDefaults.buttonColors(
                    containerColor         = if (connected) Color(0xFF20242B) else Color.White,
                    contentColor           = if (connected) Color.White else Color.Black,
                    disabledContainerColor = Color(0xFF20242B).copy(alpha = 0.5f),
                    disabledContentColor   = Color.White.copy(alpha = 0.4f),
                ),
            ) {
                if (ui.loading)
                    CircularProgressIndicator(
                        modifier    = Modifier.size(21.dp),
                        color       = if (connected) Color.White else Color.Black,
                        strokeWidth = 2.dp,
                    )
                else
                    Text(
                        if (connected) "Отключить VPN" else "Подключить VPN",
                        fontSize   = 17.sp,
                        fontWeight = FontWeight.Bold,
                    )
            }
        }
    }
}

// ── SETTINGS / SERVERS SCREEN ────────────────────────────────────────────────
@Composable
fun SettingsScreen(
    ui: UiState,
    onBack: () -> Unit,
    onSelect: (Server) -> Unit,
    onRefresh: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Bg)
            .padding(horizontal = 18.dp)
            .padding(top = 16.dp),
    ) {
        // Title row
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Серверы",
                fontSize   = 29.sp,
                fontWeight = FontWeight.Bold,
                color      = Color.White,
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
        Surface(Modifier.fillMaxWidth(), RoundedCornerShape(22.dp), Surface1) {
            Row(
                modifier          = Modifier
                    .fillMaxWidth()
                    .clickable { ui.servers.minByOrNull { it.latencyMs ?: Int.MAX_VALUE }?.let(onSelect) }
                    .padding(17.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier         = Modifier.size(42.dp).clip(CircleShape).background(Color(0xFF20242C)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("✦", color = Accent, fontSize = 20.sp)
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Автовыбор", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    Text("Минимальная задержка", color = Muted, fontSize = 12.sp)
                }
                Text("✓", color = Accent, fontSize = 20.sp)
            }
        }

        Spacer(Modifier.height(24.dp))

        // Section header
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                "ДОСТУПНЫЕ",
                color         = Muted,
                fontSize      = 11.sp,
                fontWeight    = FontWeight.Bold,
                letterSpacing = 1.5.sp,
                modifier      = Modifier.weight(1f),
            )
            TextButton(onClick = onRefresh, enabled = !ui.loading) {
                Text("Обновить", color = Color.White)
            }
        }

        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(ui.servers) { server ->
                Surface(
                    modifier = Modifier.fillMaxWidth().clickable { onSelect(server) },
                    shape    = RoundedCornerShape(19.dp),
                    color    = Surface1,
                ) {
                    Row(
                        modifier          = Modifier.padding(15.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(server.flag, fontSize = 25.sp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                server.city.ifBlank { server.name },
                                color      = Color.White,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                if (server.online) "AmneziaWG" else "Недоступен",
                                color    = Muted,
                                fontSize = 12.sp,
                            )
                        }
                        Text(
                            server.latencyMs?.let { "$it мс" } ?: "—",
                            color    = Muted,
                            fontSize = 12.sp,
                        )
                    }
                }
            }
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────
@Composable
private fun StatCell(label: String, value: String) {
    Column {
        Text(label, color = Muted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
        Spacer(Modifier.height(3.dp))
        Text(value, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SmallCard(value: String, label: String, modifier: Modifier) {
    Surface(modifier, RoundedCornerShape(20.dp), Surface1) {
        Column(Modifier.padding(16.dp)) {
            Text(value, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(3.dp))
            Text(label, color = Muted, fontSize = 12.sp)
        }
    }
}

@Composable
private fun IconTextButton(icon: String, onClick: () -> Unit, enabled: Boolean = true) {
    TextButton(onClick = onClick, enabled = enabled) {
        Text(icon, fontSize = 22.sp, color = if (enabled) Color.White else Muted)
    }
}
