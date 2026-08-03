import SwiftUI
import MapKit

struct HomeView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @State private var camera: MapCameraPosition = .region(Self.moscowRegion)
    @State private var showingSettings = false
    @State private var showingServers = false

    private static let moscowRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
    )

    var body: some View {
        ZStack {
            Map(position: $camera, interactionModes: []) {
                if viewModel.state == .connected {
                    Marker(viewModel.selectedServer.city, coordinate: viewModel.selectedServer.coordinate)
                        .tint(.cyan)
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .ignoresSafeArea()
            .overlay {
                LinearGradient(
                    colors: [
                        .black.opacity(0.22),
                        .black.opacity(0.15),
                        .black.opacity(0.58),
                        .black.opacity(0.9)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 14) {
                topBar

                if viewModel.showsAnnouncement {
                    AnnouncementBanner(
                        title: "DarkTunnel запускается",
                        message: "Первый интерфейс уже готов. Подключение пока работает в демонстрационном режиме.",
                        onClose: viewModel.dismissAnnouncement
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                connectionCard
                quickControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(viewModel)
        }
        .confirmationDialog("Сервер", isPresented: $showingServers, titleVisibility: .visible) {
            ForEach(viewModel.servers) { server in
                Button("\(server.flag) \(server.name) · \(server.latencyMilliseconds) мс") {
                    viewModel.select(server)
                }
            }
        }
        .onAppear(perform: moveCamera)
        .onChange(of: viewModel.state) { _, _ in moveCamera() }
        .onChange(of: viewModel.selectedServer) { _, _ in moveCamera() }
    }

    private var topBar: some View {
        GlassCard(cornerRadius: 22) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.cyan.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.cyan)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("DarkTunnel")
                        .font(.headline)
                    Text(viewModel.networkName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewModel.state.title.uppercased())
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(statusColor)

                        Text(viewModel.state == .connected ? viewModel.selectedServer.city : "Москва")
                            .font(.system(size: 32, weight: .bold, design: .rounded))

                        Text(viewModel.statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.1), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: viewModel.state == .connected ? 1 : 0.22)
                            .stroke(statusColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.55), value: viewModel.state)
                        Image(systemName: viewModel.state == .connected ? "lock.fill" : "lock.open.fill")
                            .font(.title3.weight(.bold))
                    }
                    .frame(width: 70, height: 70)
                }

                Button(action: viewModel.toggleConnection) {
                    HStack(spacing: 10) {
                        if viewModel.state == .connecting || viewModel.state == .reconnecting {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Image(systemName: viewModel.state == .connected ? "power" : "bolt.shield.fill")
                        }
                        Text(viewModel.state.buttonTitle)
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var quickControls: some View {
        GlassCard(cornerRadius: 24) {
            VStack(spacing: 12) {
                Button {
                    showingServers = true
                } label: {
                    controlRow(
                        icon: "globe.europe.africa.fill",
                        title: "Сервер",
                        value: "\(viewModel.selectedServer.flag) \(viewModel.selectedServer.name)"
                    )
                }

                Divider().overlay(.white.opacity(0.12))

                controlRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Транспорт",
                    value: viewModel.activeTransport.rawValue
                )

                Divider().overlay(.white.opacity(0.12))

                controlRow(
                    icon: "speedometer",
                    title: "Скорость",
                    value: "\(viewModel.speedMode.rawValue) соединения"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func controlRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            if title == "Сервер" {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .connected: .mint
        case .connecting, .reconnecting: .yellow
        case .disconnected: .secondary
        }
    }

    private func moveCamera() {
        let region: MKCoordinateRegion
        if viewModel.state == .connected {
            region = MKCoordinateRegion(
                center: viewModel.selectedServer.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.28, longitudeDelta: 0.28)
            )
        } else {
            region = Self.moscowRegion
        }

        withAnimation(.smooth(duration: 1.15)) {
            camera = .region(region)
        }
    }
}
