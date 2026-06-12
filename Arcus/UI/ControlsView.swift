import SwiftUI
import PhotosUI

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("3D 照片")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            if expanded {
                Picker("查看", selection: $model.params.debugMode) {
                    Text("正常").tag(Int32(0))
                    Text("深度").tag(Int32(1))
                    Text("主体").tag(Int32(2))
                    Text("背景").tag(Int32(3))
                }
                .pickerStyle(.segmented)

                slider(title: "3D 强度", value: $model.params.parallaxAmp, range: 0.02...0.13)
                slider(title: "背景视差", value: $model.params.bgParallaxFactor, range: 0.0...0.8)
                slider(title: "前景放大", value: $model.params.fgScale, range: 1.0...1.25)

                HStack(spacing: 12) {
                    Toggle(isOn: $model.params.motionEnabled) {
                        Label("陀螺仪", systemImage: "gyroscope").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.cyan)

                    Toggle(isOn: $model.params.autoAnimate) {
                        Label("自动旋转", systemImage: "arrow.triangle.2.circlepath").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.purple)

                    Toggle(isOn: $model.params.multiLayerBg) {
                        Label("背景分层", systemImage: "square.3.layers.3d").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.orange)

                    Toggle(isOn: $model.params.frameBars) {
                        Label("出框", systemImage: "rectangle.split.3x1").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.mint)

                    Spacer()
                }
                .foregroundStyle(.white)

                HStack(spacing: 12) {
                    actionButton(title: "导出视频", icon: "film", colors: [.blue, .cyan]) {
                        model.exportVideo()
                    }
                    actionButton(title: "空间照片", icon: "view.3d", colors: [.purple, .pink]) {
                        model.exportSpatial()
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.badge.plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 48)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func slider(title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%.0f%%", percent(value.wrappedValue, range)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: value, in: range)
                .tint(.cyan)
        }
    }

    private func percent(_ v: Float, _ range: ClosedRange<Float>) -> Float {
        (v - range.lowerBound) / (range.upperBound - range.lowerBound) * 100
    }

    private func actionButton(title: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }
}
