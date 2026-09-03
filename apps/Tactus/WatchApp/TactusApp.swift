import SwiftUI

@main
struct TactusApp: App {
    @State private var engine = MetronomeEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            PlayView()
            PresetsView()
            SettingsView()
        }
        .tabViewStyle(.verticalPage)
    }
}
