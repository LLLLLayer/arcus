import SwiftUI

/// Google Gemini 云端修复设置（可选）。不开启/不填 Key 时，「补全这一视角」走端侧 LaMa/MI-GAN（离线）。
struct GeminiSettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $model.geminiEnabled) {
                            Label("Enable Gemini Cloud Repair", systemImage: "cloud.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.title)
                        }
                        .tint(Theme.accentC)

                        Divider().overlay(Theme.hairline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Google API Key").font(.caption.weight(.semibold)).foregroundStyle(Theme.body)
                            SecureField("Paste your Gemini API Key", text: $model.geminiKey)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($keyFocused)
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                                .foregroundStyle(Theme.title)
                            Text("The key is stored only on this device (UserDefaults), and only the current frame is uploaded when you tap “Complete This View.”")
                                .font(.caption2).foregroundStyle(Theme.faint)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model").font(.caption.weight(.semibold)).foregroundStyle(Theme.body)
                            TextField(GeminiRepair.defaultModel, text: $model.geminiModel)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                                .foregroundStyle(Theme.title)
                        }

                        Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                            Label("How to get an API Key?", systemImage: "arrow.up.right.square")
                                .font(.caption.weight(.medium)).foregroundStyle(Theme.accentB)
                        }
                    }
                    .padding(16)
                    .glassCard(radius: 18)

                    Label("Offline first: it works without a key — “Complete This View” uses on-device LaMa/MI-GAN, so your photo never leaves the device.",
                          systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(Theme.sub)
                        .padding(.horizontal, 4)

                    Spacer(minLength: 12)
                }
                .padding(20)
            }
            .background(Theme.ink.ignoresSafeArea())
            .navigationTitle("Cloud Repair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.warmGradient)
                    .frame(width: 48, height: 48)
                Image(systemName: "wand.and.stars").font(.title3.weight(.semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("View Repair").font(.headline).foregroundStyle(Theme.title)
                Text("Turn the reveals, stretches, and tears from a new angle into a clean finished photo").font(.caption2).foregroundStyle(Theme.faint)
            }
            Spacer()
        }
    }
}
