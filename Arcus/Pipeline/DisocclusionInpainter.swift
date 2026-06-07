import Foundation

/// 去遮挡补全：用金字塔 push-pull（Gortler 1996 风格）把主体所在的洞，
/// 由周围背景平滑外推填满。颜色与深度通用。
/// 一次性运行，CPU O(n)，逻辑完全确定、可推理。
enum DisocclusionInpainter {

    private struct Level {
        var w: Int
        var h: Int
        var color: [Float]   // w*h*ch
        var weight: [Float]  // w*h
    }

    /// 最近有效像素填充（Jump Flooding Algorithm, Rong & Tan 2006）：
    /// 每个洞像素复制其「最近的已知背景像素」颜色。相比 push-pull 的金字塔扩散（会糊），
    /// 它是「直接复制真实像素」→ 锐利、纹理真实，且只用真实背景色（绝不产生彩虹）。
    /// 露出的去遮挡窄带紧贴剪影，最近背景就在旁边 → 看起来像背景自然延续。
    /// O(n·log(maxDim))，一次性可接受。
    static func nearestValidFill(_ image: FloatImage, valid: FloatImage) -> FloatImage {
        precondition(valid.channels == 1 && valid.width == image.width && valid.height == image.height)
        let w = image.width, h = image.height, ch = image.channels, n = w * h
        // 每像素记录「最近种子(已知像素)」的坐标。
        var sx = [Int32](repeating: -1, count: n)
        var sy = [Int32](repeating: -1, count: n)
        for p in 0..<n where valid.pixels[p] > 0.5 {
            sx[p] = Int32(p % w); sy[p] = Int32(p / w)
        }
        var tx = sx, ty = sy
        var step = 1
        while step < max(w, h) { step <<= 1 }
        step >>= 1
        while step >= 1 {
            let offs = [-step, 0, step]
            sx.withUnsafeBufferPointer { sxp in sy.withUnsafeBufferPointer { syp in
                tx.withUnsafeMutableBufferPointer { txp in ty.withUnsafeMutableBufferPointer { typ in
                    for y in 0..<h {
                        for x in 0..<w {
                            let p = y * w + x
                            var bsx = sxp[p], bsy = syp[p]
                            var bestD = bsx < 0 ? Int.max
                                : (x - Int(bsx)) * (x - Int(bsx)) + (y - Int(bsy)) * (y - Int(bsy))
                            for dy in offs {
                                let yy = y + dy; if yy < 0 || yy >= h { continue }
                                let row = yy * w
                                for dx in offs {
                                    let xx = x + dx; if xx < 0 || xx >= w { continue }
                                    let q = row + xx
                                    let qsx = sxp[q]; if qsx < 0 { continue }
                                    let qsy = syp[q]
                                    let d = (x - Int(qsx)) * (x - Int(qsx)) + (y - Int(qsy)) * (y - Int(qsy))
                                    if d < bestD { bestD = d; bsx = qsx; bsy = qsy }
                                }
                            }
                            txp[p] = bsx; typ[p] = bsy
                        }
                    }
                }}
            }}
            swap(&sx, &tx); swap(&sy, &ty)
            step >>= 1
        }
        var out = image
        for p in 0..<n where valid.pixels[p] <= 0.5 && sx[p] >= 0 {
            let q = Int(sy[p]) * w + Int(sx[p])
            for c in 0..<ch { out.pixels[p * ch + c] = image.pixels[q * ch + c] }
        }
        return out
    }

    /// 把 valid==0 的像素补全。
    /// - image: 任意通道 FloatImage
    /// - valid: 1ch，1=已知（保留），0=待填
    static func pushPullFill(_ image: FloatImage, valid: FloatImage) -> FloatImage {
        precondition(valid.channels == 1 && valid.width == image.width && valid.height == image.height)
        let ch = image.channels
        let w = image.width, h = image.height

        // Level 0
        var base = Level(w: w, h: h, color: image.pixels, weight: valid.pixels)
        // 把洞内的颜色清零（避免脏值参与），洞外保留。
        for p in 0..<(w * h) where base.weight[p] < 0.5 {
            for c in 0..<ch { base.color[p * ch + c] = 0 }
        }

        // PULL：自底向上构金字塔
        var levels: [Level] = [base]
        while levels.last!.w > 1 || levels.last!.h > 1 {
            levels.append(pull(levels.last!, ch: ch))
        }

        // PUSH：自顶向下回填
        var filled = levels.last!.color   // 顶层直接作为已填
        var filledW = levels.last!.w
        var filledH = levels.last!.h
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let fine = levels[l]
            var out = [Float](repeating: 0, count: fine.w * fine.h * ch)
            for y in 0..<fine.h {
                for x in 0..<fine.w {
                    let wf = fine.weight[y * fine.w + x]
                    let fi = (y * fine.w + x) * ch
                    if wf >= 0.999 {
                        for c in 0..<ch { out[fi + c] = fine.color[fi + c] }
                    } else {
                        // 从粗层双线性上采样
                        let cx = (Float(x) + 0.5) * 0.5 - 0.5
                        let cy = (Float(y) + 0.5) * 0.5 - 0.5
                        for c in 0..<ch {
                            let cval = bilinear(filled, filledW, filledH, ch, cx, cy, c)
                            out[fi + c] = wf * fine.color[fi + c] + (1 - wf) * cval
                        }
                    }
                }
            }
            filled = out
            filledW = fine.w
            filledH = fine.h
        }

        return FloatImage(width: w, height: h, channels: ch, pixels: filled)
    }

    // MARK: - PULL (downsample 2x, 加权平均)
    private static func pull(_ src: Level, ch: Int) -> Level {
        let cw = max(1, (src.w + 1) / 2)
        let chh = max(1, (src.h + 1) / 2)
        var color = [Float](repeating: 0, count: cw * chh * ch)
        var weight = [Float](repeating: 0, count: cw * chh)
        var sumC = [Float](repeating: 0, count: ch)   // 复用，避免每像素堆分配
        for cy in 0..<chh {
            for cx in 0..<cw {
                for c in 0..<ch { sumC[c] = 0 }
                var sumW: Float = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sx = cx * 2 + dx
                        let sy = cy * 2 + dy
                        if sx < src.w && sy < src.h {
                            let wgt = src.weight[sy * src.w + sx]
                            sumW += wgt
                            let si = (sy * src.w + sx) * ch
                            for c in 0..<ch { sumC[c] += wgt * src.color[si + c] }
                        }
                    }
                }
                let ci = (cy * cw + cx) * ch
                if sumW > 1e-6 {
                    for c in 0..<ch { color[ci + c] = sumC[c] / sumW }
                }
                weight[cy * cw + cx] = min(1, sumW * 0.25)
            }
        }
        return Level(w: cw, h: chh, color: color, weight: weight)
    }

    // MARK: - 双线性采样（clamp 边界）
    private static func bilinear(_ data: [Float], _ w: Int, _ h: Int, _ ch: Int,
                                 _ fx: Float, _ fy: Float, _ c: Int) -> Float {
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
            let xx = min(max(x, 0), w - 1)
            let yy = min(max(y, 0), h - 1)
            return data[(yy * w + xx) * ch + c]
        }
        let v00 = at(x0, y0), v10 = at(x0 + 1, y0)
        let v01 = at(x0, y0 + 1), v11 = at(x0 + 1, y0 + 1)
        let top = v00 + (v10 - v00) * tx
        let bot = v01 + (v11 - v01) * tx
        return top + (bot - top) * ty
    }
}
