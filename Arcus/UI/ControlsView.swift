import SwiftUI
import PhotosUI

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?
    var onOpenGeminiSettings: (() -> Void)? = nil
    var onRepair: (() -> Void)? = nil
    @State private var expanded = false   // 默认收起，沉浸看 3D；点 chevron 展开参数/导出

    private var isGaussian: Bool {
        model.isGaussian   // 单一真源在 AppModel（高斯泼溅 / SHARP 实验都填充 gaussianScene）
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isGaussian ? "cube.transparent" : "square.3.layers.3d")
                    .font(.subheadline).foregroundStyle(Theme.accentB)
                Text(isGaussian ? "3D Gaussian Splatting" : "3D Photo")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.subheadline).foregroundStyle(Theme.sub)
                        .frame(width: 28, height: 28)
                }
            }

            if isGaussian, let onRepair {
                Button(action: onRepair) { Label("Complete This View", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle(gradient: Theme.warmGradient))
            }

            if expanded {
                VStack(spacing: 14) {
                    if isGaussian { gaussianControls } else { ldiControls }
                    exportRow
                }
            }
        }
        .frame(maxWidth: .infinity)      // 强制按可用宽度撑满，避免被贪婪子视图(横向 ScrollView/网格)撑超出屏宽 ⇒ 不再左溢/裁切
        .padding(16)
        .glassCard(radius: 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - LDI

    @ViewBuilder private var ldiControls: some View {
        Picker("View", selection: $model.params.debugMode) {
            Text("Normal").tag(Int32(0)); Text("Depth").tag(Int32(1))
            Text("Subject").tag(Int32(2)); Text("Background").tag(Int32(3))
        }
        .pickerStyle(.segmented)

        LabeledSlider(title: "3D Strength", value: $model.params.parallaxAmp, range: 0.02...0.13)
        LabeledSlider(title: "Background Parallax", value: $model.params.bgParallaxFactor, range: 0.0...0.8)
        LabeledSlider(title: "Foreground Scale", value: $model.params.fgScale, range: 1.0...1.25)

        FlowChips {
            ChipToggle(title: "Gyroscope", icon: "gyroscope", isOn: $model.params.motionEnabled, tint: Theme.accentB)
            ChipToggle(title: "Auto-Rotate", icon: "arrow.triangle.2.circlepath", isOn: $model.params.autoAnimate, tint: Theme.accentA)
            ChipToggle(title: "Background Layering", icon: "square.3.layers.3d", isOn: $model.params.multiLayerBg, tint: .orange)
            ChipToggle(title: "Pop-Out", icon: "rectangle.split.3x1", isOn: $model.params.frameBars, tint: .mint)
            // 「重拍·补全这一视角」可走云端：配置 Gemini Key（云端优先，否则端侧）。
            chipButton(title: "Google API", icon: model.canUseGemini ? "cloud.fill" : "cloud",
                       on: model.canUseGemini, tint: Theme.accentC) { onOpenGeminiSettings?() }
        }
    }

    // MARK: - Gaussian「镜头」

    @ViewBuilder private var gaussianControls: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 12) {
            LabeledSlider(title: "3D Strength", value: $model.params.parallaxAmp, range: 0.02...0.30)
            LabeledSlider(title: "Dolly (In/Out)", value: $model.params.gsDolly, range: -1.0...1.0, unit: "")
            LabeledSlider(title: "Focus", value: $model.params.gsFocus, range: 0.0...1.0)
            LabeledSlider(title: "Aperture (f)", value: $model.params.gsFNumber, range: 1.4...16.0, unit: "")
        }

        FlowChips {
            ChipToggle(title: "Gyroscope", icon: "gyroscope", isOn: $model.params.motionEnabled, tint: Theme.accentB)
            chipButton(title: "Auto Dolly", icon: "move.3d", on: model.isDollyZooming, tint: Theme.accentC) { model.toggleDollyZoom() }
            ChipToggle(title: "Auto-Rotate", icon: "arrow.triangle.2.circlepath", isOn: $model.params.autoAnimate, tint: Theme.accentA)
            chipButton(title: "Reset", icon: "arrow.counterclockwise", on: false, tint: .white.opacity(0.5)) { model.resetLens() }
            chipButton(title: "Google API", icon: model.canUseGemini ? "cloud.fill" : "cloud",
                       on: model.canUseGemini, tint: Theme.accentC) { onOpenGeminiSettings?() }
        }
    }

    /// 动作型胶囊（非 Toggle）：复位 / 自动推轨 / Google API。
    private func chipButton(title: LocalizedStringKey, icon: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(on ? .white : Theme.sub)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? AnyShapeStyle(tint.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.06)), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 导出

    @ViewBuilder private var exportRow: some View {
        if isGaussian {
            Text("Export uses layered (LDI) rendering")
                .font(.caption2).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            actionButton(title: isGaussian ? "Layered Video" : "Export Video", icon: "film", colors: [Theme.accentB, .cyan]) {
                model.exportVideo()
            }
            actionButton(title: "Live Photo", icon: "livephoto", colors: [Theme.accentA, Theme.accentB]) {
                model.exportLive()
            }
            actionButton(title: "Animated GIF", icon: "rectangle.stack.badge.play", colors: [.orange, Theme.accentC]) {
                model.exportGif()
            }
            actionButton(title: isGaussian ? "Layered Spatial" : "Spatial Photo", icon: "view.3d", colors: [Theme.accentA, Theme.accentC]) {
                model.exportSpatial()
            }
        }
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            Label("New Photo", systemImage: "photo.badge.plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.10), lineWidth: 1))
                .foregroundStyle(Theme.body)
        }
    }

    private func actionButton(title: LocalizedStringKey, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }
}

/// 胶囊开关行：横向滚动，chips 再多也不溢出。
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) { content }.padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // 接受可用宽度，不向外撑宽容器
    }
}
