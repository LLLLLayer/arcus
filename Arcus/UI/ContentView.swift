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

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 26) {
                hero.padding(.top, 56)

                if !model.galleryItems.isEmpty { recentStrip }

                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Rendering Mode", "Choose how to turn your photo into 3D")
                    ForEach(AppModel.SceneMode.allCases) { mode in
                        SelectableCard(icon: icon(mode), title: mode.title, subtitle: mode.detail,
                                       selected: model.sceneMode == mode) {
                            withAnimation(.easeInOut(duration: 0.2)) { model.sceneMode = mode }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Background Fill", "Fill in the background hidden behind the subject (used by both modes)")
                    Picker("Background Fill", selection: $model.fillMode) {
                        ForEach(FillMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.fillMode.detail).font(.caption2).foregroundStyle(Theme.faint)
                }
                .padding(14)
                .glassCard(radius: 18)

                VStack(spacing: 12) {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(RainbowRingButtonStyle())

                    Button { model.processSample() } label: {
                        Label("Use Sample Image", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if !model.depthModelAvailable {
                    Label("No Core ML depth model detected; falling back to pseudo-depth. Run scripts/download_models.sh for the best results.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.yellow.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .auroraBackground()
        .onAppear { model.refreshGallery() }
        .sheet(isPresented: $showGallery) { ArcusGalleryView(model: model) }
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Recent", "Tap to open · long-press to delete")
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

    private var hero: some View {
        VStack(spacing: 18) {
            heroCard.frame(height: 168)
            Text("Arcus")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Theme.title, Theme.accentB],
                                                startPoint: .top, endPoint: .bottom))
            Text("Turn a photo into an interactive 3D photo\nOn-device · Offline · Zero-dependency")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(Theme.sub)
        }
    }

    /// 立体「照片长出深度」主视觉：错位的极光卡片 + 柔光 + 彩虹弧（Arcus=彩虹），呼应空间照片质感。
    private var heroCard: some View {
        ZStack {
            Circle().fill(Theme.accentGradient).frame(width: 150, height: 150)
                .blur(radius: 46).opacity(0.40)
            // 后层卡片：景深/视差提示
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentB.opacity(0.55), Theme.accentA.opacity(0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 96, height: 128)
                .rotation3DEffect(.degrees(22), axis: (x: 0, y: 1, z: 0))
                .offset(x: 30, y: -4).opacity(0.5).blur(radius: 0.5)
            // 前层卡片：极光主体 + 彩虹弧
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentC, Theme.accentA, Theme.accentB],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 102, height: 134)
                .overlay(
                    Circle()
                        .trim(from: 0.05, to: 0.45)
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 150, height: 150)
                        .blur(radius: 0.4)
                        .rotationEffect(.degrees(-20))
                        .offset(y: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                .rotation3DEffect(.degrees(-16), axis: (x: 0, y: 1, z: 0))
                .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 14)
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
