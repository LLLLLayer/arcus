import Foundation
import MetalKit
import simd

/// 纯 Metal 3D 高斯泼溅渲染器（无第三方依赖）：
///  • 合成透视相机：规范视(offset=0)精确复原原图；拖拽/陀螺仪平移机位绕「视差支点」⇒ 真实视差；
///    「推轨」沿 z 移机位 ⇒ 前景前后移动。
///  • EWA 泼溅：每实例一颗高斯撑屏幕四边形，3D 协方差经透视雅可比投到 2D conic。
///  • MRT：color(预乘 over) + depth((z·α,α) over) ⇒ 每像素期望深度；第二 pass 做景深 + 合成到 drawable
///    （透明处保留 alpha=0，露出 SwiftUI「虚拟云状」背景）。
///  • 每帧 CPU 计数排序（后→前）+ 三重缓冲 index。
final class GaussianRenderer: NSObject, MTKViewDelegate {

    /// 与 GaussianShaders.metal 的 GaussianUniforms 严格对应（stride 160）。
    private struct GaussianUniforms {
        var viewProj = matrix_identity_float4x4
        var view = matrix_identity_float4x4
        var viewportPx = SIMD2<Float>(1, 1)
        var g: Float = 1
        var aspect: Float = 1
        var nearZ: Float = 0.05
        var lowpass: Float = 0.30
        var maxAlpha: Float = 0.99
        var _pad: Float = 0
    }

    /// 与 GaussianShaders.metal 的 DOFUniforms 严格对应（stride 32）。
    private struct DOFUniforms {
        var texel = SIMD2<Float>(1, 1)
        var focusDepth: Float = 1
        var aperture: Float = 0.2
        var maxRadius: Float = 26
        var blurScale: Float = 0
        var _p0: Float = 0
        var _p1: Float = 0
    }

    private let ctx = MetalContext.shared
    private var splatPipeline: MTLRenderPipelineState!
    private var dofPipeline: MTLRenderPipelineState!
    private let depthFormat: MTLPixelFormat = .rgba16Float

    var scene: GaussianScene? { didSet { if oldValue !== scene { resizeRing() } } }
    var params = ViewerParams()
    let motion = MotionController()

    var panOffset = SIMD2<Float>(0, 0)
    var isPanning = false
    private(set) var lastOffset = SIMD2<Float>(0, 0)   // 每帧有效机位偏移（陀螺仪+拖拽+自动），供 UI 炫彩 sheen 读取

    private var frame = 0
    private var viewportSize = CGSize(width: 1, height: 1)

    // 离屏目标（drawable 尺寸）：color + depth-accum。
    private var colorTarget: MTLTexture?
    private var depthTarget: MTLTexture?

    // 三重缓冲排序索引 + 飞行信号量。
    private static let ring = 3
    private var indexBuffers: [MTLBuffer] = []
    private var indexCapacity = 0
    private var ringIndex = 0
    private let inFlight = DispatchSemaphore(value: ring)

    private var zscratch: [Float] = []
    private var bucketStart: [Int] = []
    private static let buckets = 2048

    init(pixelFormat: MTLPixelFormat) {
        super.init()
        assert(MemoryLayout<GaussianUniforms>.stride == 160, "GaussianUniforms layout must match the Metal side")
        assert(MemoryLayout<GaussianSplat>.stride == 52, "GaussianSplat layout must match the Metal side")
        assert(MemoryLayout<DOFUniforms>.stride == 32, "DOFUniforms layout must match the Metal side")
        buildPipelines(pixelFormat: pixelFormat)
        bucketStart = [Int](repeating: 0, count: Self.buckets + 1)
    }

    private func buildPipelines(pixelFormat: MTLPixelFormat) {
        // splat MRT 管线
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = ctx.library.makeFunction(name: "gs_vertex")
        d.fragmentFunction = ctx.library.makeFunction(name: "gs_fragment")
        d.rasterSampleCount = 1
        for i in [0, 1] {
            let a = d.colorAttachments[i]!
            a.pixelFormat = (i == 0) ? .bgra8Unorm : depthFormat
            a.isBlendingEnabled = true                  // 预乘 over（后→前）
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        // DOF + 合成 pass
        let f = MTLRenderPipelineDescriptor()
        f.vertexFunction = ctx.library.makeFunction(name: "gs_dof_vertex")
        f.fragmentFunction = ctx.library.makeFunction(name: "gs_dof_fragment")
        f.rasterSampleCount = 1
        f.colorAttachments[0].pixelFormat = pixelFormat
        do {
            splatPipeline = try ctx.device.makeRenderPipelineState(descriptor: d)
            dofPipeline = try ctx.device.makeRenderPipelineState(descriptor: f)
        } catch { fatalError("Failed to create Gaussian render pipeline: \(error)") }
    }

    private func resizeRing() {
        guard let count = scene?.count, count > 0 else { return }
        if count <= indexCapacity, indexBuffers.count == Self.ring { return }
        indexBuffers = (0..<Self.ring).compactMap {
            _ in ctx.device.makeBuffer(length: count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        }
        indexCapacity = count
        zscratch = [Float](repeating: 0, count: count)
    }

    private func makeTarget(_ format: MTLPixelFormat, _ w: Int, _ h: Int,
                            storage: MTLStorageMode = .private) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                            width: max(1, w), height: max(1, h), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = storage
        return ctx.device.makeTexture(descriptor: desc)
    }

    private func ensureTargets(_ w: Int, _ h: Int) {
        if let c = colorTarget, c.width == w, c.height == h { return }
        colorTarget = makeTarget(.bgra8Unorm, w, h)
        depthTarget = makeTarget(depthFormat, w, h)
    }

    // MARK: - 相机

    private func currentOffset() -> SIMD2<Float> {
        if !isPanning { panOffset *= 0.88 }
        var off = panOffset
        if params.motionEnabled { off += motion.sample() }
        if params.autoAnimate {
            let t = Float(frame) * 0.025
            off += SIMD2<Float>(sin(t) * 0.7, cos(t * 0.8) * 0.45)
        }
        return simd_clamp(off, SIMD2<Float>(-1, -1), SIMD2<Float>(1, 1))
    }

    private func dollyZ(_ scene: GaussianScene) -> Float {
        params.gsDolly * scene.pivotZ * 0.45   // 推轨：前景前后移动
    }

    private func makeView(scene: GaussianScene, offset: SIMD2<Float>) -> simd_float4x4 {
        let amp = max(0, params.parallaxAmp) * scene.pivotZ * 2.2
        let eye = SIMD3<Float>(offset.x * amp, -offset.y * amp, dollyZ(scene))
        let target = SIMD3<Float>(0, 0, scene.pivotZ)
        return Self.lookAtZForward(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
    }

    private func makeUniforms(scene: GaussianScene, viewM: simd_float4x4, viewportPx: SIMD2<Float>) -> GaussianUniforms {
        // 希区柯克变焦：推轨(沿 z 移机位)的同时按 FOV 反向补偿，使支点处主体大小近乎不变、透视被夸张（对标 OpenReshot 推轨）。
        let baseG = 1 / tan(scene.fovY / 2)
        let comp = max(0.25, (scene.pivotZ - dollyZ(scene)) / max(scene.pivotZ, 1e-3))
        let g = baseG * comp
        var u = GaussianUniforms()
        u.view = viewM
        u.viewProj = Self.perspectiveFromG(g: g, aspect: scene.imageAspect, near: scene.nearZ, far: scene.farZ) * viewM
        u.viewportPx = viewportPx
        u.g = g
        u.aspect = scene.imageAspect
        u.nearZ = scene.nearZ
        return u
    }

    private func makeDOF(scene: GaussianScene, viewportPx: SIMD2<Float>) -> DOFUniforms {
        var d = DOFUniforms()
        d.texel = SIMD2<Float>(1 / max(viewportPx.x, 1), 1 / max(viewportPx.y, 1))
        let focusWorld = scene.depthNear + (scene.depthFar - scene.depthNear) * max(0, min(1, params.gsFocus))
        d.focusDepth = focusWorld - dollyZ(scene)        // 相机空间
        d.aperture = 2.8 / max(1.4, params.gsFNumber)
        d.maxRadius = 26
        d.blurScale = params.gsFNumber >= 15.9 ? 0 : 1   // f/16+ 关景深
        return d
    }

    // MARK: - 排序（后→前）

    private func sortIndices(scene: GaussianScene, view: simd_float4x4, into buf: MTLBuffer) {
        let n = scene.count
        let r0 = view.columns.0.z, r1 = view.columns.1.z, r2 = view.columns.2.z, r3 = view.columns.3.z
        let splats = scene.splatBuffer.contents().bindMemory(to: GaussianSplat.self, capacity: n)
        var zmin = Float.greatestFiniteMagnitude, zmax = -Float.greatestFiniteMagnitude
        zscratch.withUnsafeMutableBufferPointer { zb in
            for i in 0..<n {
                let s = splats[i]
                let z = r0 * s.px + r1 * s.py + r2 * s.pz + r3
                zb[i] = z
                if z < zmin { zmin = z }
                if z > zmax { zmax = z }
            }
        }
        let NB = Self.buckets
        let scale = Float(NB - 1) / max(zmax - zmin, 1e-6)
        @inline(__always) func bucket(_ z: Float) -> Int {
            let b = Int((zmax - z) * scale)
            return b < 0 ? 0 : (b >= NB ? NB - 1 : b)
        }
        for i in 0...NB { bucketStart[i] = 0 }
        zscratch.withUnsafeBufferPointer { zb in
            for i in 0..<n { bucketStart[bucket(zb[i]) + 1] += 1 }
            for i in 1...NB { bucketStart[i] += bucketStart[i - 1] }
            let out = buf.contents().bindMemory(to: UInt32.self, capacity: n)
            bucketStart.withUnsafeMutableBufferPointer { bs in
                for i in 0..<n {
                    let b = bucket(zb[i])
                    out[bs[b]] = UInt32(i)
                    bs[b] += 1
                }
            }
        }
    }

    // MARK: - 编码

    private func encodeSplats(_ scene: GaussianScene, _ u: GaussianUniforms, color: MTLTexture, depth: MTLTexture,
                             viewport: MTLViewport, idx: MTLBuffer, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[1].texture = depth
        rpd.colorAttachments[1].loadAction = .clear
        rpd.colorAttachments[1].storeAction = .store
        rpd.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setViewport(viewport)
        enc.setRenderPipelineState(splatPipeline)
        enc.setVertexBuffer(scene.splatBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(idx, offset: 0, index: 1)
        var uu = u
        enc.setVertexBytes(&uu, length: MemoryLayout<GaussianUniforms>.stride, index: 2)
        enc.setFragmentBytes(&uu, length: MemoryLayout<GaussianUniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: scene.count)
        enc.endEncoding()
    }

    private func encodeDOF(_ scene: GaussianScene, color: MTLTexture, depth: MTLTexture, viewportPx: SIMD2<Float>,
                          into rpd: MTLRenderPassDescriptor, cb: MTLCommandBuffer) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                    width: Double(viewportPx.x), height: Double(viewportPx.y), znear: 0, zfar: 1))
        enc.setRenderPipelineState(dofPipeline)
        enc.setFragmentTexture(color, index: 0)
        enc.setFragmentTexture(depth, index: 1)
        var d = makeDOF(scene: scene, viewportPx: viewportPx)
        enc.setFragmentBytes(&d, length: MemoryLayout<DOFUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { viewportSize = size }

    func draw(in view: MTKView) {
        frame &+= 1
        motion.interfaceOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)   // 透明 ⇒ 露出 SwiftUI 云状背景

        let dw = Int(viewportSize.width.rounded()), dh = Int(viewportSize.height.rounded())
        guard let scene = scene, scene.count > 0, indexBuffers.count == Self.ring, dw > 0, dh > 0 else {
            if let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                enc.endEncoding(); cb.present(drawable); cb.commit()
            }
            return
        }
        ensureTargets(dw, dh)
        guard let color = colorTarget, let depth = depthTarget, let cb = ctx.queue.makeCommandBuffer() else { return }

        inFlight.wait()
        cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        ringIndex = (ringIndex + 1) % Self.ring
        let idxBuf = indexBuffers[ringIndex]

        let off = currentOffset()
        lastOffset = off
        let viewM = makeView(scene: scene, offset: off)
        sortIndices(scene: scene, view: viewM, into: idxBuf)

        // fit 取景：整图按**原比例完整**显示（不裁剪、不拉伸），留白处露出 SwiftUI 云状背景
        // ——空间照片悬浮在雾面玻璃上的观感。视口宽高比恒等于图像比 ⇒ 投影无形变。
        let a = CGFloat(scene.imageAspect), da = CGFloat(dw) / CGFloat(dh)
        var vw = CGFloat(dw), vh = CGFloat(dh)
        if da > a { vh = CGFloat(dh); vw = CGFloat(dh) * a }   // 屏比图宽 ⇒ 满高、左右留白
        else      { vw = CGFloat(dw); vh = CGFloat(dw) / a }   // 屏比图高 ⇒ 满宽、上下留白
        let ox = (CGFloat(dw) - vw) / 2, oy = (CGFloat(dh) - vh) / 2

        let u = makeUniforms(scene: scene, viewM: viewM, viewportPx: SIMD2<Float>(Float(vw), Float(vh)))
        encodeSplats(scene, u, color: color, depth: depth,
                     viewport: MTLViewport(originX: Double(ox), originY: Double(oy),
                                           width: Double(vw), height: Double(vh), znear: 0, zfar: 1),
                     idx: idxBuf, cb: cb)
        encodeDOF(scene, color: color, depth: depth, viewportPx: SIMD2<Float>(Float(dw), Float(dh)), into: rpd, cb: cb)
        cb.present(drawable)
        cb.commit()
    }

    // MARK: - 离屏快照（供「补全这一视角」修复用）。按原图比例渲当前机位，返回 bgra8 纹理（预乘，alpha=覆盖）。

    /// 同步快照（保留兼容；会阻塞调用线程等 GPU，勿在主线程用）。
    func snapshot(longSide: Int = 1024) -> MTLTexture? {
        guard let (outTex, cb) = encodeSnapshot(longSide: longSide) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        return outTex
    }

    /// 异步快照：命令缓冲在调用线程构建并 commit（轻量），但用 addCompletedHandler 把 GPU 等待挂起，
    /// 避免「补全这一视角」时在主线程同步 block GPU 造成卡顿。
    func snapshotAsync(longSide: Int = 1024) async -> MTLTexture? {
        guard let (outTex, cb) = encodeSnapshot(longSide: longSide) else { return nil }
        // 续体只回传 Void（闭包不捕获非 Sendable 的 MTLTexture），纹理在 await 之后返回。
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cb.addCompletedHandler { _ in cont.resume() }
            cb.commit()
        }
        return outTex
    }

    /// 构建快照命令缓冲（编码完但未 commit）。按原图比例渲当前机位 → bgra8 共享纹理（预乘，alpha=覆盖）。
    private func encodeSnapshot(longSide: Int) -> (MTLTexture, MTLCommandBuffer)? {
        guard let scene = scene, scene.count > 0, indexBuffers.count == Self.ring else { return nil }
        let H = scene.imageAspect >= 1 ? Int(Float(longSide) / scene.imageAspect) : longSide
        let W = scene.imageAspect >= 1 ? longSide : Int(Float(longSide) * scene.imageAspect)
        let w = max(2, W), h = max(2, H)
        guard let color = makeTarget(.bgra8Unorm, w, h),
              let depth = makeTarget(depthFormat, w, h),
              let outTex = makeTarget(.bgra8Unorm, w, h, storage: .shared),   // CPU 需 getBytes 回读
              let idx = ctx.device.makeBuffer(length: scene.count * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let cb = ctx.queue.makeCommandBuffer() else { return nil }

        let off = currentOffset()
        let viewM = makeView(scene: scene, offset: off)
        sortIndices(scene: scene, view: viewM, into: idx)
        // 目标本身即图像比例 ⇒ 视口铺满即可（无需 cover）。
        let u = makeUniforms(scene: scene, viewM: viewM, viewportPx: SIMD2<Float>(Float(w), Float(h)))
        encodeSplats(scene, u, color: color, depth: depth,
                     viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                     idx: idx, cb: cb)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = outTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        encodeDOF(scene, color: color, depth: depth, viewportPx: SIMD2<Float>(Float(w), Float(h)), into: rpd, cb: cb)
        return (outTex, cb)
    }

    // MARK: - 矩阵

    static func perspectiveFromG(g: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let A = far / (far - near)
        let B = -far * near / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(g / aspect, 0, 0, 0),
            SIMD4<Float>(0, g, 0, 0),
            SIMD4<Float>(0, 0, A, 1),
            SIMD4<Float>(0, 0, B, 0)))
    }

    static func lookAtZForward(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let r = simd_normalize(simd_cross(up, f))
        let u = simd_cross(f, r)
        let t = SIMD3<Float>(-simd_dot(r, eye), -simd_dot(u, eye), -simd_dot(f, eye))
        return simd_float4x4(columns: (
            SIMD4<Float>(r.x, u.x, f.x, 0),
            SIMD4<Float>(r.y, u.y, f.y, 0),
            SIMD4<Float>(r.z, u.z, f.z, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)))
    }
}
