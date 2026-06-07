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
