import SwiftUI

@main
struct XcodeOffloadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Scan") {
                    Task { await model.scan() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
