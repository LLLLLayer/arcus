import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import simd

/// 把场景渲染成左右眼并写出空间照片（立体 HEIC）。可 AirDrop 到 Apple Vision Pro 查看。
/// iOS 17.2+ 写带 StereoPair 分组的标准空间照片；更低版本回退为左右并排单图。
enum SpatialPhotoExporter {

    enum ExportError: Error { case render, destination }

    /// 左右眼在视差偏移空间的水平间距（越大立体感越强）。
    static let eyeOffset: Float = 0.6

    static func export(scene: Photo3DScene, baseParams: ViewerParams) throws -> URL {
        var w = scene.width, h = scene.height
        // 限制尺寸，避免过大。
        let maxSide = 1600
        let longSide = max(w, h)
        if longSide > maxSide {
            let s = Double(maxSide) / Double(longSide)
            w = Int((Double(w) * s).rounded()); h = Int((Double(h) * s).rounded())
        }
        w -= w % 2; h -= h % 2

        let renderer = ParallaxRenderer(pixelFormat: .bgra8Unorm)
        renderer.scene = scene
        var p = baseParams
        p.motionEnabled = false; p.autoAnimate = false
        renderer.params = p

        guard let leftTex = renderer.renderOffscreen(scene: scene, offset: SIMD2(-eyeOffset, 0), width: w, height: h),
              let rightTex = renderer.renderOffscreen(scene: scene, offset: SIMD2(eyeOffset, 0), width: w, height: h),
              let leftCG = TextureIO.cgImage(from: leftTex),
              let rightCG = TextureIO.cgImage(from: rightTex) else {
            throw ExportError.render
        }

        if #available(iOS 17.2, *) {
            return try writeStereoHEIC(left: leftCG, right: rightCG)
        } else {
            return try writeSideBySide(left: leftCG, right: rightCG, width: w, height: h)
        }
    }

    // MARK: - 标准空间照片（StereoPair）

    @available(iOS 17.2, *)
    private static func writeStereoHEIC(left: CGImage, right: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arcus-Spatial-\(UInt32.random(in: 0...UInt32.max)).heic")
        try? FileManager.default.removeItem(at: url)

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.heic.identifier as CFString, 2, nil) else {
            throw ExportError.destination
        }
        let leftProps: [CFString: Any] = [kCGImagePropertyGroupImageIsLeftImage: true]
        let rightProps: [CFString: Any] = [kCGImagePropertyGroupImageIsRightImage: true]
        CGImageDestinationAddImage(dest, left, leftProps as CFDictionary)
        CGImageDestinationAddImage(dest, right, rightProps as CFDictionary)

        let group: [CFString: Any] = [
            kCGImagePropertyGroupIndex: 0,
            kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
            kCGImagePropertyGroupImageIndexLeft: 0,
            kCGImagePropertyGroupImageIndexRight: 1
        ]
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGroups: [group]] as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { throw ExportError.destination }
        return url
    }

    // MARK: - 回退：左右并排单图

    private static func writeSideBySide(left: CGImage, right: CGImage, width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arcus-SBS-\(UInt32.random(in: 0...UInt32.max)).heic")
        try? FileManager.default.removeItem(at: url)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { throw ExportError.destination }
        guard let ctx = CGContext(data: nil, width: width * 2, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.destination
        }
        ctx.draw(left, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(right, in: CGRect(x: width, y: 0, width: width, height: height))
        guard let combined = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw ExportError.destination
        }
        CGImageDestinationAddImage(dest, combined, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.destination }
        return url
    }
}
