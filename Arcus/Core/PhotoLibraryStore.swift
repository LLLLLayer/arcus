import UIKit
import CryptoKit

/// 一条「空间画廊」记录：保存原图(已降采样的 JPEG)+缩略图+元数据(创建时间/渲染方案/补全方式)。
/// 重新打开时按原方案重跑管线（端侧很快，配合炫彩加载态体验完整），无需序列化 GPU 烘焙结果。
struct LibraryItem: Identifiable, Hashable {
    let id: String              // 签名(=文件夹名)：源图 JPEG 的 SHA256
    let createdAt: Date
    let sceneMode: String       // AppModel.SceneMode.rawValue
    let fillMode: String        // FillMode.rawValue
    let dir: URL

    var sourceURL: URL { dir.appendingPathComponent("source.jpg") }
    var thumbURL: URL  { dir.appendingPathComponent("thumb.jpg") }
    var thumbnail: UIImage? { UIImage(contentsOfFile: thumbURL.path) }
}

/// 端侧持久化的「3D 照片库」。文件全部落在 Application Support，离线、隐私（照片不出设备）。
final class PhotoLibraryStore: @unchecked Sendable {
    static let shared = PhotoLibraryStore()

    private let root: URL
    private let maxItems = 24            // 上限，超出按时间淘汰最旧，避免占满磁盘
    private let queue = DispatchQueue(label: "com.arcus.library")   // 串行化所有读写：多条后台处理任务并发 save/淘汰时不竞态

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("ArcusLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - 写入

    /// 保存一条记录（按签名去重：同一张图重复处理只更新时间/方案）。返回写好的记录。
    @discardableResult
    func save(sourceData: Data, sceneMode: String, fillMode: String) -> LibraryItem? {
        queue.sync { _save(sourceData: sourceData, sceneMode: sceneMode, fillMode: fillMode) }
    }

    private func _save(sourceData: Data, sceneMode: String, fillMode: String) -> LibraryItem? {
        let sig = Self.signature(for: sourceData)
        let dir = root.appendingPathComponent(sig, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 原图：尽量存成 JPEG（若已是 JPEG 直接落盘，否则解码再编码）
        if let jpeg = Self.asJPEG(sourceData) {
            try? jpeg.write(to: dir.appendingPathComponent("source.jpg"))
        } else {
            try? sourceData.write(to: dir.appendingPathComponent("source.jpg"))
        }
        // 缩略图（画廊网格用，长边 320）
        if let thumb = ImageUtils.downsampledImage(from: sourceData, maxSide: 320),
           let tdata = thumb.jpegData(compressionQuality: 0.8) {
            try? tdata.write(to: dir.appendingPathComponent("thumb.jpg"))
        }
        let now = Date()
        let meta: [String: Any] = [
            "createdAt": now.timeIntervalSince1970,
            "sceneMode": sceneMode,
            "fillMode": fillMode,
        ]
        if let mdata = try? JSONSerialization.data(withJSONObject: meta) {
            try? mdata.write(to: dir.appendingPathComponent("meta.json"))
        }
        evictIfNeeded()
        return LibraryItem(id: sig, createdAt: now, sceneMode: sceneMode, fillMode: fillMode, dir: dir)
    }

    // MARK: - 读取

    /// 全部记录，按时间倒序（最近在前）。
    func items() -> [LibraryItem] { queue.sync { _items() } }

    private func _items() -> [LibraryItem] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [LibraryItem] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let mdata = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let obj = try? JSONSerialization.jsonObject(with: mdata) as? [String: Any] else { continue }
            let ts = (obj["createdAt"] as? Double) ?? 0
            out.append(LibraryItem(id: dir.lastPathComponent,
                                   createdAt: Date(timeIntervalSince1970: ts),
                                   sceneMode: (obj["sceneMode"] as? String) ?? "layeredLDI",
                                   fillMode: (obj["fillMode"] as? String) ?? "fast",
                                   dir: dir))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    func sourceData(for item: LibraryItem) -> Data? {
        try? Data(contentsOf: item.sourceURL)
    }

    // MARK: - 删除

    func delete(_ item: LibraryItem) { queue.sync { _delete(item) } }

    private func _delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.dir)
    }

    func clearAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    // MARK: - 工具

    /// 仅在已持有 queue 的上下文(_save)内调用，故走非串行化的内部方法，避免串行队列自死锁。
    private func evictIfNeeded() {
        let all = _items()
        guard all.count > maxItems else { return }
        for old in all.suffix(all.count - maxItems) { _delete(old) }   // _items() 已按时间倒序，suffix 即最旧
    }

    static func signature(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 若已是 JPEG 直接返回，否则解码再编码为 JPEG（兼容 HEIC/PNG）。
    private static func asJPEG(_ data: Data) -> Data? {
        if data.count > 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return data }   // JPEG 魔数
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
    }
}
