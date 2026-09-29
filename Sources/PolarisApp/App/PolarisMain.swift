import AppKit

@main
enum PolarisMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-snapshots") {
            let dir = index + 1 < args.count ? args[index + 1] : "snapshots"
            _ = NSApplication.shared
            let code = SnapshotRenderer.run(to: URL(fileURLWithPath: dir, isDirectory: true))
            exit(code)
        }
        let app = NSApplication.shared
        let delegate = AppCoordinator()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
