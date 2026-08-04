import SwiftUI
import MapKit

struct HomeView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @AppStorage("vkCallLink") private var vkCallLink = ""
    @State private var camera: MapCameraPosition = .region(Self.moscowRegion)
    @State private var showingSettings = false
    @State private var isRefreshingSubscription = false
    @State private var lastRefreshText = "обновлено сейчас"

    private let blueGray = Color(red: 0.37, green: 0.47, blue: 0.58)
    private let panel = Color(red: 0.08, green: 0.10, blue: 0.13)

    private static let moscowRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
        span: MKCoordinateSpan(latitudeDelta: 0.34, longitudeDelta: 0.34)
    )

    var body: some View {
        ZStack {
            mapBackground

            VStack(spacing: 0) {
                subscriptionHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer(minLength: 24)

                bottomPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(viewModel)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
        .onAppear(perform: moveCamera)
        .onChange(of: viewModel.state) { _, _ in moveCamera() }
        .onChange(of: viewModel.selectedServer) { _, _ in moveCamera() }
    }

    private var mapBackground: some View {
        ZStack {
            Map(position: $camera, interactionModes: [])
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.30), .clear, .black.opacity(0.84)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var subscriptionHeader: some View {
        VStack(spacing: 10) {
            subscriptionTitleRow

            HStack(spacing: 8) {
                metricPill(icon: "calendar", title: "29 дней", subtitle: "до окончания")
                metricPill(icon: "arrow.up.arrow.down", title: "8.2 / 30 ГБ", subtitle: "использовано")
            }

            refreshButton
        }
        .padding(14)
        .background(panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var subscriptionTitleRow: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(blueGray.opacity(0.18))
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(blueGray)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("DarkTunnel")
                    .font(.headline.weight(.bold))
                Text("Подписка активна · \(lastRefreshText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(panel.opacity(0.92), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var refreshButton: some View {
        Button(action: refreshSubscription) {
            HStack(spacing: 7) {
                if isRefreshingSubscription {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                }

                Text(isRefreshingSubscription ? "Обновляем данные…" : "Обновить подписку")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(blueGray.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshingSubscription)
    }

    private func metricPill(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(blueGray)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            connectionStatusRow
            Divider().overlay(.white.opacity(0.08))
            vkLinkField
            connectButton
        }
        .padding(16)
        .background(panel.opacity(0.90), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var connectionStatusRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(viewModel.state.title)
                        .font(.headline.weight(.semibold))
                }

                Text(connectionCity)
                    .font(.title2.weight(.bold))

                Text(viewModel.statusDetail)
                    .font(.caption)
                    .foregroundStyle(statusDetailColor)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(viewModel.serverDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(viewModel.activeTransport.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var vkLinkField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ССЫЛКА НА VK-ЗВОНОК")
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(.secondary)

            HStack(spacing: 9) {
                Image(systemName: "link")
                    .foregroundStyle(blueGray)

                TextField("https://vk.me/call/join/...", text: $vkCallLink)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .lineLimit(1)

                if !vkCallLink.isEmpty {
                    Button { vkCallLink = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var connectButton: some View {
        Button(action: viewModel.toggleConnection) {
            HStack(spacing: 9) {
                if isChangingConnection {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: connectionButtonIcon)
                }

                Text(viewModel.state.buttonTitle)
            }
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var isChangingConnection: Bool {
        viewModel.state == .connecting || viewModel.state == .reconnecting
    }

    private var statusIcon: String {
        viewModel.state == .connected ? "checkmark.shield.fill" : "shield"
    }

    private var connectionButtonIcon: String {
        viewModel.state == .connected ? "power" : "bolt.shield.fill"
    }

    private var connectionCity: String {
        viewModel.state == .connected ? viewModel.selectedServer.city : "Москва"
    }

    private var statusDetailColor: Color {
        viewModel.connectionError == nil ? .secondary : .red
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .connected: return blueGray
        case .connecting, .reconnecting: return .white
        case .disconnected: return .secondary
        }
    }

    private func refreshSubscription() {
        guard !isRefreshingSubscription else { return }
        isRefreshingSubscription = true
        Task {
            try? await Task.sleep(for: .milliseconds(850))
            isRefreshingSubscription = false
            lastRefreshText = "обновлено только что"
        }
    }

    private func moveCamera() {
        let center = viewModel.state == .connected
            ? viewModel.selectedServer.coordinate
            : Self.moscowRegion.center

        withAnimation(.smooth(duration: 1.0)) {
            camera = .region(
                MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: 0.34, longitudeDelta: 0.34)
                )
            )
        }
    }
}
