import SwiftUI

/// 空间画廊：端侧保存过的「3D 照片库」。点按重新打开（按原方案重跑），长按可删除。
struct ArcusGalleryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                if model.galleryItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.galleryItems) { item in
                                GalleryCell(item: item)
                                    .onTapGesture {
                                        dismiss()
                                        model.openLibraryItem(item)
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            withAnimation { model.deleteLibraryItem(item) }
                                        } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .auroraBackground()
            .navigationTitle("Spatial Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear { model.refreshGallery() }   // 跟随系统深浅色
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text("No 3D photos yet").font(.headline).foregroundStyle(.white)
            Text("Your 3D photos will appear here")
                .font(.caption).foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

/// 画廊缩略图单元：缩略图(磁盘懒加载) + 方案角标 + 日期。
private struct GalleryCell: View {
    let item: LibraryItem
    @State private var thumb: UIImage?

    private var isGaussian: Bool { item.sceneMode == "gaussianSplat" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.white.opacity(0.06))
                        .overlay(ProgressView().tint(.white.opacity(0.5)))
                }
            }
            .frame(height: 132)
            .frame(maxWidth: .infinity)
            .clipped()

            // 底部渐隐 + 方案角标
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .frame(height: 132)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                Image(systemName: isGaussian ? "cube.transparent" : "square.3.layers.3d")
                    .font(.system(size: 9, weight: .bold))
                Text(item.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 7).padding(.vertical, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
        .task(id: item.id) {
            if thumb == nil {
                let url = item.thumbURL
                thumb = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
        }
    }
}
