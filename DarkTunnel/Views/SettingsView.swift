import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @Environment(\.dismiss) private var dismiss
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
                        subscriptionSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSubscriptionEditor) {
            subscriptionEditor
                .presentationDetents([.height(250)])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var speedSection: some View {
        compactSection("СКОРОСТЬ") {
            compactOption(icon: "speedometer", title: "Сбалансированная", subtitle: "3 соединения — быстрее запускается и расходует меньше батареи", selected: viewModel.speedMode == .balanced) {
                viewModel.speedMode = .balanced
            }
            compactOption(icon: "bolt.fill", title: "Максимальная", subtitle: "10 соединений — выше скорость при хорошем канале", selected: viewModel.speedMode == .maximum) {
                viewModel.speedMode = .maximum
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("СЕРВЕР")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("обновлено сейчас")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 5)

            compactCard {
                compactOption(icon: "wand.and.stars", title: "Автовыбор", subtitle: "Приложение использует сервер с минимальной задержкой", selected: viewModel.usesAutomaticServer) {
                    viewModel.selectAutomaticServer()
                }
            }

            VStack(spacing: 7) {
                ForEach(viewModel.servers) { server in
                    Button {
                        viewModel.select(server)
                    } label: {
                        HStack(spacing: 12) {
                            Text(server.flag).font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.country).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(server.city).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            latencyBadge(server.latencyMilliseconds)
                            let selected = !viewModel.usesAutomaticServer && viewModel.selectedServer.id == server.id
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected ? .white : .secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var transportSection: some View {
        compactSection("ТРАНСПОРТ") {
            ForEach(TransportKind.allCases) { transport in
                compactOption(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: transport.rawValue,
                    subtitle: transport == .automatic ? "Подбирать канал автоматически по текущей сети" : "Всегда использовать этот способ подключения",
                    selected: viewModel.preferredTransport == transport
                ) {
                    viewModel.preferredTransport = transport
                }
            }
        }
    }

    private var behaviorSection: some View {
        compactSection("АВТОМАТИКА И УВЕДОМЛЕНИЯ") {
            toggleRow(icon: "moon.zzz.fill", title: "Выключать при сне", subtitle: "Отключать VPN после блокировки iPhone", isOn: $viewModel.disconnectOnSleep)
            Divider().overlay(.white.opacity(0.07))
            toggleRow(icon: "sunrise.fill", title: "Включать при пробуждении", subtitle: "Подключаться после разблокировки", isOn: $viewModel.reconnectAfterWake)
            Divider().overlay(.white.opacity(0.07))
            toggleRow(icon: "bell.badge.fill", title: "Уведомления через VPN", subtitle: "Направлять трафик Apple Push через туннель", isOn: $viewModel.routeAPNsThroughVPN)
            Divider().overlay(.white.opacity(0.07))
            toggleRow(icon: "rectangle.on.rectangle.angled", title: "Live Activity и Dynamic Island", subtitle: "Показывать сервер, пинг и кнопку отключения на экране блокировки и в островке", isOn: $viewModel.liveActivitiesEnabled)
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ПОДПИСКА")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.leading, 5)

            Button { showingSubscriptionEditor = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Сменить ссылку активации").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("Заменить источник данных подписки и серверных настроек").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func compactSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).padding(.leading, 5)
            compactCard(content: content)
        }
    }

    private func compactCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1) }
    }

    private func compactOption(icon: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? .white : .secondary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.52, blue: 0.62))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().tint(Color(red: 0.42, green: 0.52, blue: 0.62))
        }
        .padding(.vertical, 10)
    }

    private func latencyBadge(_ value: Int) -> some View {
        let tint: Color = value < 70 ? .green : (value < 130 ? .yellow : .orange)
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(value) мс").font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private var subscriptionEditor: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(Color(red: 0.42, green: 0.52, blue: 0.62))
                    TextField("https://example.com/subscription/...", text: $subscriptionLink)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Ссылка хранится только на этом iPhone.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(18)
            .navigationTitle("Ссылка активации")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { showingSubscriptionEditor = false }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
