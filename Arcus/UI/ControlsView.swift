import SwiftUI
import PhotosUI

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(AppText.Controls.title)
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
                Picker(AppText.Controls.view, selection: $model.params.debugMode) {
                    Text(AppText.Controls.normal).tag(Int32(0))
                    Text(AppText.Controls.depth).tag(Int32(1))
                    Text(AppText.Controls.subject).tag(Int32(2))
                    Text(AppText.Controls.background).tag(Int32(3))
                }
                .pickerStyle(.segmented)

                slider(title: AppText.Controls.strength, value: $model.params.parallaxAmp, range: 0.02...0.13)
                slider(title: AppText.Controls.backgroundParallax, value: $model.params.bgParallaxFactor, range: 0.0...0.8)
                slider(title: AppText.Controls.foregroundScale, value: $model.params.fgScale, range: 1.0...1.25)

                HStack(spacing: 12) {
                    Toggle(isOn: $model.params.motionEnabled) {
                        Label(AppText.Controls.gyro, systemImage: "gyroscope").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.cyan)

                    Toggle(isOn: $model.params.autoAnimate) {
                        Label(AppText.Controls.autoRotate, systemImage: "arrow.triangle.2.circlepath").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.purple)

                    Toggle(isOn: $model.params.multiLayerBg) {
                        Label(AppText.Controls.layeredBackground, systemImage: "square.3.layers.3d").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.orange)

                    Toggle(isOn: $model.params.frameBars) {
                        Label(AppText.Controls.framePopOut, systemImage: "rectangle.split.3x1").font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.mint)

                    Spacer()
                }
                .foregroundStyle(.white)

                HStack(spacing: 12) {
                    actionButton(title: AppText.Controls.exportVideo, icon: "film", colors: [.blue, .cyan]) {
                        model.exportVideo()
                    }
                    actionButton(title: AppText.Controls.spatialPhoto, icon: "view.3d", colors: [.purple, .pink]) {
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
