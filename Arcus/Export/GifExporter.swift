import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// 把 3D 视差渲染成一段无限循环的动图（GIF）。最易分享的「会动的照片」格式。
/// 与 VideoExporter 共用同一条离屏相机轨迹，只是落地为 GIF（更小尺寸、更低帧率）。
enum GifExporter {

    enum ExportError: Error { case destination, render, finalize }

    struct Settings {
        var duration: Double = 3.0
        var fps: Int = 20
        var maxSide: Int = 640          // GIF 体积敏感，限制长边
        var amplitude: Float = 1.0
    }

    static func export(scene: Photo3DScene,
                       baseParams: ViewerParams,
                       settings: Settings = Settings()) throws -> URL {

        var w = scene.width, h = scene.height
        let longSide = max(w, h)
        if longSide > settings.maxSide {
            let s = Double(settings.maxSide) / Double(longSide)
            w = Int((Double(w) * s).rounded()); h = Int((Double(h) * s).rounded())
        }
        w -= w % 2; h -= h % 2

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arcus-\(UInt32.random(in: 0...UInt32.max)).gif")
        try? FileManager.default.removeItem(at: url)

        let frameCount = max(1, Int(settings.duration * Double(settings.fps)))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frameCount, nil) else {
            throw ExportError.destination
        }
        // 循环次数 0 = 无限循环
        let gifProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let delay = 1.0 / Double(settings.fps)
        let frameProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                             kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary

        let renderer = ParallaxRenderer(pixelFormat: .bgra8Unorm)
        renderer.scene = scene
        var params = baseParams
        params.motionEnabled = false
        params.autoAnimate = false
        params.parallaxAmp = baseParams.parallaxAmp * settings.amplitude
        renderer.params = params

        do {
            for i in 0..<frameCount {
                try Task.checkCancellation()
                let t = Double(i) / Double(frameCount)        // 0…1 无缝循环
                let ang = Float(t) * 2 * .pi
                let offset = SIMD2<Float>(sin(ang) * 0.8, sin(ang * 2) * 0.2)
                guard let tex = renderer.renderOffscreen(scene: scene, offset: offset, width: w, height: h),
                      let cg = TextureIO.cgImage(from: tex) else {
                    throw ExportError.render
                }
                CGImageDestinationAddImage(dest, cg, frameProps)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.finalize
        }
        return url
    }
}
