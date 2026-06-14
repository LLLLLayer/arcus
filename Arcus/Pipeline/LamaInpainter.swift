import Foundation
import CoreML

/// LaMa (Core ML) 学习型补全器：用 FFC-ResNet 把主体所在区域补成可信的背景纹理，
/// 取代 push-pull 的“扩散式糊”。模型固定 512×512：
///   输入 image[1,3,512,512] float32 RGB[0,1] + mask[1,1,512,512] (1=洞)
///   输出 inpainted_image[1,3,512,512] float32 [0,1]
/// 模型缺失/失败 → 返回 nil，由管线回退 push-pull。
final class LamaInpainter {

    static let modelBaseName = "LaMa"
    private let inputSize = 512
    private var model: MLModel?
    private var triedLoad = false

    var isAvailable: Bool { loadIfNeeded(); return model != nil }

    private func loadIfNeeded() {
        guard !triedLoad else { return }
        triedLoad = true
        guard let url = Self.findModelURL() else {
            NSLog("[LaMa] No inpainting model found, falling back to push-pull. Run scripts/download_models.sh.")
            return
        }
        do {
            let cfg = MLModelConfiguration()
            // FFC 的 irfft 等算子在 ANE 上不稳，pin 到 GPU+CPU 更可靠。
            cfg.computeUnits = .cpuAndGPU
            model = try MLModel(contentsOf: url, configuration: cfg)
            NSLog("[LaMa] Loaded inpainting model: \(url.lastPathComponent)")
        } catch {
            NSLog("[LaMa] Load failed: \(error.localizedDescription)")
        }
    }

    private static func findModelURL() -> URL? {
        if let c = Bundle.main.url(forResource: modelBaseName, withExtension: "mlmodelc") { return c }
        if let p = Bundle.main.url(forResource: modelBaseName, withExtension: "mlpackage") {
            return try? MLModel.compileModel(at: p)
        }
        return nil
    }

    /// 补全 rgb(3ch, W×H) 中 hole(1ch, 1=洞) 区域，返回补全后的 3ch 图；失败返回 nil。
    /// 关键优化：先按洞的包围盒(+留边做上下文)裁剪，仅把这块喂进 512 模型，
    /// 让洞接近原生分辨率（而非把整张 W×H 压到 512），单次推理即显著提升清晰度。
    /// hole 外保留原图，只在 hole 内软混合 LaMa 结果。
    func inpaint(rgb: FloatImage, hole: FloatImage) -> FloatImage? {
        loadIfNeeded()
        guard model != nil else { return nil }
        precondition(rgb.channels == 3 && hole.channels == 1)
        let W = rgb.width, H = rgb.height

        // 洞的包围盒
        var minX = W, minY = H, maxX = -1, maxY = -1
        for y in 0..<H {
            for x in 0..<W where hole.pixels[y * W + x] > 0.5 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        if maxX < 0 { return rgb }   // 无洞，原样返回

        // 留边作上下文（LaMa 需要洞周围像素参考）
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let mx = max(16, Int(Float(bw) * 0.35)), my = max(16, Int(Float(bh) * 0.35))
        let x0 = max(0, minX - mx), y0 = max(0, minY - my)
        let x1 = min(W - 1, maxX + mx), y1 = min(H - 1, maxY + my)
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1

        let rgbCrop = rgb.cropped(x: x0, y: y0, w: cw, h: ch)
        let holeCrop = hole.cropped(x: x0, y: y0, w: cw, h: ch)
        guard var filledCrop = runModel(rgbCrop: rgbCrop, holeCrop: holeCrop) else { return nil }

        // 中和该 LaMa CoreML 模型在「生成区」引入的整体偏色（实测：灰底洞内 G 被压低、B 抬高 → 品红/紫 cast）。
        // 做法：把补全区的逐通道均值平移到「洞周围真实背景」的均值。既消除紫色 cast，又让接缝更自然。
        Self.neutralizeColorCast(fill: &filledCrop, original: rgbCrop, hole: holeCrop)

        // 把裁剪块的补全结果软混合回原图。
        var outImg = rgb
        for j in 0..<ch {
            for i in 0..<cw {
                let a = min(1, max(0, holeCrop.pixels[j * cw + i]))
                if a > 0.01 {
                    let di = ((y0 + j) * W + (x0 + i)) * 3
                    let si = (j * cw + i) * 3
                    for c in 0..<3 {
                        outImg.pixels[di + c] = outImg.pixels[di + c] * (1 - a) + filledCrop.pixels[si + c] * a
                    }
                }
            }
        }
        return outImg
    }

    /// 中和补全区(hole 内)的整体偏色：把其逐通道均值平移到「紧邻洞外的真实背景」均值。
    /// 该 LaMa CoreML 模型对生成像素有近似常数的品红/紫 cast（G↓ B↑），常数平移即可去除，
    /// 同时让补全与周围背景同色、接缝更隐蔽。fill/original/hole 同尺寸；fill 为 3ch，hole 为 1ch。
    static func neutralizeColorCast(fill: inout FloatImage, original: FloatImage, hole: FloatImage) {
        precondition(fill.channels == 3 && original.channels == 3 && hole.channels == 1)
        let w = fill.width, h = fill.height, n = w * h
        guard n > 0 else { return }

        // 参考区 = 紧邻洞的真实背景环带（hole 膨胀 r 后、去掉 hole 本身）；环带太小则退化为全部已知背景。
        let r = max(6, Int(0.04 * Float(max(w, h))))
        let ringMask = hole.dilated(radius: r)

        var refSum = [Double](repeating: 0, count: 3); var refN = 0
        var allSum = [Double](repeating: 0, count: 3); var allN = 0
        var fillSum = [Double](repeating: 0, count: 3); var fillN = 0
        for p in 0..<n {
            if hole.pixels[p] > 0.5 {
                for c in 0..<3 { fillSum[c] += Double(fill.pixels[p * 3 + c]) }
                fillN += 1
            } else {
                for c in 0..<3 { allSum[c] += Double(original.pixels[p * 3 + c]) }
                allN += 1
                if ringMask.pixels[p] > 0.5 {     // 紧邻洞的真实背景
                    for c in 0..<3 { refSum[c] += Double(original.pixels[p * 3 + c]) }
                    refN += 1
                }
            }
        }
        guard fillN > 0 else { return }
        // 环带样本足够就用环带，否则用全部已知背景。
        let useRing = refN >= max(64, fillN / 20)
        let refTotN = useRing ? refN : allN
        let refTot = useRing ? refSum : allSum
        guard refTotN > 0 else { return }

        var offset = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            let ref = Float(refTot[c] / Double(refTotN))
            let f = Float(fillSum[c] / Double(fillN))
            offset[c] = ref - f
        }
        // 仅对 hole 内像素施加常数平移并 clamp。
        for p in 0..<n where hole.pixels[p] > 0.5 {
            for c in 0..<3 {
                fill.pixels[p * 3 + c] = min(1, max(0, fill.pixels[p * 3 + c] + offset[c]))
            }
        }
    }

    /// 把任意尺寸 crop 喂进 512 模型，返回与 crop 同尺寸的补全图。
    private func runModel(rgbCrop: FloatImage, holeCrop: FloatImage) -> FloatImage? {
        guard let model = model else { return nil }
        let S = inputSize, cw = rgbCrop.width, ch = rgbCrop.height
        let rgbS = rgbCrop.resized(to: S, to: S)
        let holeS = holeCrop.resized(to: S, to: S)
        guard let img = try? MLMultiArray(shape: [1, 3, S, S] as [NSNumber], dataType: .float32),
              let msk = try? MLMultiArray(shape: [1, 1, S, S] as [NSNumber], dataType: .float32) else { return nil }
        let ip = img.dataPointer.assumingMemoryBound(to: Float32.self)
        let mp = msk.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = S * S
        for p in 0..<plane {
            ip[0 * plane + p] = rgbS.pixels[p * 3 + 0]
            ip[1 * plane + p] = rgbS.pixels[p * 3 + 1]
            ip[2 * plane + p] = rgbS.pixels[p * 3 + 2]
            mp[p] = holeS.pixels[p] > 0.5 ? 1 : 0
        }
        guard let prov = try? MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk]),
              let out = try? model.prediction(from: prov),
              let arr = out.featureValue(for: "inpainted_image")?.multiArrayValue else {
            NSLog("[LaMa] Inference failed, falling back to push-pull")
            return nil
        }
        let op = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        var filledS = FloatImage(width: S, height: S, channels: 3)
        for p in 0..<plane {
            filledS.pixels[p * 3 + 0] = min(1, max(0, op[0 * plane + p]))
            filledS.pixels[p * 3 + 1] = min(1, max(0, op[1 * plane + p]))
            filledS.pixels[p * 3 + 2] = min(1, max(0, op[2 * plane + p]))
        }
        return filledS.resized(to: cw, to: ch)
    }
}
