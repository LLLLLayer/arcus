import Foundation
import CoreML
import UIKit

/// Apple SHARP（单图→3D 高斯泼溅）Core ML 前向封装——**仅本地实验**（Apple 研究专用许可，不可商用/上架）。
/// 模型从 Apple 官方 `github.com/apple/ml-sharp` 权重自行转换（FP16/iOS17，见 research/ml-sharp/convert_sharp_coreml.py）。
/// 只放神经前向：输入定长 1536²，输出仍在 **NDC/相机帧** 的 5 组张量；NDC→公制 + 协方差合成留给
/// `SharpGaussianBuilder`（Core ML 无法表达 fp64 反投影/分解）。模型缺失/失败 → nil，调用方回退解析式高斯。
final class SHARPModel {

    static let modelBaseName = "SHARP"
    private let internalRes = 1536
    private var model: MLModel?
    private var triedLoad = false
    private let lock = NSLock()   // 串行化懒加载：多条管线并发时不竞态改 model/triedLoad

    var isAvailable: Bool { loadIfNeeded(); return model != nil }

    /// SHARP 一次前向的原始输出（全部在 NDC/相机帧；线性 RGB；四元数 w-first 未归一）。
    struct RawOutput {
        let count: Int
        let mean: [Float]     // N×3  NDC×深度
        let scale: [Float]    // N×3  σ 标准差
        let quat: [Float]     // N×4  (w,x,y,z)
        let color: [Float]    // N×3  linearRGB 0..1
        let opacity: [Float]  // N
        let srcWidth: Int     // 原图像素宽（仅其宽高比影响公制尺度）
        let srcHeight: Int
    }

    private func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !triedLoad else { return }
        triedLoad = true
        guard let url = Self.findModelURL() else {
            NSLog("[SHARP] No SHARP.mlpackage found in bundle. SHARP scene mode will fall back to analytic gaussians.")
            return
        }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndGPU   // 700M/1536² 在 ANE 上编译/分区会 hang（见 doc 16），GPU 足矣
            model = try MLModel(contentsOf: url, configuration: cfg)
            NSLog("[SHARP] Loaded model: \(url.lastPathComponent)")
        } catch {
            NSLog("[SHARP] Load failed: \(error.localizedDescription)")
        }
    }

    private static func findModelURL() -> URL? {
        if let c = Bundle.main.url(forResource: modelBaseName, withExtension: "mlmodelc") { return c }
        if let p = Bundle.main.url(forResource: modelBaseName, withExtension: "mlpackage") {
            return try? MLModel.compileModel(at: p)
        }
        return nil
    }

    /// 跑一次 SHARP 前向。失败/模型缺失返回 nil。
    func predict(image: UIImage) -> RawOutput? {
        loadIfNeeded()
        guard let model else { return nil }
        guard let cg = Self.uprightCGImage(image) else { return nil }
        let W = cg.width, H = cg.height
        guard W > 1, H > 1 else { return nil }

        // f_px：Apple 的全画幅 36×24mm 对角模型，缺 EXIF 默认 30mm 等效（尺度只取决于宽高比）。
        let fPx = 30.0 * sqrt(Double(W * W + H * H)) / sqrt(36.0 * 36.0 + 24.0 * 24.0)
        let disparityFactor = Float(fPx / Double(W))

        guard let imgArr = Self.makeCHWInput(cg, side: internalRes),
              let dispArr = try? MLMultiArray(shape: [1], dataType: .float32) else { return nil }
        dispArr.dataPointer.assumingMemoryBound(to: Float32.self)[0] = disparityFactor

        guard let prov = try? MLDictionaryFeatureProvider(dictionary: ["image": imgArr, "disparity_factor": dispArr]),
              let out = try? model.prediction(from: prov) else {
            NSLog("[SHARP] Inference failed.")
            return nil
        }
        guard let mean = Self.readFloats(out, "mean"),
              let scale = Self.readFloats(out, "scale"),
              let quat = Self.readFloats(out, "quat"),
              let color = Self.readFloats(out, "color"),
              let opacity = Self.readFloats(out, "opacity") else {
            NSLog("[SHARP] Missing expected outputs (mean/scale/quat/color/opacity).")
            return nil
        }
        let n = opacity.count
        // 全部长度都要核对：SharpGaussianBuilder 用 withUnsafeBufferPointer 读 scale/color（release 不做越界检查），
        // 长度不符会越界读 → 崩溃。任一不符即返回 nil，调用方回退解析式高斯（保住「绝不崩溃」不变量）。
        guard n > 0, mean.count == n * 3, scale.count == n * 3, color.count == n * 3, quat.count == n * 4 else {
            NSLog("[SHARP] Output shape mismatch: N=%d mean=%d scale=%d color=%d quat=%d",
                  n, mean.count, scale.count, color.count, quat.count)
            return nil
        }
        return RawOutput(count: n, mean: mean, scale: scale, quat: quat,
                         color: color, opacity: opacity, srcWidth: W, srcHeight: H)
    }

    // MARK: - 预处理

    /// 摆正方向后取 CGImage（SHARP 期望行0=顶部的常规图像）。
    private static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let ui = UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return ui.cgImage
    }

    /// CGImage → 非等比拉伸到 side²、planar CHW、float32、/255，行0=顶部（翻转 CG 默认坐标）。
    private static func makeCHWInput(_ cg: CGImage, side: Int) -> MLMultiArray? {
        guard let arr = try? MLMultiArray(shape: [1, 3, side, side] as [NSNumber], dataType: .float32),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &bytes, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(side)); ctx.scaleBy(x: 1, y: -1)   // 让 byte 行0=图像顶部
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = side * side, inv: Float = 1.0 / 255.0
        for i in 0..<plane {
            p[0 * plane + i] = Float(bytes[i * 4 + 0]) * inv   // R
            p[1 * plane + i] = Float(bytes[i * 4 + 1]) * inv   // G
            p[2 * plane + i] = Float(bytes[i * 4 + 2]) * inv   // B
        }
        return arr
    }

    /// 读 MLMultiArray 为 [Float]，兼容 float16/float32/double 输出。
    private static func readFloats(_ out: MLFeatureProvider, _ name: String) -> [Float]? {
        guard let a = out.featureValue(for: name)?.multiArrayValue else { return nil }
        let n = a.count
        var result = [Float](repeating: 0, count: n)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<n { result[i] = p[i] }
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<n { result[i] = Float(p[i]) }
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Float64.self)
            for i in 0..<n { result[i] = Float(p[i]) }
        @unknown default:
            for i in 0..<n { result[i] = a[i].floatValue }
        }
        return result
    }
}
