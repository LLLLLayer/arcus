import Foundation
import MetalKit
import simd

/// 与 Shaders.metal 的 MeshUniforms 内存布局严格对应。
struct MeshUniforms {
    var offset = SIMD2<Float>(0, 0)
    var viewScale = SIMD2<Float>(1, 1)
    var parallaxAmp: Float = 0.06
    var depthPivot: Float = 0.5
    var flatten: Float = 0
    var layerFactor: Float = 1       // warp 缩放：前景=1, 背景=bgParallaxFactor
    var fgFlag: Float = 1            // 1=前景(matte alpha), 0=背景(不透明)
    var fgScale: Float = 1          // 前景整体放大(支点=主体质心)，1=原尺寸
    var debugMode: Int32 = 0
    var fgCenter = SIMD2<Float>(0.5, 0.5)   // 主体质心(uv)，放大支点
}

/// 渲染可调参数（由 UI 绑定）。
struct ViewerParams {
    var parallaxAmp: Float = 0.04        // 3D 强度
    var bgParallaxFactor: Float = 0.5    // 背景跟随（陀螺转动时背景也明显移动，像 Apple 空间照片；多层背景给近/远不同位移=内部视差）
    var debugMode: Int32 = 0             // 0 正常,1 深度,2 主体,3 背景,4 重拍洞掩膜
    var motionEnabled: Bool = true
    var autoAnimate: Bool = false
    var multiLayerBg: Bool = true        // 背景再分层（近景背景中间层 + 远景背景打底）：默认开启
    var fgScale: Float = 1.05            // 前景整体放大(1=原尺寸)：放大主体盖住身后的去遮挡过渡带
    var reframeMode: Bool = false        // 「重拍」入口：拖动=移机位(大范围、不回弹)，双指=缩放；默认 false ⇒ 普通查看完全不受影响
    var fitImage: Bool = true            // true=按原图比例完整展示(letterbox，不裁切)；false=cover 撑满裁切(重拍沉浸态用)
    var frameBars: Bool = false          // 「出框」：背景与前景之间夹一对屏幕空间静止白条，主体随视差跨到条前 ⇒ 裸眼 3D 出框感

    // ===== 高斯泼溅「镜头」（仅 3DGS 渲染读取；LDI 忽略）=====
    var gsDolly: Float = 0               // 推轨「前景前后移动」：-1 拉远…+1 推近（带 FOV 反向补偿=希区柯克变焦）
    var gsFocus: Float = 0.5             // 对焦深度：0 近(主体)…1 远(背景)
    var gsFNumber: Float = 16            // 光圈 f 值：1.4 浅景深大虚化…16 全清晰(景深关)
}

/// Metal 连续深度网格 warp 渲染器（2 层软 LDI，无深度缓冲——靠绘制顺序 + 剪影切口处理遮挡）：
///  1) 背景：完整连续网格，按逐像素背景深度位移（平滑背景视差，无分层环）；
///  2) 前景：主体网格（剪影/深度断层处切开），按真实逐像素深度位移（主体内部有真实视差，
///     无纸片感），柔和 matte 以 over 混合叠加（无边缘镶边）。
final class ParallaxRenderer: NSObject, MTKViewDelegate {

    static let sampleCount = 4   // 4× MSAA：抗锯齿前景剪影切口（与 MTKView.sampleCount 一致）

    /// 与 Shaders.metal 的 BarUniforms 对应：「出框」画框条（NDC rect + 预乘色）。
    private struct BarUniforms {
        var rect: SIMD4<Float>    // x=左, y=下, z=右, w=上
        var color: SIMD4<Float>
    }

    private let ctx = MetalContext.shared
    private var opaqueState: MTLRenderPipelineState!   // 背景：不透明
    private var blendState: MTLRenderPipelineState!    // 前景：预乘 over
    private var barState: MTLRenderPipelineState!      // 「出框」画框条：预乘 over
    private var viewportSize = CGSize(width: 1, height: 1)

    var scene: Photo3DScene?
    var params = ViewerParams()
    let motion = MotionController()

    var panOffset = SIMD2<Float>(0, 0)
    var isPanning = false
    var zoomLevel: Float = 1            // 「重拍」双指缩放，乘到 viewScale；普通查看恒为 1（updateUIView 强制复位）

    private var frame: Int = 0
    private var offscreenMSAA: MTLTexture?   // 离屏渲染的 MSAA 附件缓存：导出逐帧渲染时复用（1080p 单张 ~33MB，不能每帧新建）

    init(pixelFormat: MTLPixelFormat) {
        super.init()
        // 守住 Swift↔Metal 内存布局契约（不符会无声渲染错乱）：fgCenter@48、stride 56。
        assert(MemoryLayout<MeshUniforms>.stride == 56
               && MemoryLayout<MeshUniforms>.offset(of: \.fgCenter) == 48,
               "MeshUniforms layout must match Shaders.metal (fgCenter@48, stride 56)")
        buildPipelines(pixelFormat: pixelFormat)
    }

    private func buildPipelines(pixelFormat: MTLPixelFormat) {
        let vfn = ctx.library.makeFunction(name: "mesh_vertex")
        let ffn = ctx.library.makeFunction(name: "mesh_fragment")
        do {
            let d1 = MTLRenderPipelineDescriptor()
            d1.vertexFunction = vfn
            d1.fragmentFunction = ffn
            d1.rasterSampleCount = Self.sampleCount
            d1.colorAttachments[0].pixelFormat = pixelFormat
            opaqueState = try ctx.device.makeRenderPipelineState(descriptor: d1)

            let d2 = MTLRenderPipelineDescriptor()
            d2.vertexFunction = vfn
            d2.fragmentFunction = ffn
            d2.rasterSampleCount = Self.sampleCount
            let a = d2.colorAttachments[0]!
            a.pixelFormat = pixelFormat
            a.isBlendingEnabled = true                       // premultiplied over
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendState = try ctx.device.makeRenderPipelineState(descriptor: d2)

            let d3 = MTLRenderPipelineDescriptor()
            d3.vertexFunction = ctx.library.makeFunction(name: "bar_vertex")
            d3.fragmentFunction = ctx.library.makeFunction(name: "bar_fragment")
            d3.rasterSampleCount = Self.sampleCount
            let b = d3.colorAttachments[0]!
            b.pixelFormat = pixelFormat
            b.isBlendingEnabled = true
            b.rgbBlendOperation = .add
            b.alphaBlendOperation = .add
            b.sourceRGBBlendFactor = .one
            b.sourceAlphaBlendFactor = .one
            b.destinationRGBBlendFactor = .oneMinusSourceAlpha
            b.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            barState = try ctx.device.makeRenderPipelineState(descriptor: d3)
        } catch {
            fatalError("Failed to create render pipeline: \(error)")
        }
    }

    // MARK: - 偏移合成

    private func currentOffset() -> SIMD2<Float> {
        if !isPanning && !params.reframeMode { panOffset *= 0.88 }   // 重拍：保持所选机位不回弹
        var off = panOffset
        if params.motionEnabled { off += motion.sample() }
        if params.autoAnimate {
            let t = Float(frame) * 0.025
            off += SIMD2<Float>(sin(t) * 0.7, cos(t * 0.8) * 0.45)
        }
        return simd_clamp(off, SIMD2<Float>(-1.0, -1.0), SIMD2<Float>(1.0, 1.0))
    }

    /// 几何缩放：把图像方格放进视口且**保持原图比例**（不拉伸）。
    /// - fit（默认）：保持原图比例(4:3 不被拉成 16:9)，但**稍作放大裁切(overscan)**给视差留边——
    ///   这样陀螺/拖拽时画面边缘不会露出黑边、画框保持满幅静止，体验更稳。
    /// - cover（重拍沉浸态）：撑满视口、溢出轴裁掉。
    private func viewScale(imageAspect: Float) -> SIMD2<Float> {
        let viewAspect = Float(max(viewportSize.width, 1) / max(viewportSize.height, 1))
        let r = imageAspect / viewAspect
        var sx: Float = 1, sy: Float = 1
        let overscan: Float = 1.06   // 稍微放大裁切：盖住视差移动露出的边，画框保持满幅静止
        if params.fitImage {
            // fit：缩小较长的那个轴使整图入框（与 cover 的分支相反），再乘 overscan 留视差边
            if r >= 1 { sx = 1; sy = 1 / r } else { sx = r; sy = 1 }
            return SIMD2<Float>(sx * overscan * zoomLevel, sy * overscan * zoomLevel)
        } else {
            if r >= 1 { sx = r; sy = 1 } else { sx = 1; sy = 1 / r }
            return SIMD2<Float>(sx * overscan * zoomLevel, sy * overscan * zoomLevel)
        }
    }

    private func makeUniforms(offset: SIMD2<Float>) -> MeshUniforms {
        var u = MeshUniforms()
        u.offset = offset
        u.parallaxAmp = params.parallaxAmp
        u.depthPivot = scene?.depthPivot ?? 0.5   // 自适应：偏向主体深度 ⇒ 主体锚定、深层背景扫动(运镜)
        u.debugMode = params.debugMode
        u.viewScale = viewScale(imageAspect: scene?.aspect ?? 1)
        return u
    }

    // MARK: - 编码

    private func encode(scene: Photo3DScene, uniforms: MeshUniforms,
                        descriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encodeMesh(scene: scene, uniforms: uniforms, enc: enc)
        enc.endEncoding()
    }

    private func encodeMesh(scene: Photo3DScene, uniforms: MeshUniforms, enc: MTLRenderCommandEncoder) {
        let stride = MemoryLayout<MeshUniforms>.stride
        enc.setVertexBuffer(scene.vertexBuffer, offset: 0, index: 0)

        let ml = (params.multiLayerBg ? scene.multiLayer : nil)

        // ---- 背景打底：完整网格，不透明，按背景深度位移 ----
        // 多层开启时用「远景背景」(主体+近景背景已去除并填充)，否则用普通完整背景。
        if scene.bgIndexCount > 0 {
            enc.setRenderPipelineState(opaqueState)
            var ub = uniforms; ub.layerFactor = params.bgParallaxFactor; ub.fgFlag = 0
            enc.setVertexBytes(&ub, length: stride, index: 1)
            let bgC = ml?.farColor ?? scene.bgColor
            let bgD = ml?.farDepth ?? scene.bgDepth
            enc.setVertexTexture(bgD, index: 0)
            enc.setFragmentBytes(&ub, length: stride, index: 1)
            enc.setFragmentTexture(bgC, index: 0)
            enc.setFragmentTexture(bgD, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: scene.bgIndexCount,
                                      indexType: .uint32, indexBuffer: scene.bgIndexBuffer,
                                      indexBufferOffset: 0)
        }

        // ---- 中间层：近景背景，切开的网格，over 混合，按背景视差缩放(但用近景背景深度，故比远景动得多) ----
        if let ml = ml, ml.midIndexCount > 0 {
            enc.setRenderPipelineState(blendState)
            var um = uniforms; um.layerFactor = params.bgParallaxFactor; um.fgFlag = 1
            // 中间层「整体放大」盖住其身后远景的去遮挡带。放大量按**深度比例**(越远越小，烘焙时算好)：
            // 近的近景背景放大多、远的放大少 ⇒ 远层倍率自然压低（用户：离得远的别太高）。
            um.fgScale = 1 + (params.fgScale - 1) * ml.midScaleFactor
            um.fgCenter = ml.midCenter
            enc.setVertexBytes(&um, length: stride, index: 1)
            enc.setVertexTexture(ml.midDepth, index: 0)
            enc.setFragmentBytes(&um, length: stride, index: 1)
            enc.setFragmentTexture(ml.midColor, index: 0)
            enc.setFragmentTexture(ml.midDepth, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: ml.midIndexCount,
                                      indexType: .uint32, indexBuffer: ml.midIndexBuffer,
                                      indexBufferOffset: 0)
        }

        // ---- 「出框」画框条：屏幕空间静止白条，夹在所有背景层与前景之间 ----
        // 背景被框在条后、主体随视差跨到条前 ⇒ 前/框/后三层深度线索（经典裸眼 3D 出框）。
        // 只在正常查看渲染（debug/掩膜 pass 不画，避免污染重拍洞掩膜）。
        if params.frameBars && uniforms.debugMode == 0 {
            enc.setRenderPipelineState(barState)
            let sx = uniforms.viewScale.x
            let halfW = 0.030 * sx                       // 条宽：相对图像宽度，缩放下保持比例
            let white = SIMD4<Float>(0.92, 0.92, 0.92, 1)
            for cx: Float in [-0.52 * sx, 0.52 * sx] {   // 约在图像 1/4、3/4 处；满视口高 ⇒ 比画面更"高"，框感更强
                var bar = BarUniforms(rect: SIMD4<Float>(cx - halfW, -1, cx + halfW, 1), color: white)
                enc.setVertexBytes(&bar, length: MemoryLayout<BarUniforms>.stride, index: 1)
                enc.setFragmentBytes(&bar, length: MemoryLayout<BarUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        // ---- 前景：切开的主体网格，over 混合，按真实逐像素深度位移 ----
        if scene.fgIndexCount > 0 {
            enc.setRenderPipelineState(blendState)
            var uf = uniforms; uf.layerFactor = 1; uf.fgFlag = 1
            uf.fgScale = params.fgScale; uf.fgCenter = scene.fgCenter
            enc.setVertexBytes(&uf, length: stride, index: 1)
            enc.setVertexTexture(scene.depth, index: 0)
            enc.setFragmentBytes(&uf, length: stride, index: 1)
            enc.setFragmentTexture(scene.fgColor, index: 0)
            enc.setFragmentTexture(scene.depth, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: scene.fgIndexCount,
                                      indexType: .uint32, indexBuffer: scene.fgIndexBuffer,
                                      indexBufferOffset: 0)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
    }

    func draw(in view: MTKView) {
        frame &+= 1
        motion.interfaceOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = ctx.queue.makeCommandBuffer() else { return }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        if let scene = scene {
            let u = makeUniforms(offset: currentOffset())
            encode(scene: scene, uniforms: u, descriptor: rpd, commandBuffer: cb)
        } else if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    // MARK: - 离屏渲染（导出用）

    func renderOffscreen(scene: Photo3DScene, offset: SIMD2<Float>,
                         width: Int, height: Int,
                         clearColor: MTLClearColor = MTLClearColorMake(0, 0, 0, 1),
                         debugMode: Int32 = 0) -> MTLTexture? {
        guard let target = ctx.makeRenderTarget(width: width, height: height) else { return nil }
        // 4× MSAA：多重采样色附件 → resolve 到单采样 target。
        // MSAA 附件按尺寸缓存复用（每次 waitUntilCompleted 后才返回，无跨帧并用）；
        // target 不能缓存——调用方可能同时持有多个返回值（如空间照片的左右眼）。
        let msaa: MTLTexture
        if let cached = offscreenMSAA, cached.width == width, cached.height == height {
            msaa = cached
        } else {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                              width: max(1, width), height: max(1, height), mipmapped: false)
            md.textureType = .type2DMultisample
            md.sampleCount = Self.sampleCount
            md.usage = [.renderTarget]
            md.storageMode = .private
            guard let made = ctx.device.makeTexture(descriptor: md) else { return nil }
            offscreenMSAA = made
            msaa = made
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = msaa
        rpd.colorAttachments[0].resolveTexture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.colorAttachments[0].clearColor = clearColor
        guard let cb = ctx.queue.makeCommandBuffer() else { return nil }

        let savedViewport = viewportSize
        viewportSize = CGSize(width: width, height: height)
        var u = makeUniforms(offset: offset)
        u.debugMode = debugMode
        encode(scene: scene, uniforms: u, descriptor: rpd, commandBuffer: cb)
        viewportSize = savedViewport

        cb.commit()
        cb.waitUntilCompleted()
        return target
    }
}
