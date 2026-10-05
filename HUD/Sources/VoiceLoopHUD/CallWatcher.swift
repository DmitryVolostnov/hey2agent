import CoreAudio
import Foundation

/// Auto-mute during calls: macOS tells which processes are using the microphone right now.
/// Only apps from the list below count (a call app or a screen recorder holding the mic for a
/// while), so always-listening tools like Screenpipe or Open Loops never mute the panel.
@MainActor
final class CallWatcher {
    /// Bundle-ID prefixes → seconds the app must hold the mic before we mute.
    static let callApps: [(prefix: String, name: String)] = [
        // Video calls
        ("us.zoom.", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"), ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"), ("com.skype.", "Skype"), ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"), ("co.teamport.around", "Around"), ("app.tuple.", "Tuple"),
        ("com.gather.", "Gather"), ("com.pop.", "Pop"), ("com.google.meet", "Google Meet"),
        // Messengers with calls
        ("com.tinyspeck.slackmacgap", "Slack"), ("ru.keepcoder.Telegram", "Telegram"),
        ("org.telegram.desktop", "Telegram"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"),
        ("org.whispersystems.signal-desktop", "Signal"), ("com.viber.osx", "Viber"),
        ("com.facebook.archon", "Messenger"), ("ru.yandex.telemost", "Telemost"), ("com.vk.calls", "VK Calls"),
        ("Mattermost.Desktop", "Mattermost"), ("chat.rocket", "Rocket.Chat"), ("com.apple.mobilephone", "Phone"),
        // Screen / video recording
        ("com.loom.desktop", "Loom"), ("com.obsproject.obs-studio", "OBS"), ("com.apple.QuickTimePlayerX", "QuickTime"),
        ("pl.maketheweb.cleanshotx", "CleanShot"), ("net.telestream.screenflow", "ScreenFlow"),
    ]
    /// Browsers also hold the mic for voice typing on websites, so only a long hold counts (a call).
    static let browsers: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("company.thebrowser.", "Arc"), ("org.mozilla.firefox", "Firefox"), ("com.microsoft.edgemac", "Edge"),
        ("com.operasoftware.Opera", "Opera"), ("ru.yandex.desktop.yandex-browser", "Yandex Browser"),
        ("com.brave.Browser", "Brave"), ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]
    static let appDelay: TimeInterval = 15
    static let browserDelay: TimeInterval = 60

    private var since: [String: Date] = [:]  // app name → holding the mic since
    private var lastCheck = Date.distantPast

    /// The call app that has held the mic long enough, or nil. Cheap; call it every tick.
    func check(extra: [String], ignored: [String]) -> String? {
        guard Date().timeIntervalSince(lastCheck) > 2 else { return current }
        lastCheck = Date()
        let holding = Set(Self.processesUsingMic().compactMap { Self.callName(for: $0, extra: extra, ignored: ignored) })
        let now = Date()
        for name in holding where since[name] == nil { since[name] = now }
        since = since.filter { holding.contains($0.key) }
        current = since.first { entry in
            let delay = Self.browsers.contains { $0.name == entry.key } ? Self.browserDelay : Self.appDelay
            return now.timeIntervalSince(entry.value) >= delay
        }?.key
        return current
    }
    private var current: String?

    private static func callName(for bundleID: String, extra: [String], ignored: [String]) -> String? {
        if ignored.contains(where: { bundleID.hasPrefix($0) }) { return nil }
        if let hit = (callApps + browsers).first(where: { bundleID.hasPrefix($0.prefix) }) { return hit.name }
        return extra.first { bundleID.hasPrefix($0) }
    }

    /// Bundle IDs of the processes whose audio input is running (macOS 14.2+ process objects).
    static func processesUsingMic() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> String? in
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            var bsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var baddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &baddr, 0, nil, &bsize, &bundle) == noErr,
                  let b = bundle?.takeRetainedValue() as String?, !b.isEmpty else { return nil }
            return b
        }
    }
}
