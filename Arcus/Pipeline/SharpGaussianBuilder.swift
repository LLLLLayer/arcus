import Foundation
import Metal
import simd

/// 把 SHARP 的 NDC 高斯（`SHARPModel.RawOutput`）lift 成 Arcus 渲染器吃的 `GaussianScene`。
///
/// 反投影是解析的对角阵（无需求逆/SVD）：以 Apple `gaussians.py` 的 unproject 推导，
/// `ndc_matrix · intrinsics` 化简为 `diag(2fx/1536, 2fy/1536, 1)`，其逆为 `diag(sx, sy, 1)`，
/// 其中 `sx = W/(2·f_px)`、`sy = H/(2·f_px)`、`f_px = 30mm 等效`（仅宽高比影响尺度）。
/// 再叠一个 y 翻转（OpenCV y-down → Arcus 世界 y-up）⇒ 线性变换 `D = diag(sx, -sy, 1)`：
///   mean_world = D · mean_ndc，   Σ_world = D · (R·diag(σ²)·Rᵀ) · Dᵀ（直接存上三角，渲染器吃协方差）。
/// 相机：`fovY = 2·atan(H/(2·f_px))`、`aspect = W/H` ⇒ 规范视(offset=0)复原原图。
enum SharpGaussianBuilder {

    static func build(_ raw: SHARPModel.RawOutput, ctx: MetalContext = .shared) -> GaussianScene? {
        let n = raw.count
        guard n > 0 else { return nil }
        let W = Float(raw.srcWidth), H = Float(raw.srcHeight)
        let fPx = 30.0 * Float((Double(W) * Double(W) + Double(H) * Double(H)).squareRoot())
                  / Float((36.0 * 36.0 + 24.0 * 24.0).squareRoot())
        let sx = W / (2 * fPx)
        let sy = H / (2 * fPx)
        let fovY = 2 * atan(sy)                 // = 2·atan(H/(2·f_px))

        var splats = [GaussianSplat](); splats.reserveCapacity(n)
        var zSamples = [Float](); zSamples.reserveCapacity(n / 256 + 16)
        var zMin = Float.greatestFiniteMagnitude, zMax: Float = 0

        raw.mean.withUnsafeBufferPointer { mean in
        raw.scale.withUnsafeBufferPointer { scl in
        raw.quat.withUnsafeBufferPointer { qt in
        raw.color.withUnsafeBufferPointer { col in
        raw.opacity.withUnsafeBufferPointer { op in
            for i in 0..<n {
                let opacity = op[i]
                if opacity < 0.02 { continue }              // 剔除几乎透明的高斯，省排序/绘制
                let m0 = i * 3, q0 = i * 4
                let mz = mean[m0 + 2]
                if !(mz.isFinite) || mz <= 0 { continue }   // 丢弃相机后方/非法点

                // 世界位置：D · mean_ndc，D = diag(sx, -sy, 1)
                let px = sx * mean[m0 + 0]
                let py = -sy * mean[m0 + 1]
                let pz = mz

                // 旋转矩阵（四元数 w-first，归一化）
                var qw = qt[q0 + 0], qx = qt[q0 + 1], qy = qt[q0 + 2], qz = qt[q0 + 3]
                let qn = (qw * qw + qx * qx + qy * qy + qz * qz).squareRoot()
                if qn > 1e-9 { qw /= qn; qx /= qn; qy /= qn; qz /= qn } else { qw = 1; qx = 0; qy = 0; qz = 0 }
                let r00 = 1 - 2 * (qy * qy + qz * qz), r01 = 2 * (qx * qy - qw * qz), r02 = 2 * (qx * qz + qw * qy)
                let r10 = 2 * (qx * qy + qw * qz), r11 = 1 - 2 * (qx * qx + qz * qz), r12 = 2 * (qy * qz - qw * qx)
                let r20 = 2 * (qx * qz - qw * qy), r21 = 2 * (qy * qz + qw * qx), r22 = 1 - 2 * (qx * qx + qy * qy)

                // Σ_ndc = R·diag(σ²)·Rᵀ（上三角）
                let a = scl[m0 + 0] * scl[m0 + 0] + 1e-12
                let b = scl[m0 + 1] * scl[m0 + 1] + 1e-12
                let c = scl[m0 + 2] * scl[m0 + 2] + 1e-12
                let s00 = r00 * r00 * a + r01 * r01 * b + r02 * r02 * c
                let s01 = r00 * r10 * a + r01 * r11 * b + r02 * r12 * c
                let s02 = r00 * r20 * a + r01 * r21 * b + r02 * r22 * c
                let s11 = r10 * r10 * a + r11 * r11 * b + r12 * r12 * c
                let s12 = r10 * r20 * a + r11 * r21 * b + r12 * r22 * c
                let s22 = r20 * r20 * a + r21 * r21 * b + r22 * r22 * c

                // Σ_world = D·Σ_ndc·Dᵀ，D = diag(sx, -sy, 1)
                let c0 = sx * sx * s00
                let c1 = -sx * sy * s01
                let c2 = sx * s02
                let c3 = sy * sy * s11
                let c4 = -sy * s12
                let c5 = s22

                // 颜色：SHARP 为 linearRGB → 渲染器存 sRGB 编码值
                let rr = lin2srgb(col[m0 + 0]), gg = lin2srgb(col[m0 + 1]), bb = lin2srgb(col[m0 + 2])

                // NaN/Inf 防线：σ/quat 出现非有限值会经协方差污染进 GPU buffer ⇒ 渲染崩坏。整颗丢弃。
                guard px.isFinite, py.isFinite, c0.isFinite, c1.isFinite, c2.isFinite,
                      c3.isFinite, c4.isFinite, c5.isFinite else { continue }

                splats.append(GaussianSplat(px: px, py: py, pz: pz,
                                            c0: c0, c1: c1, c2: c2, c3: c3, c4: c4, c5: c5,
                                            r: rr, g: gg, b: bb, opacity: min(1, opacity)))
                if pz < zMin { zMin = pz }
                if pz > zMax { zMax = pz }
                if i % 256 == 0 { zSamples.append(pz) }
            }
        }}}}}

        guard !splats.isEmpty, zMax > zMin else { return nil }
        zSamples.sort()
        let pivotZ = zSamples.isEmpty ? (zMin + zMax) * 0.5 : zSamples[zSamples.count / 2]

        guard let buf = ctx.device.makeBuffer(bytes: splats,
                                              length: splats.count * MemoryLayout<GaussianSplat>.stride,
                                              options: .storageModeShared) else { return nil }

        NSLog("[SHARP] built %d gaussians (from %d), z=[%.3f,%.3f] pivot=%.3f fovY=%.1f°",
              splats.count, n, zMin, zMax, pivotZ, fovY * 180 / .pi)

        return GaussianScene(splatBuffer: buf, count: splats.count,
                             imageAspect: W / H, fovY: fovY, pivotZ: pivotZ,
                             nearZ: max(0.02, zMin * 0.5), farZ: zMax * 3 + 1,
                             depthNear: zMin, depthFar: zMax,
                             suggestedParallax: 0.5)
    }

    @inline(__always) private static func lin2srgb(_ c: Float) -> Float {
        let x = max(0, min(1, c))
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
}
