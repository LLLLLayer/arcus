import Foundation
import Photos

/// 把导出的视频 / 空间照片保存到系统相册。
enum MediaSaver {

    enum SaveError: Error { case notAuthorized, failed }

    private static func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if granted != .authorized && granted != .limited { throw SaveError.notAuthorized }
        default:
            throw SaveError.notAuthorized
        }
    }

    static func saveVideo(_ url: URL) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    static func saveImage(_ url: URL) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    /// 实况照片：把静帧(.photo)与配对视频(.pairedVideo)作为同一资产的两个资源写入，系统据此识别为 Live Photo。
    static func saveLivePhoto(still: URL, video: URL) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.shouldMoveFile = false
            req.addResource(with: .photo, fileURL: still, options: opts)
            req.addResource(with: .pairedVideo, fileURL: video, options: opts)
        }
    }
}
