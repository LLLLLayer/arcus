import SwiftUI

/// 空间画廊：端侧保存过的「3D 照片库」。点按重新打开（按原方案重跑），长按可删除。
/// 「选择」模式支持多选 + 批量删除（全选 / 取消 / 删除并二次确认）。
struct ArcusGalleryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selection = Set<String>()      // 选中的 LibraryItem.id
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                if model.galleryItems.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .auroraBackground()
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog("Delete selected photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let ids = selection
                    withAnimation { model.deleteLibraryItems(ids) }
                    exitSelection()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { model.refreshGallery() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.galleryItems) { item in
                    GalleryCell(item: item, selecting: selecting, selected: selection.contains(item.id))
                        .onTapGesture {
                            if selecting {
                                toggle(item.id)
                            } else {
                                dismiss()
                                model.openLibraryItem(item)
                            }
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

    // MARK: - 工具栏

    private var titleText: Text {
        if selecting {
            return Text(verbatim: "\(selection.count) ") + Text("Selected")
        }
        return Text("Spatial Gallery")
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { exitSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    HStack(spacing: 3) {
                        Text("Delete")
                        if !selection.isEmpty { Text(verbatim: "(\(selection.count))") }
                    }
                    .fontWeight(.semibold)
                }
                .disabled(selection.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { selection.removeAll() }
                    else { selection = Set(model.galleryItems.map(\.id)) }
                }
            }
        } else {
            if !model.galleryItems.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select") { withAnimation { selecting = true } }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
        }
    }

    private var allSelected: Bool {
        !model.galleryItems.isEmpty && selection.count == model.galleryItems.count
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func exitSelection() {
        withAnimation { selecting = false }
        selection.removeAll()
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

/// 画廊缩略图单元：缩略图(磁盘懒加载) + 方案角标 + 日期；选择模式叠加选中圈。
private struct GalleryCell: View {
    let item: LibraryItem
    var selecting: Bool = false
    var selected: Bool = false
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

            // 选择模式：未选变暗 + 右上角选中圈
            if selecting {
                Color.black.opacity(selected ? 0 : 0.32)
                    .allowsHitTesting(false)
                selectionBadge
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selecting && selected ? Theme.accentB : .white.opacity(0.10),
                        lineWidth: selecting && selected ? 3 : 1)
        )
        .scaleEffect(selecting && selected ? 0.95 : 1)
        .animation(.easeInOut(duration: 0.15), value: selected)
        .animation(.easeInOut(duration: 0.15), value: selecting)
        .task(id: item.id) {
            if thumb == nil {
                let url = item.thumbURL
                thumb = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
        }
    }

    private var selectionBadge: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(selected ? AnyShapeStyle(Theme.accentB) : AnyShapeStyle(.white.opacity(0.85)))
            .background(selected ? Circle().fill(.white).padding(2) : nil)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
    }
}
