import SwiftUI

@main
struct AwqatApp: App {
    @State private var model = PrayerModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    model.start()
                    await model.requestNotificationPermission()
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            TimetableView()
            QiblaView()
            TasbihView()
            SettingsView()
        }
        .tabViewStyle(.verticalPage)
    }
}
