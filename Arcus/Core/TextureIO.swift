import Foundation
import Metal
import CoreGraphics
import CoreVideo

/// MTLTexture（bgra8）与 CGImage / CVPixelBuffer 的互转，供导出使用。
enum TextureIO {

    static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: w * 4,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // Metal bgra8Unorm ↔ byteOrder32Little + premultipliedFirst
        let bmp = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: bmp) else { return nil }
        return ctx.makeImage()
    }

    /// 从预乘 bgra8 纹理读回直通 RGB(3ch) + 洞掩膜(1ch, alpha<阈=1)，供端侧修复（LaMa/MI-GAN）使用。
    static func rgbAndHole(from texture: MTLTexture, holeThreshold: Float = 0.5) -> (rgb: FloatImage, hole: FloatImage)? {
        let w = texture.width, h = texture.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var rgb = FloatImage(width: w, height: h, channels: 3)
        var hole = FloatImage(width: w, height: h, channels: 1)
        let inv255: Float = 1.0 / 255.0
        for p in 0..<(w * h) {
            let a = Float(bytes[p * 4 + 3]) * inv255           // bgra: [0]=B [1]=G [2]=R [3]=A
            let unp: Float = a > 1e-3 ? 1.0 / a : 0
            rgb.pixels[p * 3 + 0] = min(1, Float(bytes[p * 4 + 2]) * inv255 * unp)
            rgb.pixels[p * 3 + 1] = min(1, Float(bytes[p * 4 + 1]) * inv255 * unp)
            rgb.pixels[p * 3 + 2] = min(1, Float(bytes[p * 4 + 0]) * inv255 * unp)
            hole.pixels[p] = a < holeThreshold ? 1 : 0
        }
        return (rgb, hole)
    }

    /// 把 bgra8 纹理拷进给定的 CVPixelBuffer(32BGRA)。
    static func copy(texture: MTLTexture, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let w = texture.width, h = texture.height
        if rowBytes == w * 4 {
            texture.getBytes(base, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        } else {
            // 行对齐不同：逐行拷贝。
            var tmp = [UInt8](repeating: 0, count: w * h * 4)
            tmp.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                                 from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
            tmp.withUnsafeBytes { src in
                for y in 0..<h {
                    memcpy(base.advanced(by: y * rowBytes),
                           src.baseAddress!.advanced(by: y * w * 4),
                           w * 4)
                }
            }
        }
    }
}
