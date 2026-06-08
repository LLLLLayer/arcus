import Foundation
import Metal
import CoreGraphics
import simd

/// 端侧管线的烘焙产物：一张连续深度网格（前景在剪影处被切开 + 完整补全背景），
/// 供实时网格 warp 渲染器零拷贝使用。
/// offset=0 时合成 == 原图；移动相机时前景按"逐像素"深度连续位移（无分层环、无纸片感），
/// 剪影断层处的三角形被剔除，露出其后被补全的背景（窄环带，无大光晕）。
final class Photo3DScene: @unchecked Sendable {
    /// 背景再分层（可选）：把背景拆成「近景背景」中间层 + 「远景背景」打底层，
    /// 让背景自身也有视差与相互遮挡。开关打开时渲染器才用它。
    struct MultiLayer {
        let midColor: MTLTexture     // rgba8: rgb=原图, a=近景背景 matte
        let midDepth: MTLTexture     // r16f : 近景背景视差
        let midIndexBuffer: MTLBuffer
        let midIndexCount: Int
        let farColor: MTLTexture     // rgba8: 远景背景(主体+近景背景均已去除并填充)
        let farDepth: MTLTexture     // r16f : 远景背景视差
        let midCenter: SIMD2<Float>  // 近景背景质心(uv)，中间层「放大」的支点（盖住其身后远景的去遮挡带）
    }
    let multiLayer: MultiLayer?

    let width: Int
    let height: Int
    var aspect: Float { Float(width) / Float(height) }
    let fgCenter: SIMD2<Float>   // 主体质心(uv 0..1)，前景「整体放大」的支点

    // 纹理
    let fgColor: MTLTexture   // rgba8: rgb=原图, a=柔和主体 matte（边缘羽化）
    let depth: MTLTexture     // r16f : 真实逐像素视差 0…1 (1=近) —— 前景网格的几何源
    let bgColor: MTLTexture   // rgba8: 去除主体后"完整"补全的背景（可见环带 LaMa 锐补）
    let bgDepth: MTLTexture   // r16f : 主体区按"远侧"填充后的视差 —— 背景网格的几何源

    // 网格（共享顶点，前/背景各一套索引）
    let vertexBuffer: MTLBuffer   // float2 grid uv，行主序 gridW×gridH
    let gridW: Int
    let gridH: Int
    let bgIndexBuffer: MTLBuffer  // 完整网格（背景是连续整面）
    let bgIndexCount: Int
    let fgIndexBuffer: MTLBuffer  // 剪影/深度断层处剔除后的网格（前景）
    let fgIndexCount: Int

    let suggestedParallax: Float

    // 调试预览 & 来源信息
    let depthPreview: CGImage?
    let maskPreview: CGImage?
    let backgroundPreview: CGImage?
    let depthSource: String
    let segmentSource: String
    let inpaintSource: String

    init(width: Int, height: Int,
         fgColor: MTLTexture, depth: MTLTexture,
         bgColor: MTLTexture, bgDepth: MTLTexture,
         vertexBuffer: MTLBuffer, gridW: Int, gridH: Int,
         bgIndexBuffer: MTLBuffer, bgIndexCount: Int,
         fgIndexBuffer: MTLBuffer, fgIndexCount: Int,
         suggestedParallax: Float,
         depthPreview: CGImage?, maskPreview: CGImage?, backgroundPreview: CGImage?,
         depthSource: String, segmentSource: String, inpaintSource: String,
         fgCenter: SIMD2<Float> = SIMD2<Float>(0.5, 0.5),
         multiLayer: MultiLayer? = nil) {
        self.multiLayer = multiLayer
        self.fgCenter = fgCenter
        self.width = width
        self.height = height
        self.fgColor = fgColor
        self.depth = depth
        self.bgColor = bgColor
        self.bgDepth = bgDepth
        self.vertexBuffer = vertexBuffer
        self.gridW = gridW
        self.gridH = gridH
        self.bgIndexBuffer = bgIndexBuffer
        self.bgIndexCount = bgIndexCount
        self.fgIndexBuffer = fgIndexBuffer
        self.fgIndexCount = fgIndexCount
        self.suggestedParallax = suggestedParallax
        self.depthPreview = depthPreview
        self.maskPreview = maskPreview
        self.backgroundPreview = backgroundPreview
        self.depthSource = depthSource
        self.segmentSource = segmentSource
        self.inpaintSource = inpaintSource
    }
}
