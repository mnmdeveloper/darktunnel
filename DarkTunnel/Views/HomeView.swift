import MapKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var viewModel: VPNViewModel
    @StateObject private var announcements = AnnouncementFeed.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: MapCameraPosition = .automatic
    @State private var showingSettings = false

    private let panel = Color(red: 0.08, green: 0.10, blue: 0.13)
    private let accent = Color(red: 0.37, green: 0.47, blue: 0.58)

    var body: some View {
        ZStack {
            Map(position: $camera, interactionModes: [.pan, .zoom, .rotate])
                .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.28), .clear, .black.opacity(0.90)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                header.padding(.horizontal, 16).padding(.top, 8)
                if let announcement = announcements.home.first {
                    announcementCard(announcement).padding(.horizontal, 16).padding(.top, 8)
                }
                Spacer(minLength: 10)
                connectionPanel.padding(.horizontal, 16).padding(.bottom, 18)
            }
        }
        .background(.black)
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(viewModel) }
        .onAppear { refresh() }
        .onChange(of: viewModel.state) { _, _ in moveCamera(animated: true) }
        .onChange(of: viewModel.selectedServer) { _, _ in if viewModel.state == .connected { moveCamera(animated: true) } }
        .onChange(of: scenePhase) { _, phase in viewModel.handleScenePhase(phase) }
    }

    private func refresh() {
        moveCamera(animated: false)
        Task {
            await viewModel.refreshServers()
            viewModel.refreshConnectivity()
            await announcements.refresh()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18, weight: .bold)).foregroundStyle(accent).frame(width: 40, height: 40).background(accent.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("DarkTunnel").font(.headline.bold())
                    Text(ActivationStore.shared.isActivated ? "Подписка активна" : "Требуется активация").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSettings = true } label: { Image(systemName: "gearshape.fill").foregroundStyle(.white).frame(width: 38, height: 38).background(panel.opacity(0.92), in: Circle()) }
            }
            HStack(spacing: 8) {
                metric(icon: "calendar", title: daysRemaining, subtitle: "до окончания")
                metric(icon: "server.rack", title: "\(viewModel.servers.count)", subtitle: "серверов")
                Button { Task { await viewModel.refreshServers(); await announcements.refresh() } } label: {
                    Group { if viewModel.isRefreshingServers { ProgressView().tint(.white) } else { Image(systemName: "arrow.clockwise") } }.frame(width: 42, height: 42).background(accent.opacity(0.28), in: Circle())
                }.buttonStyle(.plain).disabled(viewModel.isRefreshingServers)
            }
        }
        .padding(14).background(panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
    }

    private var connectionPanel: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) { Image(systemName: viewModel.state == .connected ? "checkmark.shield.fill" : "shield"); Text(viewModel.state.title).font(.headline.weight(.semibold)) }
                    Text(viewModel.serverDisplayName).font(.title2.bold())
                    Text(viewModel.statusDetail).font(.caption).foregroundStyle(viewModel.connectionError == nil ? Color.secondary : Color.red).lineLimit(3)
                }
                Spacer()
                Text(viewModel.activeTransport.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                pill(icon: "location.fill", title: viewModel.selectedServer.flag, subtitle: viewModel.selectedServer.country.isEmpty ? "Сервер" : viewModel.selectedServer.country)
                pill(icon: "timer", title: viewModel.pingText, subtitle: viewModel.state == .connected ? "пинг · 7 сек" : "пинг сервера")
                pill(icon: "antenna.radiowaves.left.and.right", title: viewModel.networkName, subtitle: viewModel.activeTransport.rawValue)
            }
            Divider().overlay(.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 7) {
                Text("ССЫЛКА НА VK-ЗВОНОК").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Image(systemName: "link").foregroundStyle(accent)
                    TextField("https://vk.ru/call/join/...", text: $viewModel.vkCallLink).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    if !viewModel.vkCallLink.isEmpty { Button { viewModel.vkCallLink = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(.horizontal, 12).padding(.vertical, 11).background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            }
            Button(action: viewModel.toggleConnection) {
                HStack(spacing: 9) {
                    if viewModel.state == .connecting || viewModel.state == .reconnecting { ProgressView().tint(.black) } else { Image(systemName: viewModel.state == .connected ? "power" : "bolt.shield.fill") }
                    Text(viewModel.state.buttonTitle)
                }.font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 14).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain).disabled(viewModel.servers.isEmpty || viewModel.state == .connecting || viewModel.state == .reconnecting)
        }
        .padding(16).background(panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
    }

    private func announcementCard(_ announcement: DarkTunnelRemoteAnnouncement) -> some View {
        let color = announcement.accentColor
        return HStack(spacing: 9) {
            Image(systemName: "megaphone.fill").foregroundStyle(color).font(.caption.weight(.bold)).frame(width: 28, height: 28).background(color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(announcement.title).font(.caption.weight(.bold)).lineLimit(1)
                Text(announcement.body).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(color.opacity(0.65), lineWidth: 1.1) }
    }

    private func pill(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 7) { Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(accent); VStack(alignment: .leading, spacing: 1) { Text(title).font(.caption.weight(.semibold)).lineLimit(1); Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func metric(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) { Image(systemName: icon).foregroundStyle(accent).frame(width: 22); VStack(alignment: .leading, spacing: 1) { Text(title).font(.caption.weight(.semibold)); Text(subtitle).font(.caption2).foregroundStyle(.secondary) }; Spacer() }
            .padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var daysRemaining: String {
        guard let expiry = ActivationStore.shared.subscriptionExpiresAt else { return "—" }
        return "\(max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0)) дн."
    }

    private func moveCamera(animated: Bool) {
        let coordinate = viewModel.state == .connected ? CLLocationCoordinate2D(latitude: viewModel.selectedServer.latitude, longitude: viewModel.selectedServer.longitude) : CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173)
        let region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.90))
        if animated { withAnimation(.easeInOut(duration: 1.1)) { camera = .region(region) } } else { camera = .region(region) }
    }
}
