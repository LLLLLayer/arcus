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

    /// 每像素「最近已知背景像素」的坐标（Jump Flooding, Rong & Tan 2006）。O(n·log(maxDim))。
    private static func nearestSeeds(_ valid: FloatImage) -> (sx: [Int32], sy: [Int32]) {
        let w = valid.width, h = valid.height, n = w * h
        var sx = [Int32](repeating: -1, count: n)
        var sy = [Int32](repeating: -1, count: n)
        for p in 0..<n where valid.pixels[p] > 0.5 { sx[p] = Int32(p % w); sy[p] = Int32(p / w) }
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
        return (sx, sy)
    }

    /// 纯最近有效像素填充（锐利，但凸轮廓会聚处会出现放射状「风车/星芒」接缝）。保留备用。
    static func nearestValidFill(_ image: FloatImage, valid: FloatImage) -> FloatImage {
        let (sx, sy) = nearestSeeds(valid)
        let w = image.width, ch = image.channels, n = image.width * image.height
        var out = image
        for p in 0..<n where valid.pixels[p] <= 0.5 && sx[p] >= 0 {
            let q = Int(sy[p]) * w + Int(sx[p])
            for c in 0..<ch { out.pixels[p * ch + c] = image.pixels[q * ch + c] }
        }
        return out
    }

    /// 竖直延续填充：每个洞像素沿「列」复制最近的已知背景像素(上/下)。
    /// 站立主体背后的背景多为竖直结构(树干/墙/天空) → 竖直延续最自然：锐利、无星芒、无灰带。
    /// 再把竖直填充产生的「横向突变」(横向结构被拉成竖条纹处)做轻微横向柔化，优雅降级。
    static func verticalFill(_ image: FloatImage, valid: FloatImage) -> FloatImage {
        let w = image.width, h = image.height, ch = image.channels, n = w * h
        // 每像素的「最近已知像素」行号：列向上 / 列向下，各一遍 O(n)。
        var upIdx = [Int32](repeating: -1, count: n)
        var dnIdx = [Int32](repeating: -1, count: n)
        for x in 0..<w {
            var last: Int32 = -1
            for y in 0..<h { let p = y * w + x; if valid.pixels[p] > 0.5 { last = Int32(y) }; upIdx[p] = last }
            last = -1
            var y = h - 1
            while y >= 0 { let p = y * w + x; if valid.pixels[p] > 0.5 { last = Int32(y) }; dnIdx[p] = last; y -= 1 }
        }
        var vfill = image
        for x in 0..<w {
            for y in 0..<h {
                let p = y * w + x
                if valid.pixels[p] > 0.5 { continue }
                let up = upIdx[p], dn = dnIdx[p]
                var src: Int32 = -1
                if up >= 0 && dn >= 0 { src = (y - Int(up)) <= (Int(dn) - y) ? up : dn }
                else if up >= 0 { src = up } else { src = dn }
                if src >= 0 { let q = Int(src) * w + x; for c in 0..<ch { vfill.pixels[p * ch + c] = image.pixels[q * ch + c] } }
            }
        }
        // 竖条纹去除：竖直填充在复杂结构(树冠等)处会拉出细竖条纹。检测「局部横向方差高」
        // (=条纹)的洞像素，按方差强度把它混向横向模糊；连贯竖直结构(单根树干)保持锐利。
        let r = max(3, w / 60)
        var blurH = vfill
        vfill.pixels.withUnsafeBufferPointer { src in
            blurH.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        for c in 0..<ch {
                            var s: Float = 0, cnt: Float = 0, i = -r
                            while i <= r { let xx = x + i; if xx >= 0 && xx < w { s += src[(row + xx) * ch + c]; cnt += 1 }; i += 1 }
                            dst[(row + x) * ch + c] = s / cnt
                        }
                    }
                }
            }
        }
        var out = vfill
        let vr = max(2, w / 100)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if valid.pixels[p] > 0.5 { continue }
                var m: Float = 0, m2: Float = 0, cnt: Float = 0, i = -vr
                while i <= vr {
                    let xx = x + i
                    if xx >= 0 && xx < w {
                        let q = (y * w + xx) * ch
                        let lum = 0.3 * vfill.pixels[q] + 0.59 * vfill.pixels[q + 1] + 0.11 * vfill.pixels[q + 2]
                        m += lum; m2 += lum * lum; cnt += 1
                    }
                    i += 1
                }
                let mean = m / cnt
                let std = (max(0, m2 / cnt - mean * mean)).squareRoot()
                let wgt = min(1, max(0, (std - 0.04) / 0.10))
                if wgt > 0.01 { for c in 0..<ch { out.pixels[p * ch + c] = vfill.pixels[p * ch + c] * (1 - wgt) + blurH.pixels[p * ch + c] * wgt } }
            }
        }
        return out
    }

    /// 接缝感知填充：在「连贯」处用最近有效像素（锐利、真实纹理），仅在「种子不连续的接缝」
    /// （纯最近会形成放射状星芒之处）切换为 push-pull 平滑扩散 → 既不糊、也无星芒。
    /// 实测优于纯最近(星芒)与纯 push-pull(糊)。
    static func seamAwareFill(_ image: FloatImage, valid: FloatImage) -> FloatImage {
        let w = image.width, h = image.height, ch = image.channels, n = w * h
        let (sx, sy) = nearestSeeds(valid)
        var nearest = image
        for p in 0..<n where valid.pixels[p] <= 0.5 && sx[p] >= 0 {
            let q = Int(sy[p]) * w + Int(sx[p])
            for c in 0..<ch { nearest.pixels[p * ch + c] = image.pixels[q * ch + c] }
        }
        let smooth = pushPullFill(image, valid: valid)
        // 接缝强度：相邻洞像素「种子坐标」跳变大处即为接缝(星芒边界)。
        var seam = FloatImage(width: w, height: h, channels: 1)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if valid.pixels[p] > 0.5 || sx[p] < 0 { continue }
                var m: Int32 = 0
                if x + 1 < w { let q = p + 1; if sx[q] >= 0 { m = max(m, abs(sx[p]-sx[q]) + abs(sy[p]-sy[q])) } }
                if y + 1 < h { let q = p + w; if sx[q] >= 0 { m = max(m, abs(sx[p]-sx[q]) + abs(sy[p]-sy[q])) } }
                seam.pixels[p] = m >= 4 ? 1 : 0
            }
        }
        // 膨胀覆盖星芒邻域 + 柔化成 0…1 过渡。
        let seamMask = seam.dilated(radius: max(6, w / 64)).boxBlurred(radius: max(5, w / 80), passes: 1)
        var out = nearest
        for p in 0..<n where valid.pixels[p] <= 0.5 {
            let wgt = min(1, max(0, seamMask.pixels[p]))
            for c in 0..<ch {
                out.pixels[p * ch + c] = nearest.pixels[p * ch + c] * (1 - wgt) + smooth.pixels[p * ch + c] * wgt
            }
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
