import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vkCallLink") private var vkCallLink = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.02, green: 0.07, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        speedSection
                        serverSection
                        transportSection
                        vkSection
                        behaviorSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 34, height: 34)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var speedSection: some View {
        section("СКОРОСТЬ") {
            ForEach(SpeedMode.allCases) { mode in
                choiceRow(
                    icon: mode == .balanced ? "speedometer" : "bolt.fill",
                    title: mode.title,
                    subtitle: "\(mode.rawValue) соединения",
                    selected: viewModel.speedMode == mode
                ) {
                    viewModel.speedMode = mode
                }
            }
        }
    }

    private var serverSection: some View {
        section("СЕРВЕР") {
            ForEach(viewModel.servers) { server in
                choiceRow(
                    iconText: server.flag,
                    title: server.name,
                    subtitle: "\(server.latencyMilliseconds) мс",
                    selected: viewModel.selectedServer.id == server.id
                ) {
                    viewModel.select(server)
                }
            }
        }
    }

    private var transportSection: some View {
        section("ТРАНСПОРТ") {
            ForEach(TransportKind.allCases) { transport in
                choiceRow(
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

    private var vkSection: some View {
        section("ССЫЛКА НА VK-ЗВОНОК") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.cyan)
                    TextField("https://vk.me/call/join/...", text: $vkCallLink)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Пользователь вставляет ссылку сам. Она хранится только на этом iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var behaviorSection: some View {
        section("ПОВЕДЕНИЕ") {
            Toggle("Отключать при блокировке", isOn: $viewModel.disconnectOnSleep)
            Divider().overlay(.white.opacity(0.10))
            Toggle("Подключаться после пробуждения", isOn: $viewModel.reconnectAfterWake)
            Divider().overlay(.white.opacity(0.10))
            Toggle("Направлять APNs через VPN", isOn: $viewModel.routeAPNsThroughVPN)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            VStack(spacing: 0) {
                content()
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func choiceRow(
        icon: String? = nil,
        iconText: String? = nil,
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Group {
                    if let iconText {
                        Text(iconText)
                    } else if let icon {
                        Image(systemName: icon)
                    }
                }
                .font(.title3)
                .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
}
