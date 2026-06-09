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
            case .changed: r.zoomLevel = min(3.0, max(0.7, pinchStart * Float(g.scale)))   // <1=向外拉远，露出更宽画框待补全(Extend)
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

/// 「重拍」桥接器：把当前渲染器交给 SwiftUI，按需把「当前机位」渲染为全分辨率静帧 + 补全洞掩膜。
/// 洞 = 需要重新生成的像素，两类：① 画框外被移出去的边；② 主体让开后露出的「烤进去的填充」(背后)。
/// 用一遍 maskMode(debugMode 4) 渲染同时拿到两者：白色清屏=画框外；背景输出 fillMask；前景按覆盖抹 0。
final class ReframeController: ObservableObject {
    weak var renderer: ParallaxRenderer?
    weak var view: MTKView?

    /// 返回 (rgb 3ch, hole 1ch[1=待重新生成])；无渲染器/尺寸为 0 时返回 nil。
    func snapshot() -> (rgb: FloatImage, hole: FloatImage)? {
        guard let r = renderer, let scene = r.scene else { return nil }
        // 输出按**原图比例**(scene.width:height)，而非手机屏幕的竖长比例 ⇒ 重拍补全成片是一张正常比例照片。
        let dw = scene.width, dh = scene.height
        guard dw > 0, dh > 0 else { return nil }
        let off = simd_clamp(r.panOffset, SIMD2<Float>(-1, -1), SIMD2<Float>(1, 1))

        // ① 当前机位的彩色帧（画框外清黑；洞内容会被补全器忽略）。
        guard let colorTex = r.renderOffscreen(scene: scene, offset: off, width: dw, height: dh),
              let ccg = TextureIO.cgImage(from: colorTex) else { return nil }
        let cimg = FloatImage.fromCGImage(ccg, width: dw, height: dh)

        // ② 洞掩膜帧：白色清屏(画框外=洞)，maskMode 输出 fillMask 与前景覆盖。
        guard let maskTex = r.renderOffscreen(scene: scene, offset: off, width: dw, height: dh,
                                              clearColor: MTLClearColorMake(1, 1, 1, 1), debugMode: 4),
              let mcg = TextureIO.cgImage(from: maskTex) else { return nil }
        let mimg = FloatImage.fromCGImage(mcg, width: dw, height: dh)

        var rgb = FloatImage(width: dw, height: dh, channels: 3)
        var hole = FloatImage(width: dw, height: dh, channels: 1)
        for p in 0..<(dw * dh) {
            rgb.pixels[p * 3] = cimg.pixels[p * 4]
            rgb.pixels[p * 3 + 1] = cimg.pixels[p * 4 + 1]
            rgb.pixels[p * 3 + 2] = cimg.pixels[p * 4 + 2]
            hole.pixels[p] = mimg.pixels[p * 4] > 0.5 ? 1 : 0   // 掩膜 R>0.5 = 洞
        }
        return (rgb, hole.dilated(radius: 2))   // 膨胀吞掉 MSAA 抗锯齿过渡边
    }
}
