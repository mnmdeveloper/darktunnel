import Foundation
import SwiftUI

struct AppLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let level: String
    let category: String
    let message: String
}

@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var entries: [AppLogEntry] = []
    private let storageKey = "darktunnel.app.logs.v1"
    private let maximumEntries = 400

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AppLogEntry].self, from: data) {
            entries = decoded
        }
    }

    func info(_ category: String, _ message: String) { append(level: "INFO", category: category, message: message) }
    func warning(_ category: String, _ message: String) { append(level: "WARN", category: category, message: message) }
    func error(_ category: String, _ message: String) { append(level: "ERROR", category: category, message: message) }

    func clear() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    var exportText: String {
        let formatter = ISO8601DateFormatter()
        return entries.map { "[\(formatter.string(from: $0.date))] [\($0.level)] [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }

    private func append(level: String, category: String, message: String) {
        let sanitized = message
            .replacingOccurrences(of: #"darktunnel://activate\?d=[^\s]+"#, with: "darktunnel://activate?d=<hidden>", options: .regularExpression)
            .replacingOccurrences(of: #"wrap_a_password[^,}\n]*"#, with: "wrap_a_password=<hidden>", options: .regularExpression)
        entries.append(AppLogEntry(id: UUID(), date: Date(), level: level, category: category, message: sanitized))
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}

struct LogsView: View {
    @StateObject private var log = AppLog.shared

    var body: some View {
        List {
            if log.entries.isEmpty {
                ContentUnavailableView("Логов пока нет", systemImage: "doc.text.magnifyingglass", description: Text("Здесь появятся события активации и VPN-подключения"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.level).font(.caption2.bold()).foregroundStyle(entry.level == "ERROR" ? .red : (entry.level == "WARN" ? .orange : .secondary))
                            Text(entry.category).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.date, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        Text(entry.message).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Логи")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.exportText) { Image(systemName: "square.and.arrow.up") }
                    .disabled(log.entries.isEmpty)
                Button(role: .destructive) { log.clear() } label: { Image(systemName: "trash") }
                    .disabled(log.entries.isEmpty)
            }
        }
        .preferredColorScheme(.dark)
    }
}
