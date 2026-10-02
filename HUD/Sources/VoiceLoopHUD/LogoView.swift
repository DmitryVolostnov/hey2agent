import AVFoundation
import AppKit
import SwiftUI

/// The animated logo, looping continuously (muted). Fills its frame edge to edge;
/// the panel card clips the corners.
struct LogoView: NSViewRepresentable {
    func makeNSView(context: Context) -> LogoPlayerView { LogoPlayerView() }
    func updateNSView(_ view: LogoPlayerView, context: Context) {}
}

final class LogoPlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        guard let url = Bundle.main.url(forResource: "badge", withExtension: "mp4") else { return }
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let pl = AVPlayerLayer(player: player)
        pl.videoGravity = .resizeAspectFill
        pl.frame = bounds
        pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(pl)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var occlusion: NSObjectProtocol?

    /// Play only while actually visible (no decoding while the panel is hidden, e.g. phone mode).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { player.pause(); return }
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPlayback() }
        }
        syncPlayback()
    }

    private func syncPlayback() {
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        visible ? player.play() : player.pause()
    }
}
