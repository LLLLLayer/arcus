import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import simd

/// 把 3D 视差导出成一张 **Live Photo**（实况照片）：一张静帧 HEIC + 一段配对 MOV。
/// 关键在于给两者写入同一个 Content Identifier，并在视频里加一条 `still-image-time` 定时元数据轨——
/// 这正是系统识别「静帧↔视频」为实况照片的契约。保存时按 .photo + .pairedVideo 配对资源写入相册。
enum LivePhotoExporter {

    enum ExportError: Error { case writerInit, pixelBufferPool, render, still, timeout }

    struct Result { let still: URL; let video: URL }

    struct Settings {
        var duration: Double = 3.0
        var fps: Int = 30
        var maxSide: Int = 1080
        var amplitude: Float = 1.0
    }

    private static let kContentID = "com.apple.quicktime.content.identifier"
    private static let kStillTime = "com.apple.quicktime.still-image-time"

    static func export(scene: Photo3DScene,
                       baseParams: ViewerParams,
                       settings: Settings = Settings()) throws -> Result {

        let assetID = UUID().uuidString

        var w = scene.width, h = scene.height
        let longSide = max(w, h)
        if longSide > settings.maxSide {
            let s = Double(settings.maxSide) / Double(longSide)
            w = Int((Double(w) * s).rounded()); h = Int((Double(h) * s).rounded())
        }
        w -= w % 2; h -= h % 2

        // 离屏渲染器
        let renderer = ParallaxRenderer(pixelFormat: .bgra8Unorm)
        renderer.scene = scene
        var params = baseParams
        params.motionEnabled = false
        params.autoAnimate = false
        params.parallaxAmp = baseParams.parallaxAmp * settings.amplitude
        renderer.params = params

        // ── 1) 静帧（中性机位 offset=0，对应视频 t=0 帧）→ HEIC，写入 Content Identifier
        guard let stillTex = renderer.renderOffscreen(scene: scene, offset: .zero, width: w, height: h),
              let stillCG = TextureIO.cgImage(from: stillTex) else { throw ExportError.still }
        let stillURL = try writeStill(stillCG, assetID: assetID)

        // ── 2) 配对视频 MOV：H.264 + Content Identifier 顶层元数据 + still-image-time 定时元数据轨
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arcus-Live-\(UInt32.random(in: 0...UInt32.max)).mov")
        try? FileManager.default.removeItem(at: videoURL)

        guard let writer = try? AVAssetWriter(outputURL: videoURL, fileType: .mov) else { throw ExportError.writerInit }
        writer.metadata = [contentIDMetadataItem(assetID)]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, w * h * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(vInput) else { throw ExportError.writerInit }
        writer.add(vInput)

        // still-image-time 定时元数据轨
        let metaInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: stillTimeFormatDescription())
        let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
        if writer.canAdd(metaInput) { writer.add(metaInput) }

        guard writer.startWriting() else { throw ExportError.writerInit }
        writer.startSession(atSourceTime: .zero)

        // 标记静帧时刻（t=0，给一帧的小区间）
        let timescale: Int32 = 600
        let frameDuration = CMTime(value: Int64(Double(timescale) / Double(settings.fps)), timescale: timescale)
        metaAdaptor.append(AVTimedMetadataGroup(items: [stillTimeMetadataItem()],
                                                timeRange: CMTimeRange(start: .zero, duration: frameDuration)))

        guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferPool }
        let frameCount = max(1, Int(settings.duration * Double(settings.fps)))

        do {
            for i in 0..<frameCount {
                try Task.checkCancellation()
                let t = Double(i) / Double(frameCount)
                let ang = Float(t) * 2 * .pi
                let offset = SIMD2<Float>(sin(ang) * 0.8, sin(ang * 2) * 0.2)
                guard let tex = renderer.renderOffscreen(scene: scene, offset: offset, width: w, height: h) else {
                    throw ExportError.render
                }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pixelBuffer = pb else { throw ExportError.pixelBufferPool }
                TextureIO.copy(texture: tex, into: pixelBuffer)

                let deadline = Date().addingTimeInterval(30)
                while !vInput.isReadyForMoreMediaData {
                    if Date() > deadline { throw ExportError.timeout }
                    usleep(2000)
                }
                adaptor.append(pixelBuffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(i)))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: stillURL)
            throw error
        }

        metaInput.markAsFinished()
        vInput.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status == .failed { throw writer.error ?? ExportError.writerInit }

        return Result(still: stillURL, video: videoURL)
    }

    // MARK: - 静帧 HEIC（含 Content Identifier）

    private static func writeStill(_ cg: CGImage, assetID: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arcus-Live-\(UInt32.random(in: 0...UInt32.max)).heic")
        try? FileManager.default.removeItem(at: url)
        // 优先 HEIC；个别旧设备不支持编码时回退 JPEG
        let type = (CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) != nil)
            ? UTType.heic.identifier : UTType.jpeg.identifier
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ExportError.still
        }
        // Apple Maker Note 字典里 key "17" = 资源标识符（与视频 Content Identifier 对应）
        let props: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": assetID]
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.still }
        return url
    }

    // MARK: - QuickTime 元数据

    private static func contentIDMetadataItem(_ id: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = kContentID as NSString
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = id as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func stillTimeMetadataItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = kStillTime as NSString
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    private static func stillTimeFormatDescription() -> CMFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/\(kStillTime)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8
        ]
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc)
        return desc
    }
}
