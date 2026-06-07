import Foundation
import Metal
import simd

/// 构建实时 warp 用的三角网格：
///  • 共享顶点 = 图像上的规则 (u,v) 栅格（步长 K 像素）；
///  • 背景索引 = 完整网格（背景是一整面连续曲面）；
///  • 前景索引 = 剔除"跨深度断层"的四边形后的网格 —— 切开剪影，避免三角形在
///    主体/背景的深度悬崖上被拉成橡皮膜（糊状重影），切口处露出其后的补全背景。
enum MeshBuilder {

    struct Result {
        let vertexBuffer: MTLBuffer
        let gridW: Int
        let gridH: Int
        let bgIndexBuffer: MTLBuffer
        let bgIndexCount: Int
        let fgIndexBuffer: MTLBuffer
        let fgIndexCount: Int
    }

    /// - disparity: 逐像素视差(1ch, 1=近)，用于判断深度断层。
    /// - matte:     主体柔和 matte(1ch)，前景只画"有主体"的四边形。
    /// - stride:    顶点步长(像素)。越小越精细；A 系列 GPU K=2 足矣。
    /// - tauCut:    四边形 4 角视差极差超过此阈值即判为跨断层 → 前景剔除。
    static func build(width W: Int, height H: Int,
                      disparity: FloatImage, matte: FloatImage,
                      stride K: Int = 2, tauCut: Float = 0.05,
                      ctx: MetalContext = .shared) -> Result? {
        let gw = max(2, W / max(1, K) + 1)
        let gh = max(2, H / max(1, K) + 1)

        // 顶点 (u,v)，并预采样每个顶点的视差/matte（最近邻）。
        var verts = [SIMD2<Float>](repeating: .zero, count: gw * gh)
        var vDisp = [Float](repeating: 0, count: gw * gh)
        var vMatte = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            let v = Float(gy) / Float(gh - 1)
            let py = min(H - 1, Int(v * Float(H - 1) + 0.5))
            for gx in 0..<gw {
                let u = Float(gx) / Float(gw - 1)
                let px = min(W - 1, Int(u * Float(W - 1) + 0.5))
                let idx = gy * gw + gx
                verts[idx] = SIMD2<Float>(u, v)
                vDisp[idx] = disparity.pixels[py * W + px]
                vMatte[idx] = matte.pixels[py * W + px]
            }
        }

        var bgIdx = [UInt32](); bgIdx.reserveCapacity((gw - 1) * (gh - 1) * 6)
        var fgIdx = [UInt32](); fgIdx.reserveCapacity((gw - 1) * (gh - 1) * 6)
        for gy in 0..<(gh - 1) {
            for gx in 0..<(gw - 1) {
                let i00 = UInt32(gy * gw + gx)
                let i10 = UInt32(gy * gw + gx + 1)
                let i01 = UInt32((gy + 1) * gw + gx)
                let i11 = UInt32((gy + 1) * gw + gx + 1)
                // 背景：所有四边形。
                bgIdx.append(contentsOf: [i00, i10, i11, i00, i11, i01])

                // 前景：需"含主体"(任一角 matte>阈) 且"不跨断层"(视差极差≤tauCut)。
                let m0 = vMatte[Int(i00)], m1 = vMatte[Int(i10)], m2 = vMatte[Int(i01)], m3 = vMatte[Int(i11)]
                let maxM = max(max(m0, m1), max(m2, m3))
                if maxM > 0.04 {
                    let d0 = vDisp[Int(i00)], d1 = vDisp[Int(i10)], d2 = vDisp[Int(i01)], d3 = vDisp[Int(i11)]
                    let spread = max(max(d0, d1), max(d2, d3)) - min(min(d0, d1), min(d2, d3))
                    if spread <= tauCut {
                        fgIdx.append(contentsOf: [i00, i10, i11, i00, i11, i01])
                    }
                }
            }
        }

        guard let vb = ctx.device.makeBuffer(bytes: verts,
                                              length: verts.count * MemoryLayout<SIMD2<Float>>.stride,
                                              options: .storageModeShared),
              let bgb = ctx.device.makeBuffer(bytes: bgIdx.isEmpty ? [0] : bgIdx,
                                               length: max(1, bgIdx.count) * MemoryLayout<UInt32>.stride,
                                               options: .storageModeShared),
              let fgb = ctx.device.makeBuffer(bytes: fgIdx.isEmpty ? [0] : fgIdx,
                                               length: max(1, fgIdx.count) * MemoryLayout<UInt32>.stride,
                                               options: .storageModeShared)
        else { return nil }

        return Result(vertexBuffer: vb, gridW: gw, gridH: gh,
                      bgIndexBuffer: bgb, bgIndexCount: bgIdx.count,
                      fgIndexBuffer: fgb, fgIndexCount: fgIdx.count)
    }
}
