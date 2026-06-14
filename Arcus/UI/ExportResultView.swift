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
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    ShareLink(item: result.url) {
                        Label("Share File", systemImage: "square.and.arrow.up")
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
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { if result.kind == .video { startPlayer() } }
        .onDisappear { stopPlayer() }
    }

    private var title: String {
        switch result.kind {
        case .video:   return String(localized: "Parallax Video")
        case .spatial: return String(localized: "Spatial Photo")
        case .gif:     return String(localized: "Animated")
        case .live:    return String(localized: "Live Photo")
        }
    }
    private var subtitle: String {
        switch result.kind {
        case .video:   return String(localized: "Save to Photos or share it. A looping parallax clip, great for social sharing.")
        case .spatial: return String(localized: "Stereo HEIC — AirDrop it to Apple Vision Pro to view as a spatial photo.")
        case .gif:     return String(localized: "A seamless looping GIF — plays anywhere, easiest to share.")
        case .live:    return String(localized: "Save as a Live Photo — press and hold in Photos to see the 3D parallax move.")
        }
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
        case .gif:
            GIFImageView(url: result.url)
        case .live:
            ZStack(alignment: .topLeading) {
                if let img = UIImage(contentsOfFile: result.url.path) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: "livephoto").font(.system(size: 60)).foregroundStyle(.secondary)
                }
                Label("LIVE", systemImage: "livephoto")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
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

/// 动图预览：用 ImageIO 解码 GIF 帧，交给 UIImageView 循环播放（SwiftUI Image 不会动画 animatedImage）。
private struct GIFImageView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.image = Self.animatedImage(from: url)
        return v
    }
    func updateUIView(_ uiView: UIImageView, context: Context) {}

    private static func animatedImage(from url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                 ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.05
            total += d
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}
