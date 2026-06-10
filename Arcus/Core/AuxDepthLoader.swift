import Foundation
import AVFoundation
import ImageIO

/// 从照片文件的辅助数据里提取自带深度（人像/LiDAR 照片），有则走 AVDepthData 快速路径。
enum AuxDepthLoader {
    static func avDepth(from data: Data) -> AVDepthData? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let types = [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth]
        for type in types {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) as? [AnyHashable: Any],
               let depth = try? AVDepthData(fromDictionaryRepresentation: info) {
                // 辅助深度存在「未旋转」的传感器坐标系，而主图会被摆正到 .up（竖拍人像照几乎都带
                // EXIF 旋转）——深度必须同步旋转，否则与摆正后的图像差 90°/镜像。
                if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let raw = props[kCGImagePropertyOrientation] as? UInt32,
                   let exif = CGImagePropertyOrientation(rawValue: raw), exif != .up {
                    return depth.applyingExifOrientation(exif)
                }
                return depth
            }
        }
        return nil
    }
}
