import Foundation
import UIKit
import CoreGraphics
import CoreVideo
import Accelerate

enum ImageUtils {

    /// 把任意 UIImage 摆正方向并降采样到长边 ≤ maxSide，返回工程统一使用的工作图。
    static func workingImage(from image: UIImage, maxSide: Int) -> (cg: CGImage, width: Int, height: Int)? {
        let normalized = image.normalizedUp()
        guard let cg0 = normalized.cgImage else { return nil }
        let w0 = cg0.width, h0 = cg0.height
        let longSide = max(w0, h0)
        let scale = longSide > maxSide ? Double(maxSide) / Double(longSide) : 1.0
        // 让宽高为偶数，便于金字塔 / 视频编码。
        var w = max(2, Int((Double(w0) * scale).rounded()))
        var h = max(2, Int((Double(h0) * scale).rounded()))
        w -= w % 2; h -= h % 2
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg0, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return (out, w, h)
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

extension UIImage {
    /// 返回方向为 .up 的同图（消除 EXIF 旋转）。
    func normalizedUp() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
