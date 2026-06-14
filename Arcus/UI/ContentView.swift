import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
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
                    .id(toast)   // 每条 toast 独立身份 ⇒ .task 重启计时器，连续 toast 不会被上一条的计时提前清掉
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.32), value: model.stage)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["AUTOSAMPLE"] == "1", model.stage == .idle {
                if let dm = env["DEBUGMODE"], let v = Int32(dm) { model.params.debugMode = v }
                if env["AUTOANIM"] == "1" { model.params.autoAnimate = true }
                switch env["FILLMODE"] {
                case "migan": model.fillMode = .migan
                case "patchMatch": model.fillMode = .patchMatch
                case "fast": model.fillMode = .fast
                case "cloud": model.fillMode = .cloud
                default: break
                }
                switch env["SCENEMODE"] {
                case "gaussian", "gaussianSplat": model.sceneMode = .gaussianSplat
                case "ldi", "layeredLDI": model.sceneMode = .layeredLDI
                default: break
                }
                model.processSample()
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    model.processData(data)
                }
                pickerItem = nil
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.exportResult) { result in
            ExportResultView(model: model, result: result)
        }
    }
}

// MARK: - 首页

private struct IdleView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?
    @State private var showGallery = false
    @State private var showGeminiSettings = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                // 相机置顶（camera-first）：打开即取景，快门拍照直接进入 3D；下滑才是选照片等。
                CameraHomeCard(model: model).padding(.top, 6)
                captionRow

                if !model.galleryItems.isEmpty { recentStrip }

                librarySection

                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Rendering Mode", "Pick how your photo comes to life")
                    ForEach(AppModel.SceneMode.allCases) { mode in
                        SelectableCard(icon: icon(mode), title: mode.title, subtitle: mode.detail,
                                       selected: model.sceneMode == mode) {
                            withAnimation(.easeInOut(duration: 0.2)) { model.sceneMode = mode }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Background Fill", "Rebuild what's hidden behind your subject")
                    Picker("Background Fill", selection: $model.fillMode) {
                        ForEach(FillMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.fillMode.detail).font(.caption2).foregroundStyle(Theme.faint)

                    // Cloud 模式：提供 Gemini Key 入口（未配置则回退端侧，默认仍离线）。
                    if model.fillMode == .cloud {
                        Button { showGeminiSettings = true } label: {
                            Label(model.canUseGemini ? "Google API connected" : "Set up Google API key",
                                  systemImage: model.canUseGemini ? "checkmark.seal.fill" : "key.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(model.canUseGemini ? Theme.accentB : Theme.accentC)
                        }
                        .buttonStyle(.plain)
                        if !model.canUseGemini {
                            Text("Without a key, Cloud falls back to on-device fill.")
                                .font(.caption2).foregroundStyle(Theme.faint)
                        }
                    }
                }
                .padding(14)
                .glassCard(radius: 18)

                if !model.depthModelAvailable {
                    Label("No Core ML depth model detected; falling back to pseudo-depth. Run scripts/download_models.sh for the best results.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.yellow.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .auroraBackground()
        .onAppear { model.refreshGallery() }
        .sheet(isPresented: $showGallery) { ArcusGalleryView(model: model) }
        .sheet(isPresented: $showGeminiSettings) { GeminiSettingsSheet(model: model) }
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Recent", "Tap to revisit, hold to delete")
                Spacer()
                Button { showGallery = true } label: {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accentB)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.galleryItems.prefix(10)) { item in
                        RecentThumb(item: item)
                            .onTapGesture { model.openLibraryItem(item) }
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation { model.deleteLibraryItem(item) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 相机下方的品牌小标 + 引导：七彩光圈 logo + 彩虹字标，呼应 App 图标。
    private var captionRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                BladeIris(progress: 0.2)
                    .frame(width: 30, height: 30)
                Text("Arcus")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: Theme.rainbowColors,
                                                    startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            }
            Text("Shoot to create an interactive 3D photo")
                .font(.caption).foregroundStyle(Theme.sub)
        }
        .padding(.top, 2)
    }

    /// 「从相册」：选照片 + 用示例图（相机之外的次要入口，置于下方）。
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("From Your Library", "Bring any photo to life in 3D")
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose Photo", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(GhostButtonStyle())
            Button { model.processSample() } label: {
                Label("Use Sample Image", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func sectionLabel(_ title: LocalizedStringKey, _ sub: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.title)
            Text(sub).font(.caption2).foregroundStyle(Theme.faint)
        }
    }

    private func icon(_ mode: AppModel.SceneMode) -> String {
        switch mode {
        case .layeredLDI: return "square.3.layers.3d"
        case .gaussianSplat: return "cube.transparent"
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String
    var body: some View {
        VStack {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.title)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 60)
            Spacer()
        }
    }
}

/// 首页「最近作品」横向小缩略图。
private struct RecentThumb: View {
    let item: LibraryItem
    @State private var thumb: UIImage?
    private var isGaussian: Bool { item.sceneMode == "gaussianSplat" }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.surface)
                }
            }
            .frame(width: 82, height: 104)
            .clipped()
            Image(systemName: isGaussian ? "cube.transparent" : "square.3.layers.3d")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.35), in: Circle())
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
        .task(id: item.id) {
            if thumb == nil {
                let url = item.thumbURL
                thumb = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
        }
    }
}

#Preview {
    ContentView()
}
