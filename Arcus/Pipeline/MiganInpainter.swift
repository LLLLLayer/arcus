import Foundation
import CoreML

/// MI-GAN (Core ML) 学习型补全器（ICCV 2023，Picsart）：纯卷积、移动端友好（~6M 参数，~14MB FP16），
/// 取代/补充 PatchMatch 作为「AI 补全」去遮挡。固定 512×512，模型内部已做归一化/生成/反归一化/合成：
///   输入 image[1,3,512,512] float32 RGB [0,255] + mask[1,1,512,512] float32（255=已知，0=洞）
///   输出 result[1,3,512,512] float32 RGB [0,255]（已把已知区原样保留、洞内为生成内容）
/// 与 LaMa 不同：非 FFC，无品红 cast，且模型自带合成。模型缺失/失败 → 返回 nil，由管线回退 PatchMatch。
final class MiganInpainter {

    static let modelBaseName = "MiGAN"
    private let inputSize = 512
    private var model: MLModel?
    private var triedLoad = false

    var isAvailable: Bool { loadIfNeeded(); return model != nil }

    private func loadIfNeeded() {
        guard !triedLoad else { return }
        triedLoad = true
        guard let url = Self.findModelURL() else {
            NSLog("[MiGAN] No inpainting model found, falling back to PatchMatch. Run scripts/download_models.sh / convert_migan.py.")
            return
        }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all   // 纯卷积，ANE/GPU 友好
            model = try MLModel(contentsOf: url, configuration: cfg)
            NSLog("[MiGAN] Loaded inpainting model: \(url.lastPathComponent)")
        } catch {
            NSLog("[MiGAN] Load failed: \(error.localizedDescription)")
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
    /// 与 LaMa 同构：按洞包围盒(+留边作上下文)裁剪 → 512 模型 → 仅在 hole 内软混合回原图。
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
        if maxX < 0 { return rgb }   // 无洞

        // 留边作上下文（生成器需要洞周围像素参考）
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let mx = max(16, Int(Float(bw) * 0.35)), my = max(16, Int(Float(bh) * 0.35))
        let x0 = max(0, minX - mx), y0 = max(0, minY - my)
        let x1 = min(W - 1, maxX + mx), y1 = min(H - 1, maxY + my)
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1

        let rgbCrop = rgb.cropped(x: x0, y: y0, w: cw, h: ch)
        let holeCrop = hole.cropped(x: x0, y: y0, w: cw, h: ch)
        guard let filledCrop = runModel(rgbCrop: rgbCrop, holeCrop: holeCrop) else { return nil }

        // 软混合回原图（仅 hole 内；剪影外保持全分辨率真背景）
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

    /// 把任意尺寸 crop 喂进 512 模型，返回与 crop 同尺寸的补全图([0,1])。
    private func runModel(rgbCrop: FloatImage, holeCrop: FloatImage) -> FloatImage? {
        guard let model = model else { return nil }
        let S = inputSize, cw = rgbCrop.width, ch = rgbCrop.height
        let rgbS = rgbCrop.resized(to: S, to: S)
        let holeS = holeCrop.resized(to: S, to: S)
        // image[1,3,512,512] RGB [0,255]，planar；mask[1,1,512,512] 255=已知/0=洞。
        guard let imgArr = try? MLMultiArray(shape: [1, 3, S, S] as [NSNumber], dataType: .float32),
              let mskArr = try? MLMultiArray(shape: [1, 1, S, S] as [NSNumber], dataType: .float32) else { return nil }
        let ip = imgArr.dataPointer.assumingMemoryBound(to: Float32.self)
        let mp = mskArr.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = S * S
        for p in 0..<plane {
            ip[0 * plane + p] = rgbS.pixels[p * 3 + 0] * 255
            ip[1 * plane + p] = rgbS.pixels[p * 3 + 1] * 255
            ip[2 * plane + p] = rgbS.pixels[p * 3 + 2] * 255
            mp[p] = holeS.pixels[p] > 0.5 ? 0 : 255      // Arcus hole(1=洞) → MI-GAN mask(255=已知/0=洞)
        }
        guard let prov = try? MLDictionaryFeatureProvider(dictionary: ["image": imgArr, "mask": mskArr]),
              let out = try? model.prediction(from: prov),
              let arr = out.featureValue(for: "result")?.multiArrayValue else {
            NSLog("[MiGAN] Inference failed, falling back to PatchMatch")
            return nil
        }
        let op = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        var filledS = FloatImage(width: S, height: S, channels: 3)
        for p in 0..<plane {
            filledS.pixels[p * 3 + 0] = min(1, max(0, op[0 * plane + p] / 255))
            filledS.pixels[p * 3 + 1] = min(1, max(0, op[1 * plane + p] / 255))
            filledS.pixels[p * 3 + 2] = min(1, max(0, op[2 * plane + p] / 255))
        }
        return filledS.resized(to: cw, to: ch)
    }
}
