import Foundation
import AVFoundation
import simd

/// 把 3D 视差渲染成一段循环视频（mp4）。
/// 用离屏渲染器逐帧渲染一条 Lissajous 相机轨迹，编码为 H.264。
enum VideoExporter {

    enum ExportError: Error { case writerInit, pixelBufferPool, render, timeout }

    struct Settings {
        var duration: Double = 4.0
        var fps: Int = 30
        var maxSide: Int = 1080
        /// 视差幅度倍率（相对当前 ViewerParams）。
        var amplitude: Float = 1.0
    }

    static func export(scene: Photo3DScene,
                       baseParams: ViewerParams,
                       settings: Settings = Settings()) throws -> URL {

        // 输出尺寸：保持比例，长边 ≤ maxSide，且为偶数。
        var w = scene.width, h = scene.height
        let longSide = max(w, h)
        if longSide > settings.maxSide {
            let s = Double(settings.maxSide) / Double(longSide)
            w = Int((Double(w) * s).rounded()); h = Int((Double(h) * s).rounded())
        }
        w -= w % 2; h -= h % 2

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arcus-\(UInt32.random(in: 0...UInt32.max)).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw ExportError.writerInit
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            // 视差画面整帧都在动，默认码率容易糊；按 ~4 bit/px/帧给足。
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, w * h * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            // 显式标记 709：渲染输出是 sRGB 内容，不标记时播放端猜色彩会产生偏色。
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw ExportError.writerInit }
        writer.add(input)

        guard writer.startWriting() else { throw ExportError.writerInit }
        writer.startSession(atSourceTime: .zero)

        // 离屏渲染器（独立于屏幕渲染器）。
        let renderer = ParallaxRenderer(pixelFormat: .bgra8Unorm)
        renderer.scene = scene
        var params = baseParams
        params.motionEnabled = false
        params.autoAnimate = false
        params.parallaxAmp = baseParams.parallaxAmp * settings.amplitude
        renderer.params = params

        let frameCount = max(1, Int(settings.duration * Double(settings.fps)))
        let timescale: Int32 = 600
        let frameDuration = CMTime(value: Int64(Double(timescale) / Double(settings.fps)), timescale: timescale)

        guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferPool }

        do {
            for i in 0..<frameCount {
                try Task.checkCancellation()                 // 用户取消：中断逐帧渲染
                let t = Double(i) / Double(frameCount)       // 0…1 循环
                let ang = Float(t) * 2 * .pi
                // 水平为主的平滑 figure-8 轨迹，幅度收敛以减少极端机位的拉伸暴露（seamless 循环）。
                // 注：更进一步的“显著性感知最小拉伸轨迹优化”留作后续(见 docs/05)。
                let offset = SIMD2<Float>(sin(ang) * 0.8, sin(ang * 2) * 0.2)

                guard let tex = renderer.renderOffscreen(scene: scene, offset: offset, width: w, height: h) else {
                    throw ExportError.render
                }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pixelBuffer = pb else { throw ExportError.pixelBufferPool }
                TextureIO.copy(texture: tex, into: pixelBuffer)

                let deadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    if Date() > deadline { throw ExportError.timeout }
                    usleep(2000)
                }
                let pts = CMTimeMultiply(frameDuration, multiplier: Int32(i))
                adaptor.append(pixelBuffer, withPresentationTime: pts)
            }
        } catch {
            writer.cancelWriting()                           // 中断/出错：丢弃半成品文件
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        if writer.status == .failed {
            try? FileManager.default.removeItem(at: url)      // 收尾失败也清掉半成品，别在临时目录留垃圾
            throw writer.error ?? ExportError.writerInit
        }
        return url
    }
}
