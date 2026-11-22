import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.runBlocking())
        }
        MessengerApp.main()
    }
}

struct MessengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("HPAIF Messenger") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Group Chat…") { model.showingNewGroup = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When started with `swift run` there is no app bundle: make it a regular app
        // with a Dock icon and bring its window to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
