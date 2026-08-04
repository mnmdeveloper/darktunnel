import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vkCallLink") private var vkCallLink = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.03, green: 0.08, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        speedSection
                        transportSection
                        vkSection
                        behaviorSection
                        subscriptionSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var speedSection: some View {
        settingsCard(title: "СКОРОСТЬ", icon: "speedometer") {
            Picker("Режим", selection: $viewModel.speedMode) {
                ForEach(SpeedMode.allCases) { mode in
                    Text("\(mode.title) · \(mode.rawValue) соединения")
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
        }
    }

    private var transportSection: some View {
        settingsCard(title: "ТРАНСПОРТ", icon: "point.3.connected.trianglepath.dotted") {
            Picker("Режим", selection: $viewModel.preferredTransport) {
                ForEach(TransportKind.allCases) { transport in
                    Text(transport.rawValue).tag(transport)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)

            Divider().overlay(.white.opacity(0.12))
            valueRow("Текущая сеть", value: viewModel.networkName)
            valueRow("Выбранный канал", value: viewModel.activeTransport.rawValue)
        }
    }

    private var vkSection: some View {
        settingsCard(title: "ВК ЗВОНОК", icon: "link") {
            TextField("https://vk.me/call/join/...", text: $vkCallLink)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Ссылку пользователь вставляет сам. Она сохраняется только на этом iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var behaviorSection: some View {
        settingsCard(title: "ПОВЕДЕНИЕ", icon: "switch.2") {
            Toggle("Отключать при блокировке", isOn: $viewModel.disconnectOnSleep)
            Toggle("Подключаться после пробуждения", isOn: $viewModel.reconnectAfterWake)
            Toggle("Направлять APNs через VPN", isOn: $viewModel.routeAPNsThroughVPN)
        }
    }

    private var subscriptionSection: some View {
        settingsCard(title: "ПОДПИСКА", icon: "checkmark.seal") {
            valueRow("Статус", value: "Активна")
            valueRow("Действует до", value: "2 сентября 2026")
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)

            VStack(spacing: 14) {
                content()
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
