import Foundation
import UIKit
import CoreGraphics
import CoreVideo
import Accelerate

enum ImageUtils {

    /// 从原始照片数据直接解码出「已摆正 + 已降采样」的图（ImageIO 子采样解码）。
    /// 不在原始分辨率上整图落内存：48MP 照片的解码峰值从 ~190MB 降到工作分辨率量级。
    static func downsampledImage(from data: Data, maxSide: Int) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 同时应用 EXIF 方向
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 把任意 UIImage 摆正方向并降采样到长边 ≤ maxSide，返回工程统一使用的工作图。
    /// 摆正 + 缩放在一次 draw 里完成（UIImage.draw 自带 EXIF 处理），不先在原始分辨率整图重绘。
    static func workingImage(from image: UIImage, maxSide: Int) -> (cg: CGImage, width: Int, height: Int)? {
        // UIImage.size 已计入 EXIF 方向（竖拍照片宽高已交换），按它算目标像素尺寸。
        let w0 = image.size.width * image.scale
        let h0 = image.size.height * image.scale
        guard w0 >= 1, h0 >= 1 else { return nil }
        let longSide = max(w0, h0)
        let scale = longSide > CGFloat(maxSide) ? CGFloat(maxSide) / longSide : 1.0
        // 让宽高为偶数，便于金字塔 / 视频编码。
        var w = max(2, Int((w0 * scale).rounded()))
        var h = max(2, Int((h0 * scale).rounded()))
        w -= w % 2; h -= h % 2
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let out = drawn.cgImage else { return nil }
        return (out, out.width, out.height)
    }

    /// 读单通道 CVPixelBuffer（深度/灰度/mask）为 FloatImage(1ch)。支持 Float32 / Float16 / UInt8。
    static func scalarFloats(from pixelBuffer: CVPixelBuffer) -> FloatImage? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var out = FloatImage(width: w, height: h, channels: 1)

        switch fmt {
        case kCVPixelFormatType_DepthFloat32:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<w { out.pixels[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { out.pixels[y * w + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent8:
            let inv: Float = 1.0 / 255.0
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out.pixels[y * w + x] = Float(row[x]) * inv }
            }
        default:
            // 兜底：当 32 位 float 处理。
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<w { out.pixels[y * w + x] = row[x] }
            }
        }
        return out
    }

    /// CIImage / CGImage 灰度 → FloatImage(1ch)，按目标尺寸缩放。
    static func scalarFloats(fromGray cg: CGImage, width: Int, height: Int) -> FloatImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return FloatImage(width: width, height: height, channels: 1)
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var out = FloatImage(width: width, height: height, channels: 1)
        let inv: Float = 1.0 / 255.0
        for i in 0..<(width * height) { out.pixels[i] = Float(bytes[i]) * inv }
        return out
    }
}

