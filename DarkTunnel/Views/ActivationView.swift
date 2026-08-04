import SwiftUI

struct ActivationView: View {
    @AppStorage("subscriptionLink") private var subscriptionLink = ""
    @AppStorage("hasCompletedActivation") private var hasCompletedActivation = false
    @State private var isChecking = false
    @State private var errorMessage: String?

    private let blueGray = Color(red: 0.37, green: 0.47, blue: 0.58)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.06, green: 0.08, blue: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(blueGray.opacity(0.16))
                        .frame(width: 104, height: 104)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(blueGray)
                }

                VStack(spacing: 9) {
                    Text("Добро пожаловать")
                        .font(.largeTitle.bold())
                    Text("Вставьте ссылку доступа, которую вы получили после оформления подписки. Она сохранится только на этом iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("ССЫЛКА ДОСТУПА")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(blueGray)
                        TextField("https://…", text: $subscriptionLink)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .lineLimit(1)
                        if !subscriptionLink.isEmpty {
                            Button { subscriptionLink = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Button(action: activate) {
                    HStack(spacing: 9) {
                        if isChecking {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                        }
                        Text(isChecking ? "Проверяем доступ…" : "Продолжить")
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isChecking)

                Text("На текущем этапе проверка демонстрационная. Позже здесь будет настоящая проверка подписки на сервере.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .preferredColorScheme(.dark)
    }

    private func activate() {
        let trimmed = subscriptionLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "Вставьте корректную ссылку доступа."
            return
        }

        errorMessage = nil
        isChecking = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            subscriptionLink = trimmed
            hasCompletedActivation = true
            isChecking = false
        }
    }
}
