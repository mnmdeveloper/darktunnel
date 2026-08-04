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
                    VStack(spacing: 22) {
                        speedSection
                        serverSection
                        transportSection
                        subscriptionSection
                        behaviorSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 34)
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
                            .frame(width: 38, height: 38)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSubscriptionEditor) {
            subscriptionEditor
                .presentationDetents([.height(260)])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var speedSection: some View {
        settingsSection("СКОРОСТЬ") {
            ForEach(SpeedMode.allCases) { mode in
                optionRow(
                    icon: mode == .balanced ? "speedometer" : "bolt.fill",
                    title: mode == .balanced ? "Сбалансированная" : "Максимальная",
                    subtitle: mode == .balanced ? "3 соединения — быстрое подключение" : "10 соединений — максимальная скорость",
                    selected: viewModel.speedMode == mode
                ) {
                    viewModel.speedMode = mode
                }
            }
        }
    }

    private var serverSection: some View {
        settingsSection("СЕРВЕР", trailing: "обновлено только что") {
            optionRow(
                icon: "wand.and.stars",
                title: "Автовыбор",
                subtitle: "Сервер с наименьшей задержкой",
                selected: viewModel.selectedServer.id == viewModel.servers.min(by: { $0.latencyMilliseconds < $1.latencyMilliseconds })?.id
            ) {
                if let fastest = viewModel.servers.min(by: { $0.latencyMilliseconds < $1.latencyMilliseconds }) {
                    viewModel.select(fastest)
                }
            }

            ForEach(viewModel.servers) { server in
                serverRow(server)
            }
        }
    }

    private var transportSection: some View {
        settingsSection("ТРАНСПОРТ") {
            ForEach(TransportKind.allCases) { transport in
                optionRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: transport.rawValue,
                    subtitle: transport == .automatic ? "Автовыбор по текущей сети" : "Использовать этот канал",
                    selected: viewModel.preferredTransport == transport
                ) {
                    viewModel.preferredTransport = transport
                }
            }
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ПОДПИСКА")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            Button {
                showingSubscriptionEditor = true
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Сменить ссылку активации")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subscriptionLink.isEmpty ? "Ссылка не указана" : "Ссылка сохранена")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var behaviorSection: some View {
        settingsSection("ПОВЕДЕНИЕ") {
            Toggle("Отключать при блокировке", isOn: $viewModel.disconnectOnSleep)
                .padding(.vertical, 11)
            Divider().overlay(.white.opacity(0.08))
            Toggle("Подключаться после пробуждения", isOn: $viewModel.reconnectAfterWake)
                .padding(.vertical, 11)
            Divider().overlay(.white.opacity(0.08))
            Toggle("Направлять APNs через VPN", isOn: $viewModel.routeAPNsThroughVPN)
                .padding(.vertical, 11)
        }
    }

    private func serverRow(_ server: VPNServer) -> some View {
        Button {
            viewModel.select(server)
        } label: {
            HStack(spacing: 13) {
                Text(server.flag)
                    .font(.title3)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.country)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(server.city)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                latencyBadge(server.latencyMilliseconds)

                Image(systemName: viewModel.selectedServer.id == server.id ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(viewModel.selectedServer.id == server.id ? .white : .secondary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func latencyBadge(_ value: Int) -> some View {
        let tint: Color = value < 70 ? .green : (value < 130 ? .yellow : .orange)

        return HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text("\(value) мс")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private func settingsSection<Content: View>(
        _ title: String,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
        }
    }

    private func optionRow(
        icon: String,
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 10)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? .white : .secondary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subscriptionEditor: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.cyan)
                    TextField("https://example.com/subscription/...", text: $subscriptionLink)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Ссылка хранится только на этом iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(18)
            .navigationTitle("Ссылка активации")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { showingSubscriptionEditor = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
