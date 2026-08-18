import SwiftUI
import Darwin

@main
struct CodexProviderMigratorApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
