import SwiftUI
import PhotosUI
import UIKit

private enum ReframeStage { case preview, generating, result }

struct EditorView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?

    // LDI「重拍」
    @State private var reframe = false
    @State private var reframeStage: ReframeStage = .preview
    @State private var reframeResult: UIImage?
    @StateObject private var reframeController = ReframeController()

    // 高斯：快照桥 + 修复对比 + 设置
    @StateObject private var gaussianController = GaussianViewController()
    @State private var comparing = false
    @State private var showSettings = false
    @State private var coverFade: Double = 1   // 进入高斯查看时：清晰原图 → 溶解到 3D 渲染（Apple 式过场）

    private var isGaussian: Bool { model.isGaussian }   // 单一真源在 AppModel

    @ViewBuilder private var rendererHost: some View {
        if isGaussian {
            GaussianMetalView(scene: model.scene?.gaussianScene, params: model.params, controller: gaussianController)
        } else {
            ParallaxMetalView(scene: model.scene,
                              params: reframe ? reframeParams : model.params,
                              controller: reframeController)
        }
    }

    var body: some View {
        ZStack {
            if isGaussian { gaussianBackdrop } else { Color.black.ignoresSafeArea() }

            rendererHost.ignoresSafeArea()

            // 进入高斯查看：清晰原图淡出，溶解到 3D 渲染（Apple 式过场）。
            // 用 scaledToFit 与渲染器的 fit 取景对齐（按原比例、居中、留白露背景），过场不跳变。
            if isGaussian, coverFade > 0.01, let img = model.sourceImage {
                Image(uiImage: img).resizable().scaledToFit()
                    .blur(radius: CGFloat(1 - coverFade) * 18)   // 淡出同时逐渐雾化，柔和溶解进 3D，露出的遮挡区不生硬
                    .opacity(coverFade).allowsHitTesting(false).ignoresSafeArea()
            }

            // 倾斜炫彩 sheen：随机位移动的虹彩高光，模拟光照打在转动的 3D 物体上（Spatial Photo 质感）。
            if isGaussian, model.params.debugMode == 0, model.repairResult == nil, !model.repairing {
                gaussianSheen.opacity(1 - coverFade)
            }

            if !isGaussian && reframe {
                if reframeStage == .preview { reframeEdges }
                if reframeStage == .result, let img = reframeResult {
                    Image(uiImage: img).resizable().scaledToFit().transition(.opacity)
                }
                reframeChrome
                if reframeStage == .generating { generatingOverlay(String(localized: "Filling in the revealed areas…")) }
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if !isGaussian { hintBar }
                    ControlsView(model: model, pickerItem: $pickerItem,
                                 onOpenGeminiSettings: { showSettings = true },
                                 onRepair: { model.repairCurrentViewpoint(snapshot: { await gaussianController.snapshotAsync() }) })
                }
            }

            if model.repairing { generatingOverlay(model.repairMessage) }
            if isGaussian, let result = model.repairResult { repairResultOverlay(result) }
            if model.isExporting { exportingOverlay }
        }
        .animation(.easeInOut(duration: 0.25), value: reframe)
        .animation(.easeInOut(duration: 0.2), value: reframeStage)
        .animation(.easeInOut(duration: 0.25), value: model.repairResult != nil)
        .preferredColorScheme(.dark)   // 3D 沉浸查看态固定深色（对标 Apple 照片全屏的沉浸式媒体浏览）
        .sheet(isPresented: $showSettings) { GeminiSettingsSheet(model: model) }
        .onAppear {
            if isGaussian { withAnimation(.easeInOut(duration: 0.85).delay(0.25)) { coverFade = 0 } }
            // 冒烟钩子：AUTOREPAIR=1 在高斯模式下自动触发一次「补全这一视角」，便于无人值守截图验证修复链路。
            if ProcessInfo.processInfo.environment["AUTOREPAIR"] == "1", isGaussian {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    model.repairCurrentViewpoint(snapshot: { await gaussianController.snapshotAsync() })
                }
            }
        }
    }

    // MARK: - 倾斜炫彩 sheen（跟随机位的虹彩高光）

    @ViewBuilder private var gaussianSheen: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let tilt = gaussianController.currentTilt()
                let t = timeline.date.timeIntervalSinceReferenceDate
                let hue = (t.truncatingRemainder(dividingBy: 14) / 14)
                let mag = min(1.0, hypot(tilt.width, tilt.height))
                // 高光中心与机位反向移动（固定光源，物体在转）
                let ux = max(0.05, min(0.95, 0.5 - tilt.width * 0.32))
                let uy = max(0.05, min(0.95, 0.5 + tilt.height * 0.32))
                LinearGradient(colors: Theme.rainbowColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .hueRotation(.degrees(hue * 360))
                    .mask(
                        RadialGradient(colors: [.white.opacity(0.9), .clear],
                                       center: UnitPoint(x: ux, y: uy),
                                       startRadius: 0, endRadius: geo.size.width * 0.62)
                    )
                    .blendMode(.screen)
                    .opacity(0.05 + mag * 0.16)   // 静止极淡，倾斜越多越亮
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 高斯「虚拟云状」背景 + glow

    @ViewBuilder private var gaussianBackdrop: some View {
        // 关键：scaledToFill 的图理想尺寸超出屏宽(竖图≈639pt)。必须用 GeometryReader 给图一个**精确像素 frame**，
        // 否则它会撑大整个编辑器坐标系 ⇒ 控制坞左溢/文字裁切（已在真机 hierarchy 确认）。
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Theme.ink2, Theme.ink, .black], startPoint: .top, endPoint: .bottom)
                if let img = model.sourceImage {
                    // 柔雾背景：重高斯模糊 + 适度饱和（不过曝、不生硬），露出的遮挡区域呈梦幻雾状（对标 Reshot）。
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: w, height: h).clipped()
                        .blur(radius: 70).saturation(1.3).brightness(0.02).opacity(0.95)
                    // 柔白雾纱（softLight）：增加雾感、柔化边界，不抢主体。
                    LinearGradient(colors: [.white.opacity(0.10), .clear, .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom)
                        .blendMode(.softLight)
                    // 极淡虹彩流动（spatial 质感，克制，不再喧宾夺主）。
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let rot = (t.truncatingRemainder(dividingBy: 24) / 24) * 360
                        AngularGradient(colors: Theme.rainbowColors, center: .center)
                            .rotationEffect(.degrees(rot))
                            .frame(width: w, height: h)
                            .blur(radius: 96).opacity(0.12).blendMode(.overlay)
                    }
                    // 柔和暗角，把视线收向中央主体。
                    RadialGradient(colors: [.clear, .black.opacity(0.34)],
                                   center: .center, startRadius: w * 0.32, endRadius: w * 0.92)
                }
                Color.black.opacity(0.12)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
    }

    // MARK: - 修复结果（before / after）

    private func repairResultOverlay(_ result: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: comparing ? (model.sourceImage ?? result) : result)
                .resizable().scaledToFit().ignoresSafeArea()
                .transition(.opacity)

            VStack {
                HStack {
                    CircleIconButton(system: "xmark") { model.repairResult = nil; comparing = false }
                    Spacer()
                    PillLabel(text: comparing ? String(localized: "Original") : String(format: String(localized: "Completed (%@)"), model.canUseGemini ? "Gemini" : String(localized: "On-device")),
                              icon: comparing ? "photo" : "sparkles")
                    Spacer()
                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer()
                HStack(spacing: 12) {
                    Button { } label: { Label("Hold to Compare", systemImage: "rectangle.righthalf.inset.filled") }
                        .buttonStyle(GhostButtonStyle())
                        .simultaneousGesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in comparing = true }.onEnded { _ in comparing = false })
                    Button { model.saveRepairResult() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    // MARK: - 通用覆盖层

    private func generatingOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text(text).font(.headline).foregroundStyle(.white)
            }
            .padding(30).glassCard(radius: 22)
        }
    }

    private var topBar: some View {
        HStack {
            CircleIconButton(system: "chevron.left") { model.reset() }
            Spacer()
            if !model.sourceInfo.isEmpty { PillLabel(text: model.sourceInfo) }
            Spacer()
            if isGaussian {
                CircleIconButton(system: "slider.horizontal.3") { showSettings = true }
            } else {
                CircleIconButton(system: "perspective") { reframe = true; reframeStage = .preview; reframeResult = nil }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var hintBar: some View {
        PillLabel(text: String(localized: "Tilt or drag to look around, double-tap to reset"), icon: "hand.draw")
            .padding(.bottom, 10)
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text(model.exportMessage).font(.headline).foregroundStyle(.white)
                Button { model.cancelExport() } label: {
                    Text("Cancel").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.body)
                        .padding(.horizontal, 24).padding(.vertical, 9)
                        .background(.white.opacity(0.10), in: Capsule())
                }
            }
            .padding(30).glassCard(radius: 22)
        }
    }

    // MARK: - 「重拍」（LDI，保持原逻辑）

    private var reframeParams: ViewerParams {
        var p = model.params
        p.reframeMode = true
        p.motionEnabled = false
        p.autoAnimate = false
        p.debugMode = 0
        p.parallaxAmp = 0.45
        p.bgParallaxFactor = 0.5
        p.fgScale = max(p.fgScale, 1.1)
        p.multiLayerBg = false
        p.fitImage = true
        p.frameBars = false
        return p
    }

    private var reframeChrome: some View {
        VStack {
            HStack {
                CircleIconButton(system: "xmark") { reframe = false }
                Spacer()
                PillLabel(text: reframeStage == .result ? String(localized: "Reshoot complete") : String(localized: "Reshoot from a new angle"))
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            Spacer()
            switch reframeStage {
            case .preview:
                VStack(spacing: 12) {
                    PillLabel(text: String(localized: "Drag to look around, pinch to zoom, double-tap to reset"))
                    Button { generateReframe() } label: { Label("Complete This View", systemImage: "sparkles") }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 260)
                }
                .padding(.bottom, 20)
            case .generating:
                Color.clear.frame(height: 1)
            case .result:
                HStack(spacing: 12) {
                    Button { reframeStage = .preview; reframeResult = nil } label: {
                        Label("Adjust Again", systemImage: "arrow.uturn.backward")
                    }.buttonStyle(GhostButtonStyle())
                    Button { saveReframeResult() } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 20).padding(.bottom, 22)
            }
        }
    }

    private var reframeEdges: some View {
        Rectangle().fill(.ultraThinMaterial)
            .mask(RadialGradient(colors: [.clear, .clear, .white.opacity(0.95)],
                                 center: .center, startRadius: 150, endRadius: 560))
            .ignoresSafeArea().allowsHitTesting(false)
    }

    private func generateReframe() {
        reframeStage = .generating
        let controller = reframeController
        let useCloud = model.canUseGemini                     // 已配置 Gemini Key → 云端优先（与高斯模式一致）
        let gKey = model.geminiKey, gModel = model.geminiModel
        Task {
            guard let shot = await MainActor.run(body: { controller.snapshot() }) else {
                await MainActor.run { reframeStage = .preview }
                return
            }
            let rgb = shot.rgb, hole = shot.hole
            let pipeline = model.pipeline
            let img: UIImage? = await Task.detached(priority: .userInitiated) {
                // 云端优先：把渲染帧交给 Gemini 生成式修复；失败/未配置回退端侧 LaMa→MI-GAN（离线）。
                if useCloud, let rendered = rgb.toCGImage().map({ UIImage(cgImage: $0) }),
                   let repaired = try? await GeminiRepair.repair(image: rendered, key: gKey, model: gModel) {
                    return repaired
                }
                let filled = pipeline.reframeInpaint(rgb: rgb, hole: hole) ?? rgb
                return filled.toCGImage().map { UIImage(cgImage: $0) }
            }.value
            await MainActor.run { reframeResult = img; reframeStage = .result }
        }
    }

    private func saveReframeResult() {
        guard let img = reframeResult else { return }
        model.saveImageToPhotos(img, name: "Arcus-Reframe")   // 与视角修复共用存盘逻辑
    }
}
