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
                return depth
            }
        }
        return nil
    }
}
