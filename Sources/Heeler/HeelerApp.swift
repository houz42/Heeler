import SwiftUI

/// App entry point. M0 ships only the buildable skeleton; the Console UI
/// arrives in M1 once the Transport underneath it exists.
@main
struct HeelerApp: App {
    /// APNs delivers device tokens through UIApplicationDelegate callbacks
    /// only, so push bootstrap (#71) needs this adaptor.
    @UIApplicationDelegateAdaptor(PushRegistrationDelegate.self)
    private var pushDelegate
    /// The aggregate phase across every window: active while any one is.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? ImagePreparer.cleanupRemnants()
        try? FilePreparer.cleanupRemnants()
        // Capture diagnostic (env-gated, inert without the flag): the
        // device-key authorized_keys line for out-of-band proof
        // authorization (TEMP proof infra; never in release).
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["HEELER_DIAG_DEVICE_KEY"] == "1" {
                var line = "HEELER_DIAG env seen; "
                do {
                    let device = try HostCredentialsProvider().deviceKey()
                    line += device.authorizedKeysLine(comment: "heeler-proof")
                } catch {
                    line += "FAILED: \(error)"
                }
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: "/tmp/heeler-proof-signals"),
                    withIntermediateDirectories: true)
                try? line.write(
                    to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/key2.pub"),
                    atomically: true, encoding: .utf8)
            }
        #endif
    }

    var body: some Scene {
        // Valued by the Agent a window shows, so Open in New Window and a
        // dragged Console row each get a window restored to their Agent. A
        // cold launch opens the Console with no value.
        WindowGroup(for: AgentRoute.self) { $route in
            #if DEBUG && targetEnvironment(simulator)
                if DemoScreenshotMode.isEnabled {
                    DemoScreenshotRootView()
                } else {
                    productionContent(route: $route)
                }
            #else
                productionContent(route: $route)
            #endif
        }
        .commands { ConsoleCommands() }
        .onChange(of: scenePhase) {
            #if DEBUG && targetEnvironment(simulator)
                guard !DemoScreenshotMode.isEnabled else { return }
            #endif
            pushDelegate.appModel.scenePhaseDidChange(scenePhase)
        }
    }

    private func productionContent(route: Binding<AgentRoute?>) -> some View {
        ContentView(app: pushDelegate.appModel, windowRoute: route)
    }
}
