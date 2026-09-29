import SwiftUI
import PolarisCore

@main
struct PolarisApp: App {
    private let message: String
    init() {
        if CommandLine.arguments.contains("--render-snapshots") { exit(0) }
        do {
            let state = try PolarisStore().read()
            message = state.today.northStar.isEmpty ? "今日の北極星は、まだない" : state.today.northStar
        } catch { message = "状態を読み込めません: \(error.localizedDescription)" }
    }
    var body: some Scene {
        WindowGroup("Polaris") { Text(message).padding(24).frame(minWidth: 280) }
    }
}
