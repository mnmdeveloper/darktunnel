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
                colors: [.black.opacity(0.08), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
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

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.cyan)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("DarkTunnel")
                    .font(.headline.weight(.bold))
                Text(viewModel.networkName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Text(viewModel.serverDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.secondary)

                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: viewModel.state == .connected ? "checkmark.shield.fill" : "shield")
                            .foregroundStyle(statusColor)
                        Text(viewModel.state.title)
                            .font(.headline.weight(.semibold))
                    }

                    Text(viewModel.state == .connected ? viewModel.selectedServer.city : "Москва")
                        .font(.title2.weight(.bold))

                    Text(viewModel.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

            Divider().overlay(.white.opacity(0.09))

            VStack(alignment: .leading, spacing: 7) {
                Text("ССЫЛКА НА VK-ЗВОНОК")
                    .font(.caption2.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)

                HStack(spacing: 9) {
                    Image(systemName: "link")
                        .foregroundStyle(.cyan)

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
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button(action: viewModel.toggleConnection) {
                HStack(spacing: 9) {
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
                .padding(.vertical, 14)
                .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
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
