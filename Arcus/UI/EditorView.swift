import SwiftUI
import PhotosUI
import UIKit

private enum ReframeStage { case preview, generating, result }

struct EditorView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?
    @State private var reframe = false        // 「重拍」入口：复刻 Apple Spatial Reframing 的换机位交互（关 ⇒ 普通查看不变）
    @State private var reframeStage: ReframeStage = .preview
    @State private var reframeResult: UIImage?
    @StateObject private var reframeController = ReframeController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ParallaxMetalView(scene: model.scene,
                              params: reframe ? reframeParams : model.params,
                              controller: reframeController)
                .ignoresSafeArea()

            if reframe {
                if reframeStage == .preview { reframeEdges }              // 虚化只在「预览」态：露出的边缘先磨砂占位
                if reframeStage == .result, let img = reframeResult {
                    Image(uiImage: img).resizable().scaledToFit()   // 按原图比例完整展示补全成片(letterbox)，所见即所存
                        .transition(.opacity)
                }
                reframeChrome
                if reframeStage == .generating { generatingOverlay }
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    hintBar
                    ControlsView(model: model, pickerItem: $pickerItem)
                }
            }

            if model.isExporting {
                exportingOverlay
            }
        }
        .animation(.easeInOut(duration: 0.25), value: reframe)
        .animation(.easeInOut(duration: 0.2), value: reframeStage)
    }

    // MARK: - 「重拍」（Spatial Reframe 轻量复刻）

    /// 重拍参数：在普通 scene 上换一套观感——大幅移机位、不回弹、关陀螺、主体多放一点盖住更宽的去遮挡带。
    private var reframeParams: ViewerParams {
        var p = model.params
        p.reframeMode = true
        p.motionEnabled = false
        p.autoAnimate = false
        p.debugMode = 0
        p.parallaxAmp = 0.45                     // 普通查看是 0.02–0.13；这里放大成「换机位」幅度（移动范围更大）
        p.bgParallaxFactor = 0.5                 // 背景跟随更多 ⇒ 背景活动范围更大（之前 0.2 偏小）
        p.fgScale = max(p.fgScale, 1.1)
        p.multiLayerBg = false                   // 重拍只用单背景层 ⇒ 「补全主体背后」的洞掩膜干净（仅 bg+fg）
        p.fitImage = true                        // 与普通查看一致的取景(原图比例+overscan) ⇒ 进入重拍不跳帧；移动/缩放才露边
        return p
    }

    private var reframeChrome: some View {
        VStack {
            HStack {
                Button { reframe = false } label: {
                    Image(systemName: "xmark")
                        .font(.headline).foregroundStyle(.white)
                        .padding(12).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text(reframeStage == .result ? "重拍 · 已补全" : "重拍 · 换个机位")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            Spacer()

            switch reframeStage {
            case .preview:
                VStack(spacing: 12) {
                    Text("单指拖动改变视角 · 双指缩放 · 双击复位")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button { generateReframe() } label: {
                        Label("补全这一视角", systemImage: "sparkles")
                            .font(.headline).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 14)
                            .background(LinearGradient(colors: [.blue, .purple],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                }
                .padding(.bottom, 18)
            case .generating:
                Color.clear.frame(height: 1)
            case .result:
                HStack(spacing: 12) {
                    Button { reframeStage = .preview; reframeResult = nil } label: {
                        Label("重新调整", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 13)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Button { saveReframeResult() } label: {
                        Label("保存到相册", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 13)
                            .background(LinearGradient(colors: [.blue, .cyan],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    /// 虚化：把「移动后露出画框的边缘」磨砂占位（补全前还不是真内容）。仅预览态显示。
    private var reframeEdges: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(RadialGradient(colors: [.clear, .clear, .white.opacity(0.95)],
                                 center: .center, startRadius: 150, endRadius: 560))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var generatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text("补全露出的区域…").font(.headline).foregroundStyle(.white)
            }
            .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - 「补全这一视角」：当前机位 → 静帧（露出区=哨兵洞）→ LaMa 外扩补全 → 出图

    private func generateReframe() {
        reframeStage = .generating
        let controller = reframeController
        Task {
            guard let shot = await MainActor.run(body: { controller.snapshot() }) else {
                await MainActor.run { reframeStage = .preview }   // 取不到帧 → 退回预览
                return
            }
            let rgb = shot.rgb, hole = shot.hole
            let img: UIImage? = await Task.detached(priority: .userInitiated) {
                let filled = LamaInpainter().inpaint(rgb: rgb, hole: hole)   // LaMa 的 FFC 擅长外扩
                    ?? MiganInpainter().inpaint(rgb: rgb, hole: hole)
                    ?? rgb
                return filled.toCGImage().map { UIImage(cgImage: $0) }
            }.value
            await MainActor.run {
                reframeResult = img
                reframeStage = .result
            }
        }
    }

    private func saveReframeResult() {
        guard let img = reframeResult else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        model.toast = "已保存到相册"
    }

    private var topBar: some View {
        HStack {
            Button {
                model.reset()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if !model.sourceInfo.isEmpty {
                Text(model.sourceInfo)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Button { reframe = true; reframeStage = .preview; reframeResult = nil } label: {
                Image(systemName: "perspective")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var hintBar: some View {
        Text("倾斜手机 · 拖动画面 · 双击复位")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 10)
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text(model.exportMessage)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(30)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
