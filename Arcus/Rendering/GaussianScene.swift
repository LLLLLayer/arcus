import Foundation
import Metal
import simd

/// 一颗 3D 高斯（与 GaussianShaders.metal 的 `GSplat` 内存布局严格对应）。
/// 全部用裸 `Float`（无 SIMD3 对齐填充）保证 Swift/Metal 两端 stride 一致（13×4=52 字节）。
/// 协方差以 3×3 对称阵上三角存储：[[c0 c1 c2],[c1 c3 c4],[c2 c4 c5]]（单位：世界空间²）。
struct GaussianSplat {
    var px: Float, py: Float, pz: Float       // 位置（相机规范世界系，+Z 朝场景）
    var c0: Float, c1: Float, c2: Float       // cov 行0
    var c3: Float, c4: Float, c5: Float       // cov 行1(c3=yy,c4=yz) + 行2(c5=zz)
    var r: Float, g: Float, b: Float          // 颜色（与 LDI 一致：直接存 sRGB 编码值 0…1）
    var opacity: Float                        // 0…1（前景=柔和 matte ⇒ 剪影软边抗锯齿）
}

/// 高斯泼溅场景：一块只读 splat 缓冲 + 渲染所需的合成相机参数。
/// 由 `GaussianSplatBuilder` 从端侧管线已算好的 FloatImage（前景主体 + 完整补全背景）直接 lift 出来——
/// 零新模型、全离线，这是相对 OpenReshot（1.23GiB 云端 SHARP）的底牌。
final class GaussianScene: @unchecked Sendable {
    let splatBuffer: MTLBuffer
    let count: Int
    let imageAspect: Float       // W/H：渲染按原图比例（cover 取景），保证 offset=0 即原图
    let fovY: Float              // 合成相机竖直视场角
    let pivotZ: Float            // 视差支点的世界 z（此深度处近乎锚定）
    let nearZ: Float
    let farZ: Float
    let depthNear: Float         // 场景实际深度范围（对焦/景深映射用）
    let depthFar: Float
    let suggestedParallax: Float

    init(splatBuffer: MTLBuffer, count: Int, imageAspect: Float,
         fovY: Float, pivotZ: Float, nearZ: Float, farZ: Float,
         depthNear: Float, depthFar: Float, suggestedParallax: Float) {
        self.splatBuffer = splatBuffer
        self.count = count
        self.imageAspect = imageAspect
        self.fovY = fovY
        self.pivotZ = pivotZ
        self.nearZ = nearZ
        self.farZ = farZ
        self.depthNear = depthNear
        self.depthFar = depthFar
        self.suggestedParallax = suggestedParallax
    }
}

/// 从管线 FloatImage 构建 3D 高斯（CPU，后台线程）。两层：
///  • 背景层：完整补全背景（bgColor+bgDisp）整幅采样 ⇒ 一张完整后景，相机移动时露出主体身后内容；
///  • 前景层：仅主体像素（matte>阈）采样，更近的深度 + 柔和 matte 当不透明度 ⇒ 真实去遮挡 + 软剪影。
/// 视差→深度用「逆深度」映射（disparity≈1/z 的物理直觉）：d=1→zNear，d=0→zFar。
/// 合成相机的规范视（offset=0）在投影上**精确复原原图**（焦距在投影里约掉），故 3DGS 与 LDI 起点一致。
enum GaussianSplatBuilder {

    static func build(color: FloatImage,      // rgba 原图
                      fgDisp: FloatImage,      // 1ch 前景视差(已平滑)
                      matte: FloatImage,       // 1ch 柔和主体 matte（前景不透明度）
                      bgColor: FloatImage,     // 3ch 补全背景
                      bgDisp: FloatImage,      // 1ch 背景视差
                      depthPivot: Float,
                      suggestedParallax: Float,
                      fgStride: Int = 2,
                      bgStride: Int = 2,
                      ctx: MetalContext = .shared) -> GaussianScene? {
        let W = color.width, H = color.height
        guard W > 1, H > 1, fgDisp.width == W, bgColor.width == W, bgDisp.width == W else { return nil }

        // 合成相机内参。fovY 只影响透视/视差强度——规范视的投影与焦距无关（焦距约掉），
        // 故 offset=0 恒复原原图（与 Arcus「offset=0 即原图」不变量一致）。
        let fovY: Float = 0.92                                    // ~52.7°
        let focal = Float(H) / (2 * tan(fovY / 2))                // 像素焦距（cx=W/2, cy=H/2）
        let halfW = Float(W) * 0.5, halfH = Float(H) * 0.5
        let zNear: Float = 1.0, zFar: Float = 4.0                 // 合成深度跨度（决定视差幅度）
        let invNear = 1 / zNear, invFar = 1 / zFar
        let flatZ: Float = 0.45                                   // 深度方向压扁系数：薄片表面锐利，但太薄(0.3)在斜视角会被拉成针状。
                                                                  // 0.45 让 splat 略厚 ⇒ 斜视角不易拉丝，规范视(offset=0,视向=+z)投影不变 ⇒ 原图依旧锐利。
        let sigmaScale: Float = 0.62                              // σ ≈ sigmaScale·采样间距 ⇒ 相邻 splat 轻微交叠无缝

        @inline(__always) func depthOf(_ d: Float) -> Float {
            1 / (max(0, min(1, d)) * (invNear - invFar) + invFar)
        }
        @inline(__always) func makeSplat(_ px: Int, _ py: Int, _ d: Float,
                                         _ r: Float, _ g: Float, _ b: Float,
                                         _ op: Float, _ stride: Int) -> GaussianSplat {
            let z = depthOf(d)
            let xc = (Float(px) + 0.5 - halfW) / focal * z
            let yc = -(Float(py) + 0.5 - halfH) / focal * z       // 图像 y 向下 ⇒ 世界 y 向上
            let sigma = sigmaScale * Float(stride) / focal * z
            let sxy2 = sigma * sigma
            let sz2 = (sigma * flatZ) * (sigma * flatZ)
            return GaussianSplat(px: xc, py: yc, pz: z,
                                 c0: sxy2, c1: 0, c2: 0, c3: sxy2, c4: 0, c5: sz2,
                                 r: r, g: g, b: b, opacity: op)
        }

        var splats = [GaussianSplat]()
        let bgCols = (W + bgStride - 1) / bgStride, bgRows = (H + bgStride - 1) / bgStride
        splats.reserveCapacity(bgCols * bgRows + (W * H) / (fgStride * fgStride) / 3)

        // ---- 背景层：整幅补全背景 ----
        var py = 0
        while py < H {
            var px = 0
            while px < W {
                let p = py * W + px
                splats.append(makeSplat(px, py, bgDisp.pixels[p],
                                        bgColor.pixels[p * 3 + 0], bgColor.pixels[p * 3 + 1], bgColor.pixels[p * 3 + 2],
                                        1.0, bgStride))
                px += bgStride
            }
            py += bgStride
        }

        // ---- 前景层：仅主体像素，matte 当不透明度（软剪影）----
        py = 0
        while py < H {
            var px = 0
            while px < W {
                let p = py * W + px
                let m = matte.pixels[p]
                if m > 0.04 {
                    splats.append(makeSplat(px, py, fgDisp.pixels[p],
                                            color.pixels[p * 4 + 0], color.pixels[p * 4 + 1], color.pixels[p * 4 + 2],
                                            min(1, m), fgStride))
                }
                px += fgStride
            }
            py += fgStride
        }

        guard !splats.isEmpty,
              let buf = ctx.device.makeBuffer(bytes: splats,
                                              length: splats.count * MemoryLayout<GaussianSplat>.stride,
                                              options: .storageModeShared)
        else { return nil }

        return GaussianScene(splatBuffer: buf, count: splats.count,
                             imageAspect: Float(W) / Float(H),
                             fovY: fovY, pivotZ: depthOf(depthPivot),
                             nearZ: 0.05, farZ: 50,
                             depthNear: zNear, depthFar: zFar,
                             suggestedParallax: suggestedParallax)
    }
}
