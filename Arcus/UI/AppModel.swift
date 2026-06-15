import SwiftUI
import AVFoundation
import Metal

@MainActor
final class AppModel: ObservableObject {

    enum Stage: Equatable { case idle, processing, editor }
    enum ExportKind { case video, spatial, gif, live }

    /// 渲染方案（首页选择）：分层视差(LDI，原有) / 高斯泼溅(3DGS，新)。
    enum SceneMode: String, CaseIterable, Identifiable, Sendable {
        case layeredLDI
        case gaussianSplat
        case sharpSplat        // 隐藏实验：Apple SHARP 单图→3DGS（研究授权，不上架；只经 env/隐藏入口选中）
        var id: String { rawValue }
        /// 启动页可见选项（不含实验性的 SHARP）。
        static var selectable: [SceneMode] { [.layeredLDI, .gaussianSplat] }
        var title: String {
            switch self {
            case .layeredLDI: return String(localized: "Layered Parallax")
            case .gaussianSplat: return String(localized: "Gaussian Splatting")
            case .sharpSplat: return String(localized: "SHARP (experimental)")
            }
        }
        var detail: String {
            switch self {
            case .layeredLDI:    return String(localized: "Real-time depth-layered mesh, great for subtle parallax, pop-out, and export")
            case .gaussianSplat: return String(localized: "On-device 3D Gaussian splatting with true novel views, fully offline and dependency-free")
            case .sharpSplat:    return String(localized: "Apple SHARP single-image 3DGS — research model, local experiment only")
            }
        }
    }
    struct ExportResult: Identifiable { let id = UUID(); let url: URL; let kind: ExportKind; var pairedURL: URL? = nil }

    @Published var stage: Stage = .idle
    @Published var progress: Double = 0
    @Published var progressMessage = ""
    @Published var scene: Photo3DScene?
    @Published var params = ViewerParams()
    @Published var fillMode: FillMode = .fast   // 启动页选择：快速 / PatchMatch / MI-GAN
    @Published var sceneMode: SceneMode = .layeredLDI   // 启动页选择：分层视差(LDI) / 高斯泼溅(3DGS)
    @Published var sourceInfo = ""
    @Published var errorMessage: String?
    @Published var sourceImage: UIImage?         // 原图：高斯模式「虚拟云状」背景 + 修复补底

    // 视角修复（高斯模式「补全这一视角」）：端侧 LaMa/MI-GAN 默认，离线；可选 Gemini 云端。
    @Published var repairResult: UIImage?
    @Published var repairing = false
    @Published var repairFailed = false
    @Published var repairMessage = ""
    @Published var geminiEnabled = UserDefaults.standard.bool(forKey: "Arcus.geminiEnabled") {
        didSet { UserDefaults.standard.set(geminiEnabled, forKey: "Arcus.geminiEnabled") }
    }
    @Published var geminiKey = UserDefaults.standard.string(forKey: "Arcus.geminiKey") ?? "" {
        didSet { UserDefaults.standard.set(geminiKey, forKey: "Arcus.geminiKey") }
    }
    @Published var geminiModel = UserDefaults.standard.string(forKey: "Arcus.geminiModel") ?? GeminiRepair.defaultModel {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "Arcus.geminiModel") }
    }

    @Published var isExporting = false
    @Published var exportMessage = ""
    @Published var exportResult: ExportResult?
    @Published var toast: String?

    // 空间画廊（端侧持久化的「3D 照片库」）
    @Published var galleryItems: [LibraryItem] = []

    let pipeline = Photo3DPipeline()
    private(set) lazy var depthModelAvailable: Bool = pipeline.isDepthModelAvailable

    private var processingTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var activeRequestID = UUID()   // 防乱序：重选/取消后，旧任务的迟到结果不得覆盖新状态

    // MARK: - 处理入口

    func processData(_ data: Data) {
        // ImageIO 子采样解码：摆正 + 降采样一步完成，超大照片(48MP)不在原始分辨率整图落内存。
        let maxSide = Photo3DPipeline.Options().maxWorkingSide
        guard let img = ImageUtils.downsampledImage(from: data, maxSide: maxSide) ?? UIImage(data: data) else {
            errorMessage = String(localized: "Unable to read the selected image.")
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
        progressMessage = String(localized: "Preparing…")
        errorMessage = nil
        sourceImage = image                 // 处理态炫彩特效 + 高斯雾状背景都要用原图
        processingTask?.cancel()            // 重选/重跑：先取消上一条管线，让它在最近 checkCancellation() 退出，释放强引用、停止抢 CPU
        let rid = UUID(); activeRequestID = rid
        let pipeline = self.pipeline
        let fm = self.fillMode
        let sm = self.sceneMode
        let useCloudFill = (fm == .cloud) && canUseGemini   // 仅 Cloud 模式且已配置 Key 才联网；否则管线自动回退 PatchMatch
        let gKey = geminiKey, gModel = geminiModel
        processingTask = Task.detached(priority: .userInitiated) {
            do {
                var opts = Photo3DPipeline.Options(fillMode: fm,
                                                   buildGaussians: sm == .gaussianSplat || sm == .sharpSplat,
                                                   useSharp: sm == .sharpSplat)
                if useCloudFill {
                    opts.cloudFill = { rgb, hole in AppModel.cloudFillSync(rgb: rgb, hole: hole, key: gKey, model: gModel) }
                }
                let scene = try pipeline.process(image: image, avDepth: avDepth, options: opts) { p, m in
                    Task { @MainActor in
                        guard self.activeRequestID == rid else { return }   // 已被新请求取代的旧管线，别覆盖新进度
                        self.progress = p
                        self.progressMessage = m
                    }
                }
                // 存入空间画廊（端侧、离线、隐私）：原图 JPEG + 缩略图 + 方案元数据
                try Task.checkCancellation()   // 已被新请求取消的孤儿任务不再写图库/触发淘汰
                if let sdata = image.jpegData(compressionQuality: 0.9) {
                    let saved = PhotoLibraryStore.shared.save(sourceData: sdata, sceneMode: sm.rawValue, fillMode: fm.rawValue)
                    NSLog("[Gallery] saved record id=%@ bytes=%d", saved?.id ?? "nil", sdata.count)
                } else {
                    NSLog("[Gallery] jpegData is nil, skip save")
                }
                await MainActor.run {
                    guard self.activeRequestID == rid else { return }   // 已有更新请求，丢弃本次结果
                    self.scene = scene
                    self.galleryItems = PhotoLibraryStore.shared.items()
                    self.sourceImage = image
                    // 视差幅度：配合自适应支点(主体锚定、深层背景扫动)，略放大让背景运镜更明显。
                    self.params.parallaxAmp = 0.022 + scene.suggestedParallax * 0.026
                    self.sourceInfo = String(format: String(localized: "Depth %1$@, subject %2$@, fill %3$@"), scene.depthSource, scene.segmentSource, scene.inpaintSource)
                    self.stage = .editor
                    // 测试钩子：AUTOEXPORT=video|spatial 时自动触发导出，便于冒烟测试导出链路。
                    switch ProcessInfo.processInfo.environment["AUTOEXPORT"] {
                    case "video": self.exportVideo()
                    case "spatial": self.exportSpatial()
                    case "gif": self.exportGif()
                    case "live": self.exportLive()
                    default: break
                    }
                }
            } catch is CancellationError {
                await MainActor.run {     // 用户主动取消：静默回到首页，不当作错误
                    guard self.activeRequestID == rid else { return }
                    self.stage = .idle
                    self.progress = 0
                }
            } catch {
                await MainActor.run {
                    guard self.activeRequestID == rid else { return }
                    self.errorMessage = String(format: String(localized: "Processing failed: %@"), error.localizedDescription)
                    self.stage = .idle
                }
            }
        }
    }

    /// 取消处理：管线在各阶段节点检查 Task 取消并尽快退出。
    func cancelProcessing() {
        processingTask?.cancel()
        progressMessage = String(localized: "Cancelling…")
    }

    func reset() {
        scene = nil
        stage = .idle
        progress = 0
        repairResult = nil
        repairFailed = false
        repairMessage = ""
        sourceImage = nil
        if isDollyZooming { dollyTask?.cancel(); dollyTask = nil; isDollyZooming = false }
    }

    // MARK: - 空间画廊

    func refreshGallery() { galleryItems = PhotoLibraryStore.shared.items() }

    /// 从画廊重新打开一张：按当初的方案/补全方式重跑（端侧很快，配合炫彩加载态）。
    func openLibraryItem(_ item: LibraryItem) {
        guard let data = PhotoLibraryStore.shared.sourceData(for: item) else {
            errorMessage = String(localized: "Couldn't load this photo — it may have been cleared.")
            refreshGallery()
            return
        }
        sceneMode = SceneMode(rawValue: item.sceneMode) ?? sceneMode
        fillMode = FillMode(rawValue: item.fillMode) ?? fillMode
        processData(data)
    }

    func deleteLibraryItem(_ item: LibraryItem) {
        PhotoLibraryStore.shared.delete(item)
        refreshGallery()
    }

    /// 批量删除（画廊「多选删除」）：删完只刷新一次，避免逐条刷新抖动。
    func deleteLibraryItems(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for item in galleryItems where ids.contains(item.id) {
            PhotoLibraryStore.shared.delete(item)
        }
        refreshGallery()
    }

    // MARK: - 视角修复（高斯模式「补全这一视角」）

    var canUseGemini: Bool { geminiEnabled && !geminiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 当前是否走高斯渲染宿主（高斯泼溅 / SHARP 实验都会填充 gaussianScene）。视图层统一读这里。
    var isGaussian: Bool { scene?.gaussianScene != nil }

    /// 把当前机位的离屏快照修成一张干净成片：优先 Gemini 云端（若已配置），否则/失败回退端侧 LaMa/MI-GAN（离线）。
    /// 快照以异步闭包传入：在 MainActor 上 await（GPU 等待挂起、不阻塞主线程），重活随后丢进后台任务。
    func repairCurrentViewpoint(snapshot: @escaping () async -> MTLTexture?) {
        guard !repairing else { return }
        repairing = true; repairFailed = false; repairResult = nil
        let rid = activeRequestID    // 防陈旧：修复期间若重新处理(新 rid)，丢弃这次迟到的修复结果
        let useCloud = canUseGemini
        repairMessage = useCloud ? String(localized: "Repairing in the Gemini cloud…") : String(localized: "Repairing on-device…")
        let original = sourceImage
        let key = geminiKey, model = geminiModel
        let pipeline = self.pipeline
        Task { @MainActor in
            guard let tex = await snapshot() else {     // GPU 等待在此挂起，主线程不卡
                self.repairing = false; self.repairFailed = true
                self.errorMessage = String(localized: "View repair failed. Please try again.")
                return
            }
            Task.detached(priority: .userInitiated) {
            let snapCG = TextureIO.cgImage(from: tex)
            let snapUI = snapCG.map { UIImage(cgImage: $0) }
            var result: UIImage?
            if useCloud, let snapUI {
                let composed = Self.composeForGemini(rendered: snapUI, source: original)
                result = try? await GeminiRepair.repair(image: composed, key: key, model: model)
            }
            if result == nil, let (rgb, hole) = TextureIO.rgbAndHole(from: tex) {
                let filled = pipeline.reframeInpaint(rgb: rgb, hole: hole.dilated(radius: 2)) ?? rgb
                result = filled.toCGImage().map { UIImage(cgImage: $0) }
            }
            if result == nil { result = snapUI }
            await MainActor.run {
                self.repairing = false
                guard self.activeRequestID == rid else { return }   // 已重新处理，丢弃迟到的修复结果
                if let result { self.repairResult = result }
                else { self.repairFailed = true; self.errorMessage = String(localized: "View repair failed. Please try again.") }
            }
            }   // 关闭 Task.detached
        }       // 关闭外层 Task { @MainActor }
    }

    func saveRepairResult() {
        guard let img = repairResult else { return }
        saveImageToPhotos(img, name: "Arcus-Reshot")
    }

    /// 把一张成片(JPEG)落临时盘并存进相册；toast/错误统一在此处理。重拍与视角修复共用。
    func saveImageToPhotos(_ image: UIImage, name: String) {
        Task {
            do {
                guard let data = image.jpegData(compressionQuality: 0.95) else { throw MediaSaver.SaveError.failed }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name)-\(UInt32.random(in: 0...UInt32.max)).jpg")
                try data.write(to: url)
                try await MediaSaver.saveImage(url)
                self.toast = String(localized: "Saved to Photos")
            } catch {
                self.errorMessage = String(format: String(localized: "Failed to save to Photos: %@"), error.localizedDescription)
            }
        }
    }

    // MARK: - 镜头：自动推轨变焦 / 复位

    @Published var isDollyZooming = false
    private var dollyTask: Task<Void, Never>?

    /// 自动希区柯克推轨变焦：循环把 gsDolly 推近→拉远→归位（60fps smoothstep）。
    func toggleDollyZoom() {
        if isDollyZooming {
            dollyTask?.cancel(); dollyTask = nil; isDollyZooming = false
            withAnimation(.easeOut(duration: 0.4)) { params.gsDolly = 0 }
            return
        }
        isDollyZooming = true
        dollyTask = Task { @MainActor in
            while !Task.isCancelled {
                await self.rampDolly(0, 0.6, 1.2)
                await self.rampDolly(0.6, -0.35, 1.4)
                await self.rampDolly(-0.35, 0, 0.9)
            }
            self.isDollyZooming = false
        }
    }

    private func rampDolly(_ from: Float, _ to: Float, _ dur: Double) async {
        let steps = max(1, Int(dur * 60))
        for i in 0...steps {
            if Task.isCancelled { return }
            let t = Float(i) / Float(steps)
            params.gsDolly = from + (to - from) * (t * t * (3 - 2 * t))
            try? await Task.sleep(nanoseconds: 16_666_667)
        }
    }

    func resetLens() {
        if isDollyZooming { dollyTask?.cancel(); dollyTask = nil; isDollyZooming = false }
        withAnimation(.easeOut(duration: 0.25)) {
            params.gsDolly = 0; params.gsFocus = 0.5; params.gsFNumber = 16
        }
    }

    /// 把含透明洞的快照叠到原图(aspect-fill)上，得到给 Gemini 的完整帧（洞处用原图补底）。
    nonisolated private static func composeForGemini(rendered: UIImage, source: UIImage?) -> UIImage {
        let size = rendered.size
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = rendered.scale; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            if let source, source.size.width > 0, source.size.height > 0 {
                let s = max(size.width / source.size.width, size.height / source.size.height)
                let dw = source.size.width * s, dh = source.size.height * s
                source.draw(in: CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2, width: dw, height: dh))
            } else {
                UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            }
            rendered.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 云端背景补全（首页 Cloud Fill）：主体洞涂中性灰标出 → Gemini 生成身后背景 → 仅在洞内合成、洞外保留真背景。
    /// 同步阻塞：在后台管线线程上以信号量等这一次网络调用；失败/超时返回 nil ⇒ 管线回退 PatchMatch（鲁棒兜底）。
    nonisolated static func cloudFillSync(rgb: FloatImage, hole: FloatImage, key: String, model: String) -> FloatImage? {
        let W = rgb.width, H = rgb.height
        let ch = rgb.channels
        guard ch >= 3, hole.width == W, hole.height == H else { return nil }
        // 1) 洞(主体)涂中性灰，向模型标出「待移除前景 / 待补全背景」
        var erased = rgb
        for p in 0..<(W * H) where hole.pixels[p] > 0.5 {
            let b = p * ch
            erased.pixels[b] = 0.5; erased.pixels[b + 1] = 0.5; erased.pixels[b + 2] = 0.5
        }
        guard let erasedCG = erased.toCGImage() else { return nil }
        // 2) 等待 Gemini。注意：这里阻塞的是**调用线程本身**(管线所在的协作线程)，不是 URLSession 的线程。
        //    故用**有界**等待：网络挂死或管线被取消时，最多占用 60s 后释放线程并回退 PatchMatch，避免长时间占着协作线程。
        let sem = DispatchSemaphore(value: 0)
        var got: UIImage?
        Task.detached(priority: .userInitiated) {
            got = try? await GeminiRepair.fillBackground(image: UIImage(cgImage: erasedCG), key: key, model: model)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut { return nil }   // 超时 → 回退端侧补全
        guard let got, let genCG = got.cgImage else { return nil }
        // 3) 云端结果缩放回 W×H；只在洞内取云端、洞外保留真背景（柔边过渡，避免剪影硬边）
        let gen = FloatImage.fromCGImage(genCG, width: W, height: H)   // 4ch
        let feather = hole.boxBlurred(radius: max(2, W / 200), passes: 1)
        var out = rgb
        for p in 0..<(W * H) {
            let a = max(0, min(1, feather.pixels[p]))
            if a <= 0.001 { continue }
            let gb = p * 4, ob = p * ch
            out.pixels[ob]     = rgb.pixels[ob]     * (1 - a) + gen.pixels[gb]     * a
            out.pixels[ob + 1] = rgb.pixels[ob + 1] * (1 - a) + gen.pixels[gb + 1] * a
            out.pixels[ob + 2] = rgb.pixels[ob + 2] * (1 - a) + gen.pixels[gb + 2] * a
        }
        return out
    }

    // MARK: - 导出

    /// 四种导出共用的脚手架：置 isExporting、丢后台任务、统一处理取消/错误、回主线程发结果。
    /// 各导出只提供：进度文案、出错文案、以及「跑导出器并造出 ExportResult」这一份独有逻辑。
    private func runExport(message: String, errorFormat: String,
                          _ work: @Sendable @escaping () throws -> ExportResult) {
        guard scene != nil else { return }
        isExporting = true
        exportMessage = message
        exportTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try work()
                await MainActor.run { self.isExporting = false; self.exportResult = result }
            } catch is CancellationError {
                await MainActor.run { self.isExporting = false }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = String(format: errorFormat, error.localizedDescription)
                }
            }
        }
    }

    func exportVideo() {
        guard let scene else { return }
        let params = self.params
        runExport(message: String(localized: "Rendering parallax video…"),
                  errorFormat: String(localized: "Failed to export video: %@")) {
            let url = try VideoExporter.export(scene: scene, baseParams: params)
            NSLog("[Export] Video exported: %@", url.path)
            return ExportResult(url: url, kind: .video)
        }
    }

    func exportLive() {
        guard let scene else { return }
        let params = self.params
        runExport(message: String(localized: "Rendering Live Photo…"),
                  errorFormat: String(localized: "Live Photo export failed: %@")) {
            let r = try LivePhotoExporter.export(scene: scene, baseParams: params)
            let sz = (try? Data(contentsOf: r.video))?.count ?? 0
            NSLog("[Export] Live Photo exported still=%@ video=%@ (%dKB)", r.still.lastPathComponent, r.video.lastPathComponent, sz/1024)
            return ExportResult(url: r.still, kind: .live, pairedURL: r.video)
        }
    }

    func exportGif() {
        guard let scene else { return }
        let params = self.params
        runExport(message: String(localized: "Rendering animation…"),
                  errorFormat: String(localized: "GIF export failed: %@")) {
            let url = try GifExporter.export(scene: scene, baseParams: params)
            let sz = (try? Data(contentsOf: url))?.count ?? 0
            NSLog("[Export] GIF exported %@ (%dKB)", url.lastPathComponent, sz/1024)
            return ExportResult(url: url, kind: .gif)
        }
    }

    func exportSpatial() {
        guard let scene else { return }
        let params = self.params
        runExport(message: String(localized: "Rendering spatial photo…"),
                  errorFormat: String(localized: "Failed to export spatial photo: %@")) {
            let url = try SpatialPhotoExporter.export(scene: scene, baseParams: params)
            return ExportResult(url: url, kind: .spatial)
        }
    }

    /// 取消导出：VideoExporter 在帧循环里检查 Task 取消，中断并清理半成品文件。
    func cancelExport() {
        exportTask?.cancel()
        exportMessage = String(localized: "Cancelling…")
    }

    func saveToAlbum(_ result: ExportResult) {
        Task {
            do {
                switch result.kind {
                case .video: try await MediaSaver.saveVideo(result.url)
                case .spatial, .gif: try await MediaSaver.saveImage(result.url)   // GIF 字节原样落盘 → 相册保留动画
                case .live:
                    if let video = result.pairedURL {
                        try await MediaSaver.saveLivePhoto(still: result.url, video: video)
                    } else { try await MediaSaver.saveImage(result.url) }
                }
                // 入相册后清理临时产物，避免 temporaryDirectory 持续堆积
                try? FileManager.default.removeItem(at: result.url)
                if let paired = result.pairedURL { try? FileManager.default.removeItem(at: paired) }
                self.toast = String(localized: "Saved to Photos")
            } catch {
                self.errorMessage = String(format: String(localized: "Failed to save to Photos: %@"), error.localizedDescription)
            }
        }
    }
}
