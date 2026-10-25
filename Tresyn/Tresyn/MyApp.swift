import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 650)
        .windowResizability(.contentSize)
        .commands {
            SceneCommands()
        }
    }
}

private struct SceneCommands: Commands {
    @FocusedObject private var session: DrawingSession?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") {
                session?.requestSceneOpen()
            }
            .keyboardShortcut("o")
            .disabled(session?.canTransferScene != true)
        }

        CommandGroup(before: .saveItem) {
            Button("Save…") {
                session?.requestSceneSave()
            }
            .keyboardShortcut("s")
            .disabled(session?.canTransferScene != true)

            Button("Export USDZ…") {
                session?.requestUSDZExport()
            }
            .disabled(session?.canTransferScene != true)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                session?.undo()
            }
            .keyboardShortcut("z")
            .disabled(session?.canUndo != true)

            Button("Redo") {
                session?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(session?.canRedo != true)
        }
    }
}
