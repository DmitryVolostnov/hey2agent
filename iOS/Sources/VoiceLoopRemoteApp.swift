import SwiftUI
import UIKit

@main
struct VoiceLoopRemoteApp: App {
    @State private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.paired && model.status != .badCode {
                    RemoteView(model: model)
                } else {
                    PairingView(model: model)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true  // always-on screen next to the laptop
                model.start()
            }
            .onChange(of: phase) { _, now in
                if now == .background { model.goAway() }
                if now == .active { model.comeBack() }
            }
        }
    }
}
