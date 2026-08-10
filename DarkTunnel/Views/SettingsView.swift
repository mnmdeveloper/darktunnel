import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var announcements = AnnouncementFeed.shared
    @AppStorage("subscriptionLink") private var subscriptionLink = ""
    @State private var showingSubscriptionEditor = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        speedSection
                        serverSection
                        transportSection
                        behaviorSection
                        diagnosticsSection
                        subscriptionSection
                    }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
                }
            }
            .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary).frame(width: 36, height: 36).background(.thinMaterial, in: Circle()) }.buttonStyle(.plain)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSubscriptionEditor) { subscriptionEditor.presentationDetents([.height(250)]).presentationBackground(.ultraThinMaterial) }
        .task { await viewModel.refreshServers(); await announcements.refresh() }
    }

    private var speedSection: some View {
        compactSection("СКОРОСТЬ") {
            compactOption(icon: "speedometer", title: "Стандарт", subtitle: "5 соединений — режим по умолчанию", selected: viewModel.speedMode == .balanced) { viewModel.speedMode = .balanced }
            compactOption(icon: "bolt.fill", title: "Максимум", subtitle: "10 соединений — включается только вручную", selected: viewModel.speedMode == .maximum) { viewModel.speedMode = .maximum }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("СЕРВЕР").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary); Spacer()
                if viewModel.isRefreshingServers { ProgressView().scaleEffect(0.7) } else { Text("пинг обновлён автоматически").font(.caption2).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 5)
            if let announcement = announcements.server.first { serverAnnouncementCard(announcement).padding(.horizontal, 2) }
            compactCard { compactOption(icon: "wand.and.stars", title: "Автовыбор", subtitle: "Выбираем сервер с минимальной задержкой", selected: viewModel.usesAutomaticServer) { viewModel.selectAutomaticServer() } }
            VStack(spacing: 7) {
                ForEach(viewModel.servers) { server in
                    Button { viewModel.select(server) } label: {
                        HStack(spacing: 12) {
                            Text(server.flag).font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) { Text(server.country).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(server.city).font(.caption2).foregroundStyle(.secondary) }
                            Spacer(minLength: 6); latencyBadge(server.latencyMilliseconds)
                            let selected = !viewModel.usesAutomaticServer && viewModel.selectedServer.id == server.id
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? .white : .secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1) }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func serverAnnouncementCard(_ announcement: DarkTunnelRemoteAnnouncement) -> some View {
        let color = announcement.accentColor
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "megaphone.fill").foregroundStyle(color).frame(width: 32, height: 32).background(color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(announcement.title).font(.caption.weight(.bold)); Text(announcement.body).font(.caption2).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.75), lineWidth: 1.3) }
    }

    private var transportSection: some View {
        compactSection("ТРАНСПОРТ") {
            compactOption(icon: "wand.and.stars", title: "Автоматически", subtitle: "Wi‑Fi → AmneziaWG · мобильная сеть → Google/VK проверка", selected: viewModel.preferredTransport == .automatic) { viewModel.preferredTransport = .automatic; viewModel.refreshConnectivity() }
            compactOption(icon: "shield.lefthalf.filled", title: "AmneziaWG", subtitle: "Всегда использовать AmneziaWG", selected: viewModel.preferredTransport == .amneziaWG) { viewModel.preferredTransport = .amneziaWG }
            compactOption(icon: "phone.fill", title: "VK обход", subtitle: "Всегда использовать обход через VK-звонок", selected: viewModel.preferredTransport == .vkTurn) { viewModel.preferredTransport = .vkTurn }
        }
    }

    private var behaviorSection: some View {
        compactSection("АВТОМАТИКА И УВЕДОМЛЕНИЯ") {
            toggleRow(icon: "moon.zzz.fill", title: "Выключать при сне", subtitle: "Отключать VPN при уходе приложения в фон", isOn: $viewModel.disconnectOnSleep)
            Divider().overlay(.white.opacity(0.07))
            toggleRow(icon: "sunrise.fill", title: "Включать при пробуждении", subtitle: "Возвращать VPN после возврата в приложение", isOn: $viewModel.reconnectAfterWake)
            Divider().overlay(.white.opacity(0.07))
            toggleRow(icon: "bell.badge.fill", title: "Уведомления через VPN", subtitle: "Сохранять настройку для полного туннеля; Push при полном VPN-маршруте идёт через VPN", isOn: $viewModel.routeAPNsThroughVPN)
            Divider().overlay(.white.opacity(0.07))
            toggleRow(icon: "rectangle.on.rectangle.angled", title: "Live Activity и Dynamic Island", subtitle: "Показывать сервер, пинг и кнопку отключения", isOn: $viewModel.liveActivitiesEnabled)
            Button { viewModel.repairLiveActivity() } label: {
                HStack(spacing: 10) { Image(systemName: viewModel.state == .connected ? "arrow.clockwise.circle.fill" : "xmark.circle.fill"); Text(viewModel.state == .connected ? "Включить / обновить Live Activity" : "Убрать Live Activity"); Spacer() }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 8)
            }.buttonStyle(.plain)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ДИАГНОСТИКА").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).padding(.leading, 5)
            NavigationLink { LogsView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.body.weight(.semibold)).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) { Text("Логи").font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text("Активация, backend, VPN и системные статусы").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1) }
            }.buttonStyle(.plain)
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ПОДПИСКА").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).padding(.leading, 5)
            Button { showingSubscriptionEditor = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) { Text("Сменить ссылку активации").font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text("Заменить источник данных подписки и серверных настроек").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1) }
            }.buttonStyle(.plain)
        }
    }

    private func compactSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).padding(.leading, 5); compactCard(content: content) }
    }

    private func compactCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }.padding(.horizontal, 12).padding(.vertical, 3).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1) }
    }

    private func compactOption(icon: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 8); Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? .white : .secondary)
            }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(Color(red: 0.42, green: 0.52, blue: 0.62)).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)); Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8); Toggle("", isOn: isOn).labelsHidden().tint(Color(red: 0.42, green: 0.52, blue: 0.62))
        }.padding(.vertical, 10)
    }

    private func latencyBadge(_ value: Int) -> some View {
        let tint: Color = value <= 0 ? .secondary : (value < 70 ? .green : (value < 130 ? .yellow : .orange))
        return HStack(spacing: 4) { Circle().fill(tint).frame(width: 6, height: 6); Text(value > 0 ? "\(value) мс" : "—").font(.caption2.monospacedDigit().weight(.semibold)) }.foregroundStyle(tint).padding(.horizontal, 9).padding(.vertical, 5).background(tint.opacity(0.14), in: Capsule())
    }

    private var subscriptionEditor: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) { Image(systemName: "link").foregroundStyle(Color(red: 0.42, green: 0.52, blue: 0.62)); TextField("darktunnel://activate?d=...", text: $subscriptionLink).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled() }
                    .padding(14).background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Ссылка хранится только на этом iPhone.").font(.caption).foregroundStyle(.secondary); Spacer()
            }.padding(18).navigationTitle("Ссылка активации").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showingSubscriptionEditor = false }.fontWeight(.semibold) } }
        }.preferredColorScheme(.dark)
    }
}
