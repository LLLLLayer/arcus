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
        .onAppear {
            // 测试钩子：以 AUTOSAMPLE=1 启动时自动处理示例图，便于冒烟测试。
            let env = ProcessInfo.processInfo.environment
            if env["AUTOSAMPLE"] == "1", model.stage == .idle {
                if let dm = env["DEBUGMODE"], let v = Int32(dm) { model.params.debugMode = v }
                if env["AUTOANIM"] == "1" { model.params.autoAnimate = true }
                model.processSample()
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    model.processData(data)
                }
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.exportResult) { result in
            ExportResultView(model: model, result: result)
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12),
                                Color(red: 0.10, green: 0.08, blue: 0.18),
                                Color.black],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 首页

private struct IdleView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Arcus")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("把一张照片变成可交互的 3D 照片\n端侧 · 深度分层 · 背景补全")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            VStack(spacing: 14) {
                Toggle(isOn: $model.highQualityFill) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高质量背景补全").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text("PatchMatch 内容感知 · 更连贯，但处理较慢（约 1–3 分钟）")
                            .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .tint(.orange)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("选择照片", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }

                Button {
                    model.processSample()
                } label: {
                    Label("使用示例图", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 28)

            if !model.depthModelAvailable {
                Label("未检测到 Core ML 深度模型，将用伪深度兜底。运行 scripts/download_models.sh 获取最佳效果。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer().frame(height: 12)
        }
        .padding(.bottom, 24)
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
