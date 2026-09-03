import SwiftUI

@main
struct KairosApp: App {
    @State private var model = CodeModel()
    @State private var sync = SyncSession()

    var body: some Scene {
        WindowGroup {
            AccountListView()
                .environment(model)
                .environment(sync)
                .onAppear {
                    model.load()
                    sync.activate(into: model)
                }
        }
    }
}
