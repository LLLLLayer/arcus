import Foundation
import CoreML
import Vision
import AVFoundation
import CoreVideo

/// 单目深度估计。
/// 优先级：AVDepthData（拍摄自带，免跑模型） → Core ML Depth Anything V2 → 伪深度兜底。
/// 产出统一为「视差」FloatImage(1ch)，约定 0=最远、1=最近，已归一化到工作分辨率。
final class DepthEstimator {

    enum Source: String { case avDepth = "AVDepthData", coreML = "Depth Anything V2", pseudo = "Pseudo-depth (fallback)" }

    struct Result {
        var disparity: FloatImage   // 1ch, 0…1, 1=近
        var source: Source
    }

    /// 候选模型名（按质量优先级）：高端机可放 Base 提升精度，否则用官方 Small。
    static let modelCandidates = ["DepthAnythingV2BaseF16", "DepthAnythingV2SmallF16"]

    private var vnModel: VNCoreMLModel?
    private var triedLoad = false

    /// 模型文件是否存在（用于 UI 提示）。只查文件、不加载/编译模型——
    /// 这个检查在首屏主线程触发，真正的加载留到 estimate() 在后台首次推理时做。
    var isModelAvailable: Bool {
        if vnModel != nil { return true }
        for name in Self.modelCandidates {
            if Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil { return true }
            if Bundle.main.url(forResource: name, withExtension: "mlpackage") != nil { return true }
        }
        if let res = Bundle.main.resourceURL,
           let items = try? FileManager.default.contentsOfDirectory(at: res, includingPropertiesForKeys: nil) {
            return items.contains {
                ($0.pathExtension == "mlmodelc" || $0.pathExtension == "mlpackage")
                    && $0.lastPathComponent.localizedCaseInsensitiveContains("depth")
            }
        }
        return false
    }

    // MARK: - 模型加载（动态，不依赖编译期生成的类）

    private func loadModelIfNeeded() {
        guard !triedLoad else { return }
        triedLoad = true
        guard let url = Self.findModelURL() else {
            NSLog("[Depth] No Core ML depth model found; using pseudo-depth fallback. Run scripts/download_models.sh to fetch models.")
            return
        }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let ml = try MLModel(contentsOf: url, configuration: cfg)
            vnModel = try VNCoreMLModel(for: ml)
            NSLog("[Depth] Loaded Core ML depth model: \(url.lastPathComponent)")
        } catch {
            NSLog("[Depth] Failed to load depth model: \(error.localizedDescription)")
        }
    }

    private static func findModelURL() -> URL? {
        for name in modelCandidates {
            if let c = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return c }
            if let p = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                return try? MLModel.compileModel(at: p)
            }
        }
        // 宽松搜索 bundle 内任意已编译的深度模型。
        if let res = Bundle.main.resourceURL,
           let items = try? FileManager.default.contentsOfDirectory(at: res, includingPropertiesForKeys: nil) {
            if let hit = items.first(where: { $0.pathExtension == "mlmodelc" && $0.lastPathComponent.localizedCaseInsensitiveContains("depth") }) {
                return hit
            }
            if let pkg = items.first(where: { $0.pathExtension == "mlpackage" && $0.lastPathComponent.localizedCaseInsensitiveContains("depth") }) {
                return try? MLModel.compileModel(at: pkg)
            }
        }
        return nil
    }

    // MARK: - 主入口

    func estimate(cgImage: CGImage, width: Int, height: Int, avDepth: AVDepthData?) -> Result {
        if let av = avDepth, let disp = Self.disparity(from: av, width: width, height: height) {
            return Result(disparity: disp, source: .avDepth)
        }
        loadModelIfNeeded()
        if let model = vnModel, let disp = runCoreML(model: model, cgImage: cgImage, width: width, height: height) {
            return Result(disparity: disp, source: .coreML)
        }
        return Result(disparity: Self.pseudoDepth(cgImage: cgImage, width: width, height: height), source: .pseudo)
    }

    // MARK: - Core ML 推理

    private func runCoreML(model: VNCoreMLModel, cgImage: CGImage, width: Int, height: Int) -> FloatImage? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill   // 拉伸到模型输入，输出再拉回，整帧对齐
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[Depth] Core ML inference failed: \(error.localizedDescription)")
            return nil
        }
        guard let obs = request.results?.first as? VNPixelBufferObservation,
              var raw = ImageUtils.scalarFloats(from: obs.pixelBuffer) else { return nil }
        for i in 0..<raw.pixels.count where !raw.pixels[i].isFinite { raw.pixels[i] = 0 }  // 滤除 NaN/Inf
        Self.normalize(&raw)                 // 归一化到 0…1（暂不管远近方向，后续用 mask 自动定向）
        return raw.resized(to: width, to: height)
    }

    // MARK: - AVDepthData

    private static func disparity(from avDepth: AVDepthData, width: Int, height: Int) -> FloatImage? {
        // 统一转成 disparity（1/深度），数值越大越近。
        let converted: AVDepthData
        if avDepth.depthDataType != kCVPixelFormatType_DisparityFloat32 {
            converted = avDepth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        } else {
            converted = avDepth
        }
        guard var raw = ImageUtils.scalarFloats(from: converted.depthDataMap) else { return nil }
        // 替换 NaN/Inf（视差图常有无效值）。
        for i in 0..<raw.pixels.count where !raw.pixels[i].isFinite { raw.pixels[i] = 0 }
        normalize(&raw)
        return raw.resized(to: width, to: height)
    }

    // MARK: - 工具

    /// 鲁棒归一化到 0…1（用 2%/98% 分位裁剪，避免离群值压扁动态范围）。
    static func normalize(_ img: inout FloatImage) {
        let n = img.pixels.count
        guard n > 0 else { return }
        var sorted = img.pixels
        sorted.sort()
        let lo = sorted[Int(Double(n) * 0.02)]
        let hi = sorted[min(n - 1, Int(Double(n) * 0.98))]
        let range = max(hi - lo, 1e-5)
        for i in 0..<n {
            img.pixels[i] = min(1, max(0, (img.pixels[i] - lo) / range))
        }
    }

    /// 伪深度：垂直梯度(下方更近) + 亮度 + 轻微中心偏置。保证无模型也有 3D 视差。
    static func pseudoDepth(cgImage: CGImage, width: Int, height: Int) -> FloatImage {
        let color = FloatImage.fromCGImage(cgImage, width: width, height: height)
        var out = FloatImage(width: width, height: height, channels: 1)
        let cx = Float(width) * 0.5, cy = Float(height) * 0.55
        let maxR = sqrt(cx * cx + cy * cy)
        for y in 0..<height {
            let vy = Float(y) / Float(height)         // 0 顶 1 底
            for x in 0..<width {
                let base = (y * width + x) * 4
                let lum = 0.299 * color.pixels[base] + 0.587 * color.pixels[base + 1] + 0.114 * color.pixels[base + 2]
                let dx = Float(x) - cx, dy = Float(y) - cy
                let r = sqrt(dx * dx + dy * dy) / maxR  // 0 中心 1 边缘
                let center = 1 - r
                let d = 0.55 * vy + 0.20 * lum + 0.25 * center
                out.pixels[y * width + x] = min(1, max(0, d))
            }
        }
        return out.boxBlurred(radius: max(2, width / 200), passes: 2)
    }
}
