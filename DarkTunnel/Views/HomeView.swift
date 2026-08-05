import MapKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var showingSettings = false

    private let panel = Color(red: 0.08, green: 0.10, blue: 0.13)
    private let accent = Color(red: 0.37, green: 0.47, blue: 0.58)

    var body: some View {
        ZStack {
            Map(position: $camera, interactionModes: [])
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.3), .clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer(minLength: 24)
                connectionPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
        }
        .background(.black)
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(viewModel)
        }
        .task {
            await viewModel.refreshServers()
            moveCamera()
        }
        .onChange(of: viewModel.selectedServer) { _, _ in moveCamera() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("DarkTunnel").font(.headline.bold())
                    Text(subscriptionStatus).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(panel.opacity(0.92), in: Circle())
                }
            }

            HStack(spacing: 8) {
                metric(icon: "calendar", title: daysRemaining, subtitle: "до окончания")
                metric(icon: "server.rack", title: "\(viewModel.servers.count)", subtitle: "доступно серверов")
            }

            Button {
                Task { await viewModel.refreshServers() }
            } label: {
                HStack(spacing: 7) {
                    if viewModel.isRefreshingServers { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(viewModel.isRefreshingServers ? "Обновляем…" : "Обновить данные")
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
    }

    private var connectionPanel: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: viewModel.state == .connected ? "checkmark.shield.fill" : "shield")
                        Text(viewModel.state.title).font(.headline.weight(.semibold))
                    }
                    Text(viewModel.serverDisplayName).font(.title2.bold())
                    Text(viewModel.statusDetail)
                        .font(.caption)
                        .foregroundStyle(viewModel.connectionError == nil ? .secondary : .red)
                        .lineLimit(3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(viewModel.selectedServerHost).font(.caption.weight(.semibold))
                    Text(viewModel.activeTransport.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 7) {
                Text("ССЫЛКА НА VK-ЗВОНОК")
                    .font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Image(systemName: "link").foregroundStyle(accent)
                    TextField("https://vk.ru/call/join/...", text: $viewModel.vkCallLink)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    if !viewModel.vkCallLink.isEmpty {
                        Button { viewModel.vkCallLink = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            }

            Button(action: viewModel.toggleConnection) {
                HStack(spacing: 9) {
                    if viewModel.state == .connecting || viewModel.state == .reconnecting { ProgressView().tint(.black) }
                    else { Image(systemName: viewModel.state == .connected ? "power" : "bolt.shield.fill") }
                    Text(viewModel.state.buttonTitle)
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.servers.isEmpty || viewModel.isRefreshingServers)
        }
        .padding(16)
        .background(panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 28))
    }

    private func metric(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var subscriptionStatus: String {
        ActivationStore.shared.isActivated ? "Подписка активна" : "Требуется активация"
    }

    private var daysRemaining: String {
        guard let expiry = ActivationStore.shared.subscriptionExpiresAt else { return "—" }
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0)
        return "\(days) дн."
    }

    private func moveCamera() {
        guard !viewModel.servers.isEmpty else { return }
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: viewModel.selectedServer.latitude, longitude: viewModel.selectedServer.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.34, longitudeDelta: 0.34)
        ))
    }
}
