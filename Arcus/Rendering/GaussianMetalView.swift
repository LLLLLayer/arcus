import SwiftUI
import MetalKit
import simd

/// 把 3D 高斯泼溅渲染器包进 SwiftUI。拖拽 → 移机位（视差）；双击 → 复位陀螺仪参考 + 机位。
/// 与 ParallaxMetalView 同构（共享手势/陀螺仪习惯），但渲染的是真 3DGS 而非 2.5D 网格 warp。
struct GaussianMetalView: UIViewRepresentable {
    let scene: GaussianScene?
    let params: ViewerParams
    var controller: GaussianViewController? = nil   // 供「补全这一视角」拿渲染器做快照

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = 1                 // 高斯衰减自带软边，无需 MSAA
        view.framebufferOnly = false         // snapshot 需要可读 drawable / 离屏
        view.isOpaque = false                // 透明 ⇒ 露出 SwiftUI「虚拟云状」背景
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .clear
        (view.layer as? CAMetalLayer)?.isOpaque = false

        let renderer = GaussianRenderer(pixelFormat: view.colorPixelFormat)
        renderer.scene = scene
        renderer.params = params
        view.delegate = renderer
        context.coordinator.renderer = renderer
        context.coordinator.attachGestures(to: view)
        controller?.renderer = renderer
        if params.motionEnabled { renderer.motion.start() }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        r.scene = scene
        r.params = params
        controller?.renderer = r
        if params.motionEnabled { r.motion.start() } else { r.motion.stop() }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        view.isPaused = true
        coordinator.renderer?.motion.stop()
    }

    final class Coordinator: NSObject {
        var renderer: GaussianRenderer?

        func attachGestures(to view: UIView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view, let r = renderer else { return }
            let t = g.translation(in: view)
            let nx = Float(t.x / max(view.bounds.width, 1)) * 2.2
            let ny = Float(t.y / max(view.bounds.height, 1)) * 2.2
            switch g.state {
            case .began, .changed:
                r.isPanning = true
                r.panOffset = SIMD2<Float>(nx, -ny)
            case .ended, .cancelled, .failed:
                r.isPanning = false
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let r = renderer else { return }
            r.motion.recenter()
            r.panOffset = .zero
        }
    }
}

/// 「补全这一视角」桥接：把当前 3DGS 渲染器交给 SwiftUI，按需把当前机位渲染成离屏快照。
final class GaussianViewController: ObservableObject {
    weak var renderer: GaussianRenderer?
    /// 返回当前机位的离屏渲染纹理（bgra8 预乘，alpha=覆盖；透明处=露出区/洞）。
    func snapshot(longSide: Int = 1024) -> MTLTexture? { renderer?.snapshot(longSide: longSide) }
    /// 异步快照：不在主线程同步阻塞 GPU。
    func snapshotAsync(longSide: Int = 1024) async -> MTLTexture? { await renderer?.snapshotAsync(longSide: longSide) }
    /// 当前有效机位偏移（-1…1），供 SwiftUI 炫彩 sheen 跟随倾斜。轻量轮询，无 @Published 60fps 风暴。
    func currentTilt() -> CGSize {
        let o = renderer?.lastOffset ?? .zero
        return CGSize(width: CGFloat(o.x), height: CGFloat(o.y))
    }
}
