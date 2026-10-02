import AVFoundation
import SwiftUI
import UIKit

/// The animated logo, looping (muted), e.g. on the idle screen instead of a clock.
struct LogoVideo: UIViewRepresentable {
    func makeUIView(context: Context) -> LoopingPlayerView { LoopingPlayerView() }
    func updateUIView(_ view: LoopingPlayerView, context: Context) {}
}

final class LoopingPlayerView: UIView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    init() {
        super.init(frame: .zero)
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "mp4") else { return }
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        // Don't take over audio (summaries are read aloud by the app itself).
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        (layer as? AVPlayerLayer)?.player = player
        (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
        player.play()
    }

    required init?(coder: NSCoder) { fatalError() }
}
