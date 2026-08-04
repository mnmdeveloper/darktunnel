import SwiftUI
import MapKit

struct HomeView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @AppStorage("vkCallLink") private var vkCallLink = ""
    @State private var camera: MapCameraPosition = .region(Self.moscowRegion)
    @State private var showingSettings = false

    private static let moscowRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
        span: MKCoordinateSpan(latitudeDelta: 0.34, longitudeDelta: 0.34)
    )

    var body: some View {
        ZStack {
            Map(position: $camera, interactionModes: [])
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.10), .black.opacity(0.34), .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    Spacer(minLength: 150)
                    statusCard
                    vkCard
                    controlsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .ignoresSafeArea(edges: .bottom)
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.cyan)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("DarkTunnel")
                    .font(.title3.weight(.bold))
                Text(viewModel.networkName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var statusCard: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.state.title.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(statusColor)

                    Text(viewModel.state == .connected ? viewModel.selectedServer.city : "Москва")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(viewModel.statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ZStack {
                    Circle().fill(.thinMaterial)
                    Circle()
                        .stroke(statusColor.opacity(0.8), lineWidth: 7)
                        .padding(6)
                    Image(systemName: viewModel.state == .connected ? "lock.fill" : "lock.open.fill")
                        .font(.title2.weight(.bold))
                }
                .frame(width: 82, height: 82)
            }

            Button(action: viewModel.toggleConnection) {
                HStack(spacing: 10) {
                    if viewModel.state == .connecting || viewModel.state == .reconnecting {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: viewModel.state == .connected ? "power" : "bolt.shield.fill")
                    }
                    Text(viewModel.state.buttonTitle)
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var vkCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ССЫЛКА НА VK-ЗВОНОК")
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.cyan)

                TextField("https://vk.me/call/join/...", text: $vkCallLink)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .lineLimit(1)

                if !vkCallLink.isEmpty {
                    Button {
                        vkCallLink = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 0) {
            row(icon: "globe", title: "Сервер", value: "\(viewModel.selectedServer.flag) \(viewModel.selectedServer.name) · в настройках")
            Divider().overlay(.white.opacity(0.1))
            row(icon: "point.3.connected.trianglepath.dotted", title: "Транспорт", value: viewModel.activeTransport.rawValue)
        }
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 15)
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .connected: return .mint
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .secondary
        }
    }

    private func moveCamera() {
        let center = viewModel.state == .connected ? viewModel.selectedServer.coordinate : Self.moscowRegion.center
        withAnimation(.smooth(duration: 1.0)) {
            camera = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.34, longitudeDelta: 0.34)))
        }
    }
}
