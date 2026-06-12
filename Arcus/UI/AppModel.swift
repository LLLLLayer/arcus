import SwiftUI
import AVFoundation

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
            errorMessage = "无法读取所选图片。"
            return
        }
        let av = AuxDepthLoader.avDepth(from: data)
        process(image: img, avDepth: av)
    }

    func processSample() {
        process(image: SampleImage.make(), avDepth: nil)
    }

    private func process(image: UIImage, avDepth: AVDepthData?) {
        stage = .processing
        progress = 0
        progressMessage = "准备…"
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
                    self.sourceInfo = "深度：\(scene.depthSource) · 主体：\(scene.segmentSource) · 补全：\(scene.inpaintSource)"
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
                    self.errorMessage = "处理失败：\(error.localizedDescription)"
                    self.stage = .idle
                }
            }
        }
    }

    /// 取消处理：管线在各阶段节点检查 Task 取消并尽快退出。
    func cancelProcessing() {
        processingTask?.cancel()
        progressMessage = "正在取消…"
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
        exportMessage = "正在渲染视差视频…"
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
                    self.errorMessage = "导出视频失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportSpatial() {
        guard let scene = scene else { return }
        isExporting = true
        exportMessage = "正在渲染空间照片…"
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
                    self.errorMessage = "导出空间照片失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 取消导出：VideoExporter 在帧循环里检查 Task 取消，中断并清理半成品文件。
    func cancelExport() {
        exportTask?.cancel()
        exportMessage = "正在取消…"
    }

    func saveToAlbum(_ result: ExportResult) {
        Task {
            do {
                switch result.kind {
                case .video: try await MediaSaver.saveVideo(result.url)
                case .spatial: try await MediaSaver.saveImage(result.url)
                }
                self.toast = "已保存到相册"
            } catch {
                self.errorMessage = "保存到相册失败：\(error.localizedDescription)"
            }
        }
    }
}
