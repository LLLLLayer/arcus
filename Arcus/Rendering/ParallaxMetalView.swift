import SwiftUI
import MetalKit
import simd

/// 把 Metal 视差渲染器包进 SwiftUI。拖拽 → 手动视差；双击 → 复位陀螺仪参考。
struct ParallaxMetalView: UIViewRepresentable {
    let scene: Photo3DScene?
    let params: ViewerParams
    var controller: ReframeController? = nil   // 「重拍」桥接（可选）：让 SwiftUI 能拿到渲染器做静帧补全

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
        controller?.renderer = renderer
        controller?.view = view
        if params.motionEnabled { renderer.motion.start() }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        r.scene = scene
        r.params = params
        if !params.reframeMode { r.zoomLevel = 1 }   // 退出重拍即复位缩放 ⇒ 普通查看绝不被缩放影响
        controller?.renderer = r
        controller?.view = view
        if params.motionEnabled { r.motion.start() } else { r.motion.stop() }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil            // 停止渲染回调，避免拆除期间继续 draw
        view.isPaused = true
        coordinator.renderer?.motion.stop()
    }

    final class Coordinator: NSObject {
        var renderer: ParallaxRenderer?
        private var pinchStart: Float = 1

        func attachGestures(to view: UIView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)   // 仅在重拍模式生效（见 handlePinch）；普通查看双指无操作，不改变现有交互
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let r = renderer, r.params.reframeMode else { return }   // 普通查看：直接忽略
            switch g.state {
            case .began: pinchStart = r.zoomLevel
            case .changed: r.zoomLevel = min(3.0, max(1.0, pinchStart * Float(g.scale)))
            default: break
            }
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
            r.zoomLevel = 1
        }
    }
}

/// 「重拍」桥接器：把当前渲染器交给 SwiftUI，按需将「当前机位」渲染为全分辨率静帧，
/// 并以哨兵品红清屏 → 渲染后仍是品红的像素 = 被移出画框、需要补全的「洞」。
final class ReframeController: ObservableObject {
    weak var renderer: ParallaxRenderer?
    weak var view: MTKView?

    /// 返回 (rgb 3ch, hole 1ch[1=露出待补全])；无渲染器/尺寸为 0 时返回 nil。
    func snapshot() -> (rgb: FloatImage, hole: FloatImage)? {
        guard let r = renderer, let scene = r.scene, let v = view else { return nil }
        let dw = Int(v.drawableSize.width), dh = Int(v.drawableSize.height)
        guard dw > 0, dh > 0 else { return nil }
        let off = simd_clamp(r.panOffset, SIMD2<Float>(-1, -1), SIMD2<Float>(1, 1))
        guard let tex = r.renderOffscreen(scene: scene, offset: off, width: dw, height: dh,
                                          clearColor: MTLClearColorMake(1, 0, 1, 1)),
              let cg = TextureIO.cgImage(from: tex) else { return nil }
        let img = FloatImage.fromCGImage(cg, width: dw, height: dh)   // 4ch RGBA
        var rgb = FloatImage(width: dw, height: dh, channels: 3)
        var hole = FloatImage(width: dw, height: dh, channels: 1)
        for p in 0..<(dw * dh) {
            let rr = img.pixels[p * 4], gg = img.pixels[p * 4 + 1], bb = img.pixels[p * 4 + 2]
            rgb.pixels[p * 3] = rr; rgb.pixels[p * 3 + 1] = gg; rgb.pixels[p * 3 + 2] = bb
            hole.pixels[p] = (rr > 0.8 && gg < 0.2 && bb > 0.8) ? 1 : 0   // 命中哨兵品红=洞
        }
        return (rgb, hole.dilated(radius: 2))   // 膨胀吞掉 MSAA 抗锯齿过渡边
    }
}
