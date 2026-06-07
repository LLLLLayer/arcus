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
    @Published var sourceInfo = ""
    @Published var errorMessage: String?

    @Published var isExporting = false
    @Published var exportMessage = ""
    @Published var exportResult: ExportResult?
    @Published var toast: String?

    let pipeline = Photo3DPipeline()
    private(set) lazy var depthModelAvailable: Bool = pipeline.isDepthModelAvailable

    // MARK: - 处理入口

    func processData(_ data: Data) {
        guard let img = UIImage(data: data) else {
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
        Task.detached(priority: .userInitiated) {
            do {
                let scene = try pipeline.process(image: image, avDepth: avDepth) { p, m in
                    Task { @MainActor in
                        self.progress = p
                        self.progressMessage = m
                    }
                }
                await MainActor.run {
                    self.scene = scene
                    // 默认更克制的视差幅度：露出的去遮挡带更窄，背景“糊”的部分更少（苹果的运动也很微妙）
                    self.params.parallaxAmp = 0.015 + scene.suggestedParallax * 0.018
                    self.sourceInfo = "深度：\(scene.depthSource) · 主体：\(scene.segmentSource) · 补全：\(scene.inpaintSource)"
                    self.stage = .editor
                    // 测试钩子：AUTOEXPORT=video|spatial 时自动触发导出，便于冒烟测试导出链路。
                    switch ProcessInfo.processInfo.environment["AUTOEXPORT"] {
                    case "video": self.exportVideo()
                    case "spatial": self.exportSpatial()
                    default: break
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "处理失败：\(error.localizedDescription)"
                    self.stage = .idle
                }
            }
        }
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
        Task.detached(priority: .userInitiated) {
            do {
                let url = try VideoExporter.export(scene: scene, baseParams: params)
                NSLog("[Export] 视频导出成功：%@", url.path)
                await MainActor.run {
                    self.isExporting = false
                    self.exportResult = ExportResult(url: url, kind: .video)
                }
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
        Task.detached(priority: .userInitiated) {
            do {
                let url = try SpatialPhotoExporter.export(scene: scene, baseParams: params)
                await MainActor.run {
                    self.isExporting = false
                    self.exportResult = ExportResult(url: url, kind: .spatial)
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = "导出空间照片失败：\(error.localizedDescription)"
                }
            }
        }
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
