import SwiftUI

@main
struct VSLMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("VSL Mixer", id: "mixer") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1180, minHeight: 680)
                .onAppear { delegate.app = app }
        }
        .defaultSize(width: 1440, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Finishes any recording so the WAV headers are complete.
        MainActor.assumeIsolated { app?.shutdown() }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            Group {
                switch app.route {
                case .mixer: MixerView()
                case .eq(let s): ChannelEditorView(strip: s, tab: .eq)
                case .comp(let s): ChannelEditorView(strip: s, tab: .comp)
                case .feedback: FeedbackView()
                }
            }
            .environment(\.uiScale, min(1.8, max(1, min(geo.size.width / 1440, geo.size.height / 900))))
        }
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $app.showSetup) { SetupView().environment(app) }
        .sheet(isPresented: $app.showPhones) { PhonesView().environment(app).preferredColorScheme(.dark) }
    }
}
