import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Скорость") {
                    Picker("Режим", selection: $viewModel.speedMode) {
                        ForEach(SpeedMode.allCases) { mode in
                            Text("\(mode.title) · \(mode.rawValue) соединения")
                                .tag(mode)
                        }
                    }
                }

                Section("Транспорт") {
                    Picker("Режим", selection: $viewModel.preferredTransport) {
                        ForEach(TransportKind.allCases) { transport in
                            Text(transport.rawValue).tag(transport)
                        }
                    }

                    LabeledContent("Текущая сеть", value: viewModel.networkName)
                    LabeledContent("Выбранный канал", value: viewModel.activeTransport.rawValue)
                }

                Section("Поведение") {
                    Toggle("Отключать при блокировке", isOn: $viewModel.disconnectOnSleep)
                    Toggle("Подключаться после пробуждения", isOn: $viewModel.reconnectAfterWake)
                    Toggle("Направлять APNs через VPN", isOn: $viewModel.routeAPNsThroughVPN)
                }

                Section("Подписка") {
                    LabeledContent("Статус", value: "Активна")
                    LabeledContent("Действует до", value: "2 сентября 2026")
                    Button("Ввести ссылку активации") { }
                }

                Section("Диагностика") {
                    Button("Скопировать отчёт") { }
                    Button("Проверить серверы") { }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
