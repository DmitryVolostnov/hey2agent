import AVFoundation
import AppKit
import SwiftUI

/// The animated logo: rests on its first frame, plays once every `interval` seconds.
struct LogoView: NSViewRepresentable {
    var interval: TimeInterval = 40

    func makeNSView(context: Context) -> LogoPlayerView { LogoPlayerView(interval: interval) }
    func updateNSView(_ view: LogoPlayerView, context: Context) {}
}

final class LogoPlayerView: NSView {
    private let player: AVPlayer?
    private var timer: Timer?

    init(interval: TimeInterval) {
        let url = Bundle.main.url(forResource: "badge", withExtension: "mp4")
        player = url.map { AVPlayer(url: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        guard let player else { return }
        player.isMuted = true
        player.actionAtItemEnd = .pause
        let pl = AVPlayerLayer(player: player)
        pl.videoGravity = .resizeAspectFill
        pl.frame = bounds
        pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(pl)
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)  // freeze on the first frame (= the static logo)
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate() }
    }
}
