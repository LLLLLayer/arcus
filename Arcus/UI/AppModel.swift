import SwiftUI
import AVFoundation
import Foundation

enum AppText {
    private static var zh: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    static func text(_ zhText: String, _ enText: String) -> String {
        zh ? zhText : enText
    }

    static let ok = text("好", "OK")
    static let cancel = text("取消", "Cancel")
    static let done = text("完成", "Done")
    static let saveToPhotos = text("保存到相册", "Save to Photos")

    enum Home {
        static let eyebrow = text("端侧 2D 转 3D 照片", "On-device 2D to 3D photos")
        static let title = text("空间照片工作台", "Spatial Photo Studio")
        static let subtitle = text("选择一张照片，生成可交互的深度分层资产。", "Choose a photo and build an interactive layered-depth scene.")
        static let choosePhoto = text("选择照片", "Choose Photo")
        static let fillTitle = text("背景补全", "Background Fill")
        static let fillSubtitle = text("决定主体移开后，背后缺失区域如何生成。", "Controls how missing regions behind the subject are filled.")
        static let depthWarning = text(
            "未检测到 Core ML 深度模型，将用伪深度兜底。运行 scripts/download_models.sh 获取最佳效果。",
            "Core ML depth model not found. Arcus will fall back to pseudo depth. Run scripts/download_models.sh for best results."
        )
        static let depth = text("深度", "Depth")
        static let subject = text("主体", "Subject")
        static let fill = text("补全", "Fill")
        static let render = text("渲染", "Render")
        static let local = text("本地", "Local")
    }

    enum Error {
        static let title = text("出错了", "Something went wrong")
        static let unreadableImage = text("无法读取所选图片。", "Could not read the selected image.")
        static func processingFailed(_ message: String) -> String {
            text("处理失败：\(message)", "Processing failed: \(message)")
        }
        static func exportVideoFailed(_ message: String) -> String {
            text("导出视频失败：\(message)", "Video export failed: \(message)")
        }
        static func exportSpatialFailed(_ message: String) -> String {
            text("导出空间照片失败：\(message)", "Spatial photo export failed: \(message)")
        }
        static func saveFailed(_ message: String) -> String {
            text("保存到相册失败：\(message)", "Save to Photos failed: \(message)")
        }
    }

    enum Processing {
        static let preparing = text("准备…", "Preparing...")
        static let cancelling = text("正在取消…", "Cancelling...")
        static let summary = text("端侧处理中 · 深度 → 分割 → 背景补全 → 烘焙", "On-device · depth → segmentation → fill → bake")
        static let preprocess = text("预处理图像…", "Preprocessing image...")
        static let depth = text("估计深度…", "Estimating depth...")
        static let segment = text("分割主体…", "Segmenting subject...")
        static let fillBackground = text("补全主体背后的背景…", "Filling background behind the subject...")
        static let miganFill = text("AI 补全背景（MI-GAN，端侧生成）…", "AI background fill with MI-GAN on device...")
        static let patchMatchFill = text("高质量补全背景（PatchMatch · 深度感知，较慢）…", "High-quality PatchMatch depth-aware fill...")
        static let baking = text("烘焙 3D 网格…", "Baking 3D mesh...")
        static let complete = text("完成", "Complete")
    }

    enum Editor {
        static let reframeReady = text("重拍 · 已补全", "Reframe · Filled")
        static let reframePreview = text("重拍 · 换个机位", "Reframe · Move Camera")
        static let reframeHint = text("单指拖动改变视角 · 双指缩放 · 双击复位", "Drag to move camera · Pinch to zoom · Double tap to reset")
        static let fillThisView = text("补全这一视角", "Fill This View")
        static let adjustAgain = text("重新调整", "Adjust Again")
        static let filling = text("补全露出的区域…", "Filling revealed regions...")
        static let viewerHint = text("倾斜手机 · 拖动画面 · 双击复位", "Tilt phone · Drag view · Double tap to reset")
    }

    enum Controls {
        static let title = text("3D 照片", "3D Photo")
        static let view = text("查看", "View")
        static let normal = text("正常", "Normal")
        static let depth = text("深度", "Depth")
        static let subject = text("主体", "Subject")
        static let background = text("背景", "Background")
        static let strength = text("3D 强度", "3D Strength")
        static let backgroundParallax = text("背景视差", "Background Parallax")
        static let foregroundScale = text("前景放大", "Foreground Scale")
        static let gyro = text("陀螺仪", "Gyro")
        static let autoRotate = text("自动旋转", "Auto Rotate")
        static let layeredBackground = text("背景分层", "Layered BG")
        static let framePopOut = text("出框", "Pop Out")
        static let exportVideo = text("导出视频", "Export Video")
        static let spatialPhoto = text("空间照片", "Spatial Photo")
    }

    enum Export {
        static let renderingVideo = text("正在渲染视差视频…", "Rendering parallax video...")
        static let renderingSpatial = text("正在渲染空间照片…", "Rendering spatial photo...")
        static let saved = text("已保存到相册", "Saved to Photos")
        static let shareFile = text("分享文件", "Share File")
        static let videoTitle = text("视差视频", "Parallax Video")
        static let spatialTitle = text("空间照片", "Spatial Photo")
        static let videoSubtitle = text("可保存到相册或分享。循环视差，适合社交分享。", "Save to Photos or share. Looped parallax works well for social posts.")
        static let spatialSubtitle = text("立体 HEIC，AirDrop 到 Apple Vision Pro 可作为空间照片查看。", "Stereo HEIC. AirDrop to Apple Vision Pro to view as a spatial photo.")
    }

    static func fillModeTitle(_ mode: FillMode) -> String {
        switch mode {
        case .fast: return text("快速", "Fast")
        case .patchMatch: return "PatchMatch"
        case .migan: return text("AI 补全", "AI Fill")
        }
    }

    static func fillModeDetail(_ mode: FillMode) -> String {
        switch mode {
        case .fast: return text("竖直延续 · 深度门控 · 实时", "Vertical propagation · depth gated · realtime")
        case .patchMatch: return text("内容感知 · 更连贯 · 较慢（约十几秒）", "Content-aware · more coherent · slower")
        case .migan: return text("MI-GAN 神经生成 · 端侧 · 处理较慢", "MI-GAN neural fill · on device · slower")
        }
    }

    static func sourceInfo(depth: String, subject: String, fill: String) -> String {
        text(
            "深度：\(source(depth)) · 主体：\(source(subject)) · 补全：\(source(fill))",
            "Depth: \(source(depth)) · Subject: \(source(subject)) · Fill: \(source(fill))"
        )
    }

    static func source(_ value: String) -> String {
        switch value {
        case "伪深度(兜底)": return text("伪深度(兜底)", "Pseudo depth fallback")
        case "前景主体实例": return text("前景主体实例", "Foreground instance")
        case "人物分割": return text("人物分割", "Person segmentation")
        case "深度阈值近似": return text("深度阈值近似", "Depth-threshold approximation")
        case "PatchMatch+depth(MI-GAN 不可用)": return text("PatchMatch+depth(MI-GAN 不可用)", "PatchMatch+depth (MI-GAN unavailable)")
        default: return value
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    enum Stage: Equatable { case idle, processing, editor }
    enum ExportKind { case video, spatial }
    struct ExportResult: Identifiable { let id = UUID(); let url: URL; let kind: ExportKind }

    @Published var stage: Stage = .idle
    @Published var progress: Double = 0
    @Published var progressMessage = ""
    @Published var scene: Photo3DScene?
    @Published var params = ViewerParams()
    @Published var fillMode: FillMode = .fast   // 启动页选择：快速 / PatchMatch / MI-GAN
    @Published var sourceInfo = ""
    @Published var errorMessage: String?

    @Published var isExporting = false
    @Published var exportMessage = ""
    @Published var exportResult: ExportResult?
    @Published var toast: String?

    let pipeline = Photo3DPipeline()
    private(set) lazy var depthModelAvailable: Bool = pipeline.isDepthModelAvailable

    private var processingTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    // MARK: - 处理入口

    func processData(_ data: Data) {
        // ImageIO 子采样解码：摆正 + 降采样一步完成，超大照片(48MP)不在原始分辨率整图落内存。
        let maxSide = Photo3DPipeline.Options().maxWorkingSide
        guard let img = ImageUtils.downsampledImage(from: data, maxSide: maxSide) ?? UIImage(data: data) else {
            errorMessage = AppText.Error.unreadableImage
            return
        }
        let av = AuxDepthLoader.avDepth(from: data)
        process(image: img, avDepth: av)
    }

    private func process(image: UIImage, avDepth: AVDepthData?) {
        stage = .processing
        progress = 0
        progressMessage = AppText.Processing.preparing
        errorMessage = nil
        let pipeline = self.pipeline
        let fm = self.fillMode
        processingTask = Task.detached(priority: .userInitiated) {
            do {
                let scene = try pipeline.process(image: image, avDepth: avDepth,
                                                 options: Photo3DPipeline.Options(fillMode: fm)) { p, m in
                    Task { @MainActor in
                        self.progress = p
                        self.progressMessage = m
                    }
                }
                await MainActor.run {
                    self.scene = scene
                    // 视差幅度：配合自适应支点(主体锚定、深层背景扫动)，略放大让背景运镜更明显。
                    self.params.parallaxAmp = 0.022 + scene.suggestedParallax * 0.026
                    self.sourceInfo = AppText.sourceInfo(depth: scene.depthSource, subject: scene.segmentSource, fill: scene.inpaintSource)
                    self.stage = .editor
                    // 测试钩子：AUTOEXPORT=video|spatial 时自动触发导出，便于冒烟测试导出链路。
                    switch ProcessInfo.processInfo.environment["AUTOEXPORT"] {
                    case "video": self.exportVideo()
                    case "spatial": self.exportSpatial()
                    default: break
                    }
                }
            } catch is CancellationError {
                await MainActor.run {     // 用户主动取消：静默回到首页，不当作错误
                    self.stage = .idle
                    self.progress = 0
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = AppText.Error.processingFailed(error.localizedDescription)
                    self.stage = .idle
                }
            }
        }
    }

    /// 取消处理：管线在各阶段节点检查 Task 取消并尽快退出。
    func cancelProcessing() {
        processingTask?.cancel()
        progressMessage = AppText.Processing.cancelling
    }

    func reset() {
        scene = nil
        stage = .idle
        progress = 0
    }

    // MARK: - 导出

    func exportVideo() {
        guard let scene = scene else { return }
        isExporting = true
        exportMessage = AppText.Export.renderingVideo
        let params = self.params
        exportTask = Task.detached(priority: .userInitiated) {
            do {
                let url = try VideoExporter.export(scene: scene, baseParams: params)
                NSLog("[Export] 视频导出成功：%@", url.path)
                await MainActor.run {
                    self.isExporting = false
                    self.exportResult = ExportResult(url: url, kind: .video)
                }
            } catch is CancellationError {
                await MainActor.run { self.isExporting = false }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = AppText.Error.exportVideoFailed(error.localizedDescription)
                }
            }
        }
    }

    func exportSpatial() {
        guard let scene = scene else { return }
        isExporting = true
        exportMessage = AppText.Export.renderingSpatial
        let params = self.params
        exportTask = Task.detached(priority: .userInitiated) {
            do {
                let url = try SpatialPhotoExporter.export(scene: scene, baseParams: params)
                await MainActor.run {
                    self.isExporting = false
                    self.exportResult = ExportResult(url: url, kind: .spatial)
                }
            } catch is CancellationError {
                await MainActor.run { self.isExporting = false }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = AppText.Error.exportSpatialFailed(error.localizedDescription)
                }
            }
        }
    }

    /// 取消导出：VideoExporter 在帧循环里检查 Task 取消，中断并清理半成品文件。
    func cancelExport() {
        exportTask?.cancel()
        exportMessage = AppText.Processing.cancelling
    }

    func saveToAlbum(_ result: ExportResult) {
        Task {
            do {
                switch result.kind {
                case .video: try await MediaSaver.saveVideo(result.url)
                case .spatial: try await MediaSaver.saveImage(result.url)
                }
                self.toast = AppText.Export.saved
            } catch {
                self.errorMessage = AppText.Error.saveFailed(error.localizedDescription)
            }
        }
    }
}
