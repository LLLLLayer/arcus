import Foundation
import CoreGraphics
import Metal

/// 行主序的浮点图像缓冲（值域约定 0…1）。
/// 一次性管线（深度归一化、定向、去遮挡补全）全部在这上面跑，逻辑直白可推理。
struct FloatImage {
    var width: Int
    var height: Int
    var channels: Int          // 1 = 标量(深度/mask)，3/4 = 颜色
    var pixels: [Float]        // count = width * height * channels

    init(width: Int, height: Int, channels: Int, repeating value: Float = 0) {
        self.width = width
        self.height = height
        self.channels = channels
        self.pixels = [Float](repeating: value, count: max(1, width * height * channels))
    }

    init(width: Int, height: Int, channels: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * channels, "FloatImage size does not match data")
        self.width = width
        self.height = height
        self.channels = channels
        self.pixels = pixels
    }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int {
        (y * width + x) * channels
    }

    @inline(__always) func clampedSample(_ x: Int, _ y: Int, _ c: Int) -> Float {
        let xx = min(max(x, 0), width - 1)
        let yy = min(max(y, 0), height - 1)
        return pixels[(yy * width + xx) * channels + c]
    }

    // MARK: - 从 CGImage 读入 (RGBA, 0…1, gamma-encoded)
    // 用 noneSkipLast：把输入当作不透明照片读其直通 RGB（alpha 通道由分割 mask 另行决定），
    // 避免预乘 RGB 流入非预乘合成。创建失败时返回全零图，绝不崩。
    static func fromCGImage(_ cg: CGImage, width: Int, height: Int) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return out }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return out }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let inv: Float = 1.0 / 255.0
        for i in 0..<(width * height * 4) {
            out.pixels[i] = Float(bytes[i]) * inv
        }
        return out
    }

    // MARK: - 输出为 CGImage (用于调试 / 导出)
    func toCGImage() -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if channels == 1 {
            for p in 0..<(width * height) {
                let v = UInt8(max(0, min(1, pixels[p])) * 255)
                bytes[p * 4 + 0] = v; bytes[p * 4 + 1] = v
                bytes[p * 4 + 2] = v; bytes[p * 4 + 3] = 255
            }
        } else {
            for p in 0..<(width * height) {
                let base = p * channels
                bytes[p * 4 + 0] = UInt8(max(0, min(1, pixels[base + 0])) * 255)
                bytes[p * 4 + 1] = UInt8(max(0, min(1, pixels[base + 1])) * 255)
                bytes[p * 4 + 2] = UInt8(max(0, min(1, pixels[base + 2])) * 255)
                let a = channels >= 4 ? pixels[base + 3] : 1
                bytes[p * 4 + 3] = UInt8(max(0, min(1, a)) * 255)
            }
        }
        guard let ctx = CGContext(data: &bytes,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: - 双线性缩放（unsafe 指针，避免方法调用开销）
    func resized(to newW: Int, to newH: Int) -> FloatImage {
        if newW == width && newH == height { return self }
        let w = width, h = height, ch = channels
        var out = [Float](repeating: 0, count: newW * newH * ch)
        let sx = Float(w) / Float(newW)
        let sy = Float(h) / Float(newH)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<newH {
                    let fy = (Float(y) + 0.5) * sy - 0.5
                    let y0 = Int(floor(fy)); let ty = fy - Float(y0)
                    let y0c = min(max(y0, 0), h - 1)
                    let y1c = min(max(y0 + 1, 0), h - 1)
                    for x in 0..<newW {
                        let fx = (Float(x) + 0.5) * sx - 0.5
                        let x0 = Int(floor(fx)); let tx = fx - Float(x0)
                        let x0c = min(max(x0, 0), w - 1)
                        let x1c = min(max(x0 + 1, 0), w - 1)
                        let i00 = (y0c * w + x0c) * ch, i10 = (y0c * w + x1c) * ch
                        let i01 = (y1c * w + x0c) * ch, i11 = (y1c * w + x1c) * ch
                        let o = (y * newW + x) * ch
                        for c in 0..<ch {
                            let top = src[i00 + c] + (src[i10 + c] - src[i00 + c]) * tx
                            let bot = src[i01 + c] + (src[i11 + c] - src[i01 + c]) * tx
                            dst[o + c] = top + (bot - top) * ty
                        }
                    }
                }
            }
        }
        return FloatImage(width: newW, height: newH, channels: ch, pixels: out)
    }

    /// 裁剪子区域（clamp 到边界）。
    func cropped(x: Int, y: Int, w: Int, h: Int) -> FloatImage {
        var out = FloatImage(width: w, height: h, channels: channels)
        for j in 0..<h {
            let sy = min(max(y + j, 0), height - 1)
            for i in 0..<w {
                let sx = min(max(x + i, 0), width - 1)
                let si = (sy * width + sx) * channels
                let di = (j * w + i) * channels
                for c in 0..<channels { out.pixels[di + c] = pixels[si + c] }
            }
        }
        return out
    }

    /// 抽取单通道为标量图。
    func channel(_ c: Int) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 1)
        for p in 0..<(width * height) {
            out.pixels[p] = pixels[p * channels + min(c, channels - 1)]
        }
        return out
    }

    /// 写入某通道（self 必须有该通道）。
    mutating func setChannel(_ c: Int, from scalar: FloatImage) {
        precondition(scalar.channels == 1 && scalar.width == width && scalar.height == height)
        for p in 0..<(width * height) {
            pixels[p * channels + c] = scalar.pixels[p]
        }
    }

    // MARK: - 形态学膨胀（标量, 半径 r 的方框最大值, 可分离）
    func dilated(radius r: Int) -> FloatImage {
        precondition(channels == 1)
        if r <= 0 { return self }
        var tmp = FloatImage(width: width, height: height, channels: 1)
        // 水平
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for dx in -r...r { m = max(m, clampedSample(x + dx, y, 0)) }
                tmp.pixels[y * width + x] = m
            }
        }
        // 垂直
        var out = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for dy in -r...r { m = max(m, tmp.clampedSample(x, y + dy, 0)) }
                out.pixels[y * width + x] = m
            }
        }
        return out
    }

    /// 形态学腐蚀（标量, 半径 r 的方框最小值, 可分离）。用于求"洞内侧"环带。
    func eroded(radius r: Int) -> FloatImage {
        precondition(channels == 1)
        if r <= 0 { return self }
        var tmp = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 1
                for dx in -r...r { m = min(m, clampedSample(x + dx, y, 0)) }
                tmp.pixels[y * width + x] = m
            }
        }
        var out = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 1
                for dy in -r...r { m = min(m, tmp.clampedSample(x, y + dy, 0)) }
                out.pixels[y * width + x] = m
            }
        }
        return out
    }

    /// 3×3 中值滤波（标量）：边缘保持式去噪，替代会糊掉深度断层的方框模糊。
    func median3() -> FloatImage {
        precondition(channels == 1)
        var out = FloatImage(width: width, height: height, channels: 1)
        var v = [Float](repeating: 0, count: 9)
        for y in 0..<height {
            for x in 0..<width {
                var k = 0
                for dy in -1...1 { for dx in -1...1 { v[k] = clampedSample(x + dx, y + dy, 0); k += 1 } }
                // 部分排序取中位（9 个元素，选择法到第 5 个即可）。
                for i in 0...4 {
                    var mi = i
                    for j in (i+1)..<9 where v[j] < v[mi] { mi = j }
                    if mi != i { v.swapAt(i, mi) }
                }
                out.pixels[y * width + x] = v[4]
            }
        }
        return out
    }

    /// 高斯近似（多次方框模糊），标量, 用于柔化 mask / 深度。unsafe 指针实现。
    func boxBlurred(radius r: Int, passes: Int = 2) -> FloatImage {
        precondition(channels == 1)
        if r <= 0 { return self }
        let w = width, h = height
        let norm = 1.0 / Float(2 * r + 1)
        var cur = pixels
        var tmp = [Float](repeating: 0, count: w * h)
        for _ in 0..<passes {
            cur.withUnsafeBufferPointer { src in
                tmp.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = y * w
                        for x in 0..<w {
                            var s: Float = 0
                            var xi = x - r
                            for _ in 0...(2 * r) {
                                let c = xi < 0 ? 0 : (xi >= w ? w - 1 : xi)
                                s += src[row + c]; xi += 1
                            }
                            dst[row + x] = s * norm
                        }
                    }
                }
            }
            tmp.withUnsafeBufferPointer { src in
                cur.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        for x in 0..<w {
                            var s: Float = 0
                            var yi = y - r
                            for _ in 0...(2 * r) {
                                let c = yi < 0 ? 0 : (yi >= h ? h - 1 : yi)
                                s += src[c * w + x]; yi += 1
                            }
                            dst[y * w + x] = s * norm
                        }
                    }
                }
            }
        }
        return FloatImage(width: w, height: h, channels: 1, pixels: cur)
    }

    /// Guided filter（He et al.）精修：用 guide(1ch) 把 self(1ch, 视作 P) 对齐到 guide 的边缘，
    /// 用于把主体 mask 贴合发丝/边界、改善半透明区。radius 越大越平滑，eps 越小越贴边。
    func guidedRefined(guide: FloatImage, radius: Int, eps: Float) -> FloatImage {
        precondition(channels == 1 && guide.channels == 1 && guide.width == width && guide.height == height)
        let n = width * height
        let I = guide, P = self
        var II = FloatImage(width: width, height: height, channels: 1)
        var IP = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<n { II.pixels[i] = I.pixels[i] * I.pixels[i]; IP.pixels[i] = I.pixels[i] * P.pixels[i] }
        let meanI = I.boxBlurred(radius: radius, passes: 1)
        let meanP = P.boxBlurred(radius: radius, passes: 1)
        let meanII = II.boxBlurred(radius: radius, passes: 1)
        let meanIP = IP.boxBlurred(radius: radius, passes: 1)
        var a = FloatImage(width: width, height: height, channels: 1)
        var b = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<n {
            let varI = meanII.pixels[i] - meanI.pixels[i] * meanI.pixels[i]
            let covIP = meanIP.pixels[i] - meanI.pixels[i] * meanP.pixels[i]
            let ai = covIP / (varI + eps)
            a.pixels[i] = ai
            b.pixels[i] = meanP.pixels[i] - ai * meanI.pixels[i]
        }
        let meanA = a.boxBlurred(radius: radius, passes: 1)
        let meanB = b.boxBlurred(radius: radius, passes: 1)
        var q = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<n { q.pixels[i] = min(1, max(0, meanA.pixels[i] * I.pixels[i] + meanB.pixels[i])) }
        return q
    }

    /// 滑窗 box 均值（O(n)，与半径无关；clamp 边界）。供彩色 guided filter 高效求各阶矩。
    private static func boxMean(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        if r <= 0 { return src }
        let win = Float(2 * r + 1)
        var tmp = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { d in
                for y in 0..<h {
                    let row = y * w
                    var sum: Float = 0
                    for k in -r...r { sum += s[row + min(max(k, 0), w - 1)] }
                    d[row] = sum / win
                    for x in 1..<w {
                        sum += s[row + min(x + r, w - 1)] - s[row + max(x - r - 1, 0)]
                        d[row + x] = sum / win
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for x in 0..<w {
                    var sum: Float = 0
                    for k in -r...r { sum += s[min(max(k, 0), h - 1) * w + x] }
                    d[x] = sum / win
                    for y in 1..<h {
                        sum += s[min(y + r, h - 1) * w + x] - s[max(y - r - 1, 0) * w + x]
                        d[y * w + x] = sum / win
                    }
                }
            }
        }
        return out
    }

    /// 彩色（RGB 三通道）引导的 guided filter（He et al. matting 版）。
    /// 比单亮度强：在「亮度相近但颜色不同」的低对比边界（如浅灰杯/浅灰墙带一点色差）也能把 mask
    /// 吸附到真实边缘；在完全无边的平坦区 a→0 ⇒ 退化为局部均值，自动把低分辨率台阶磨成平滑斜坡。
    /// guide 须 3/4 通道彩色图，self 为 1ch mask。半径用滑窗均值 ⇒ 取大也不变慢。
    func guidedRefinedColor(guide color: FloatImage, radius: Int, eps: Float) -> FloatImage {
        precondition(channels == 1 && color.channels >= 3 && color.width == width && color.height == height)
        let w = width, h = height, n = w * h, cc = color.channels, r = max(1, radius)
        var Ir = [Float](repeating: 0, count: n), Ig = Ir, Ib = Ir
        let P = pixels
        for i in 0..<n { Ir[i] = color.pixels[i * cc]; Ig[i] = color.pixels[i * cc + 1]; Ib[i] = color.pixels[i * cc + 2] }
        func mean(_ a: [Float]) -> [Float] { Self.boxMean(a, w, h, r) }
        let mIr = mean(Ir), mIg = mean(Ig), mIb = mean(Ib), mP = mean(P)
        var Irr = [Float](repeating: 0, count: n), Irg = Irr, Irb = Irr, Igg = Irr, Igb = Irr, Ibb = Irr
        var IrP = Irr, IgP = Irr, IbP = Irr
        for i in 0..<n {
            let rr = Ir[i], gg = Ig[i], bb = Ib[i], p = P[i]
            Irr[i] = rr * rr; Irg[i] = rr * gg; Irb[i] = rr * bb
            Igg[i] = gg * gg; Igb[i] = gg * bb; Ibb[i] = bb * bb
            IrP[i] = rr * p; IgP[i] = gg * p; IbP[i] = bb * p
        }
        let mIrr = mean(Irr), mIrg = mean(Irg), mIrb = mean(Irb)
        let mIgg = mean(Igg), mIgb = mean(Igb), mIbb = mean(Ibb)
        let mIrP = mean(IrP), mIgP = mean(IgP), mIbP = mean(IbP)
        var ar = [Float](repeating: 0, count: n), ag = ar, ab = ar, bcoef = ar
        for i in 0..<n {
            let cr = mIrP[i] - mIr[i] * mP[i]
            let cg = mIgP[i] - mIg[i] * mP[i]
            let cb = mIbP[i] - mIb[i] * mP[i]
            // 方差矩阵（对称）+ eps·I
            let vrr = mIrr[i] - mIr[i] * mIr[i] + eps
            let vrg = mIrg[i] - mIr[i] * mIg[i]
            let vrb = mIrb[i] - mIr[i] * mIb[i]
            let vgg = mIgg[i] - mIg[i] * mIg[i] + eps
            let vgb = mIgb[i] - mIg[i] * mIb[i]
            let vbb = mIbb[i] - mIb[i] * mIb[i] + eps
            // 解 3×3 对称线性系统 (V) a = c（伴随矩阵 / 行列式）
            let inv00 = vgg * vbb - vgb * vgb
            let inv01 = vgb * vrb - vrg * vbb
            let inv02 = vrg * vgb - vrb * vgg
            let inv11 = vrr * vbb - vrb * vrb
            let inv12 = vrg * vrb - vrr * vgb
            let inv22 = vrr * vgg - vrg * vrg
            let det = vrr * inv00 + vrg * inv01 + vrb * inv02
            if abs(det) > 1e-12 {
                let idet = 1 / det
                ar[i] = (inv00 * cr + inv01 * cg + inv02 * cb) * idet
                ag[i] = (inv01 * cr + inv11 * cg + inv12 * cb) * idet
                ab[i] = (inv02 * cr + inv12 * cg + inv22 * cb) * idet
            }
            bcoef[i] = mP[i] - ar[i] * mIr[i] - ag[i] * mIg[i] - ab[i] * mIb[i]
        }
        let mar = mean(ar), mag = mean(ag), mab = mean(ab), mb = mean(bcoef)
        var q = FloatImage(width: w, height: h, channels: 1)
        for i in 0..<n {
            q.pixels[i] = min(1, max(0, mar[i] * Ir[i] + mag[i] * Ig[i] + mab[i] * Ib[i] + mb[i]))
        }
        return q
    }

    /// 取 RGBA/RGB 的亮度作为单通道引导图。
    func luminance() -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 1)
        for p in 0..<(width * height) {
            let base = p * channels
            out.pixels[p] = 0.299 * pixels[base] + 0.587 * pixels[base + 1] + 0.114 * pixels[base + 2]
        }
        return out
    }

    // MARK: - 上传到 Metal 纹理
    /// RGBA 颜色 → rgba8Unorm。channels 须为 3 或 4。分配失败返回 nil。
    func uploadColorTexture(_ ctx: MetalContext = .shared) -> MTLTexture? {
        precondition(channels >= 3, "uploadColorTexture requires 3 or 4 channels")
        guard width > 0, height > 0, let tex = ctx.makeColorTexture(width: width, height: height) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for p in 0..<(width * height) {
            let base = p * channels
            bytes[p * 4 + 0] = UInt8(max(0, min(1, pixels[base + 0])) * 255)
            bytes[p * 4 + 1] = UInt8(max(0, min(1, pixels[base + (channels > 1 ? 1 : 0)])) * 255)
            bytes[p * 4 + 2] = UInt8(max(0, min(1, pixels[base + (channels > 2 ? 2 : 0)])) * 255)
            let a = channels >= 4 ? pixels[base + 3] : 1
            bytes[p * 4 + 3] = UInt8(max(0, min(1, a)) * 255)
        }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: width * 4)
        }
        return tex
    }

    /// 标量 → r16Float（支持线性过滤）。分配失败返回 nil。
    func uploadScalarTexture(_ ctx: MetalContext = .shared) -> MTLTexture? {
        precondition(channels == 1)
        guard width > 0, height > 0, let tex = ctx.makeScalarTexture(width: width, height: height) else { return nil }
        var halfs = [Float16](repeating: 0, count: width * height)
        for i in 0..<(width * height) { halfs[i] = Float16(pixels[i]) }
        halfs.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: width * 2)
        }
        return tex
    }
}
