import SwiftUI
import PhotosUI

struct EditorView: View {
    @ObservedObject var model: AppModel
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ParallaxMetalView(scene: model.scene, params: model.params)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                hintBar
                ControlsView(model: model, pickerItem: $pickerItem)
            }

            if model.isExporting {
                exportingOverlay
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                model.reset()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if !model.sourceInfo.isEmpty {
                Text(model.sourceInfo)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var hintBar: some View {
        Text("倾斜手机 · 拖动画面 · 双击复位")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 10)
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text(model.exportMessage)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(30)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
