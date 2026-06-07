import SwiftUI
import MetalKit
import simd

/// 把 Metal 视差渲染器包进 SwiftUI。拖拽 → 手动视差；双击 → 复位陀螺仪参考。
struct ParallaxMetalView: UIViewRepresentable {
    let scene: Photo3DScene?
    let params: ViewerParams

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = ParallaxRenderer.sampleCount   // 4× MSAA：抗锯齿剪影切口
        view.framebufferOnly = true
        view.isOpaque = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .black

        let renderer = ParallaxRenderer(pixelFormat: view.colorPixelFormat)
        renderer.scene = scene
        renderer.params = params
        view.delegate = renderer
        context.coordinator.renderer = renderer
        context.coordinator.attachGestures(to: view)
        if params.motionEnabled { renderer.motion.start() }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        r.scene = scene
        r.params = params
        if params.motionEnabled { r.motion.start() } else { r.motion.stop() }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil            // 停止渲染回调，避免拆除期间继续 draw
        view.isPaused = true
        coordinator.renderer?.motion.stop()
    }

    final class Coordinator: NSObject {
        var renderer: ParallaxRenderer?

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
                r.panOffset = SIMD2<Float>(nx, -ny)   // y 反向，拖动方向更符合直觉
            case .ended, .cancelled, .failed:
                r.isPanning = false                    // 渲染循环里自动回弹
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
