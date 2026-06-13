import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            switch model.stage {
            case .idle:
                IdleView(model: model, pickerItem: $pickerItem)
            case .processing:
                ProcessingView(model: model)
            case .editor:
                EditorView(model: model, pickerItem: $pickerItem)
            }

            if let toast = model.toast {
                ToastView(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.stage)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    model.processData(data)
                }
                pickerItem = nil   // 复位：PhotosPickerItem 按 asset 判等，不复位则重选同一张照片不触发 onChange
            }
        }
        .alert(AppText.Error.title, isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button(AppText.ok, role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.exportResult) { result in
            ExportResultView(model: model, result: result)
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.05, green: 0.055, blue: 0.06),
                                Color(red: 0.08, green: 0.11, blue: 0.12),
                                Color(red: 0.02, green: 0.025, blue: 0.03)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 首页

private struct IdleView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .padding(.top, 34)

                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title3.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppText.Home.choosePhoto)
                                .font(.headline)
                            Text(AppText.Home.subtitle)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(
                        LinearGradient(colors: [Color(red: 0.0, green: 0.48, blue: 0.72),
                                                Color(red: 0.55, green: 0.28, blue: 0.84)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                }

                fillModePanel

                HStack(spacing: 10) {
                    metric(AppText.Home.depth, "waveform.path.ecg")
                    metric(AppText.Home.subject, "person.crop.rectangle")
                    metric(AppText.Home.fill, "sparkles")
                    metric(AppText.Home.render, "display")
                }

                if !model.depthModelAvailable {
                    Label(AppText.Home.depthWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.footnote.weight(.semibold))
                Text(AppText.Home.eyebrow)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(AppText.Home.local)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            .foregroundStyle(.white.opacity(0.72))

            VStack(alignment: .leading, spacing: 8) {
                Text("Arcus")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(AppText.Home.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private var fillModePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppText.Home.fillTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(AppText.Home.fillSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
            }

            Picker(AppText.Home.fillTitle, selection: $model.fillMode) {
                ForEach(FillMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(model.fillMode.detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.56))
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func metric(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white.opacity(0.82))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String
    var body: some View {
        VStack {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 60)
            Spacer()
        }
    }
}

#Preview {
    ContentView()
}
