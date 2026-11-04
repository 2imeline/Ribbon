import SwiftUI

@main
struct RibbonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var recorder = Recorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle" : "pause.circle")
        }

        Window("Clips", id: "library") { LibraryView() }
            .defaultSize(width: 1100, height: 720)
            .defaultLaunchBehavior(.suppressed)

        Window("Ribbon Settings", id: "settings") { SettingsView() }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
    }
}

private struct MenuContent: View {
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var updater = Updater.shared
    @AppStorage(K.hotkeyLabel) private var hotkey = Defaults.hotkeyLabel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(recorder.status)
        Button("Save Clip (\(hotkey))") { recorder.saveClip() }
            .disabled(!recorder.isRecording)
        Divider()
        Button("Open Clips…") { openWindow(id: "library"); NSApp.activate() }
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate() }
            .keyboardShortcut(",")
        Button(updater.available.map { "Update to \($0)…" } ?? "Check for Updates…") {
            Task { await updater.check(interactive: true) }
        }
        Divider()
        Button(recorder.userPaused ? "Resume Recording" : "Pause Recording") { recorder.userPaused.toggle() }
        Button("Quit Ribbon") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debounce: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Defaults.values)
        Hotkey.shared.action = { Recorder.shared.saveClip() }
        Hotkey.shared.register()
        Recorder.shared.restart()

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
        Task { await Updater.shared.check(interactive: false) }  // one tiny request per launch; only marks the menu
    }

    private func settingsChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            Recorder.shared.applySettings()
        }
    }
}
