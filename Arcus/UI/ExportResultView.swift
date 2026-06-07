import SwiftUI
import AVKit

struct ExportResultView: View {
    @ObservedObject var model: AppModel
    let result: AppModel.ExportResult
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 380)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button {
                        model.saveToAlbum(result)
                    } label: {
                        Label("保存到相册", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    ShareLink(item: result.url) {
                        Label("分享文件", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { if result.kind == .video { startPlayer() } }
        .onDisappear { stopPlayer() }
    }

    private var title: String { result.kind == .video ? "视差视频" : "空间照片" }
    private var subtitle: String {
        result.kind == .video
            ? "可保存到相册或分享。循环视差，适合社交分享。"
            : "立体 HEIC，AirDrop 到 Apple Vision Pro 可作为空间照片查看。"
    }

    @ViewBuilder private var preview: some View {
        switch result.kind {
        case .video:
            if let player = player {
                VideoPlayer(player: player)
            } else {
                Color.black.overlay(ProgressView().tint(.white))
            }
        case .spatial:
            if let img = UIImage(contentsOfFile: result.url.path) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Image(systemName: "cube").font(.system(size: 60)).foregroundStyle(.secondary)
            }
        }
    }

    private func startPlayer() {
        guard player == nil else { return }
        let p = AVPlayer(url: result.url)
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: .zero); p?.play()
        }
        player = p
        p.play()
    }

    private func stopPlayer() {
        if let token = loopObserver { NotificationCenter.default.removeObserver(token); loopObserver = nil }
        player?.pause()
        player = nil
    }
}
