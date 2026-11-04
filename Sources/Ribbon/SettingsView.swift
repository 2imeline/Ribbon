import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(K.clipSeconds) private var clipSeconds = 30
    @AppStorage(K.height) private var height = 1080
    @AppStorage(K.fps) private var fps = 60
    @AppStorage(K.bitrate) private var bitrate = 15
    @AppStorage(K.hevc) private var hevc = false
    @AppStorage(K.game) private var game = true
    @AppStorage(K.discord) private var discord = true
    @AppStorage(K.mic) private var mic = true
    @AppStorage(K.micID) private var micID = ""
    @AppStorage(K.folder) private var folder = Defaults.folder
    @AppStorage(K.sound) private var sound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @ObservedObject private var updater = Updater.shared

    private let mics = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices

    /// Encoded video + raw PCM per audio source (48 kHz stereo float ≈ 384 KB/s).
    private var memoryMB: Int {
        let sources = (game ? 1 : 0) + (discord && !game ? 1 : 0) + (mic ? 1 : 0)
        return bitrate * clipSeconds / 8 + sources * clipSeconds * 384 / 1000
    }

    var body: some View {
        Form {
            Section {
                TargetPicker()
                LabeledContent("Clip length") {
                    HStack {
                        TextField("", value: $clipSeconds, format: .number)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $clipSeconds, in: 5...600, step: 15).labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Save clip shortcut") { HotkeyRecorder() }
            } header: {
                Text("Replay")
            } footer: {
                Text("Auto records just the game you're playing (its window and its audio) and records the whole screen when no game is open.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Resolution", selection: $height) {
                    Text("Native").tag(0)
                    Text("1440p").tag(1440)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                Picker("Frame rate", selection: $fps) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                }
                LabeledContent("Bitrate") {
                    HStack {
                        TextField("", value: $bitrate, format: .number)
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $bitrate, in: 1...100).labelsHidden()
                        Text("Mbps").foregroundStyle(.secondary)
                    }
                }
                Picker("Codec", selection: $hevc) {
                    Text("H.264 (plays everywhere)").tag(false)
                    Text("HEVC (smaller files)").tag(true)
                }
            } header: {
                Text("Video")
            } footer: {
                Text("Uses about \(memoryMB) MB of memory. Nothing is written to disk until you save a clip.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Game / app audio", isOn: $game)
                Toggle("Discord", isOn: $discord)
                Toggle("Microphone", isOn: $mic)
                Picker("Microphone device", selection: $micID) {
                    Text("System default").tag("")
                    ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .disabled(!mic)
            } header: {
                Text("Audio")
            } footer: {
                if game && !discord {
                    Text("With Discord off, Discord's windows are hidden from clips too.").foregroundStyle(.secondary)
                }
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…", action: chooseFolder)
                    }
                }
                Toggle("Play a sound when a clip is saved", isOn: $sound)
                Toggle("Open Ribbon at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section("About") {
                LabeledContent("Version", value: Updater.currentVersion)
                Button(updater.available.map { "Update to \($0)…" } ?? "Check for Updates…") {
                    Task { await updater.check(interactive: true) }
                }
                .disabled(updater.busy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onAppear { NSApp.activate() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Library.folder
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }
}

/// Auto (detect games) / Whole Screen / any running app. Used in the menu bar and in Settings.
struct TargetPicker: View {
    @AppStorage(K.target) private var target = Target.auto
    @ObservedObject private var recorder = Recorder.shared

    private var autoLabel: String {
        guard let id = recorder.detectedGame else { return "Auto (detect games)" }
        return "Auto: \(recorder.apps.first { $0.id == id }?.name ?? GameDetector.name(of: id))"
    }

    private var isMissingApp: Bool {
        target != Target.auto && target != Target.screen && !recorder.apps.contains { $0.id == target }
    }

    var body: some View {
        Picker("Record", selection: $target) {
            Text(autoLabel).tag(Target.auto)
            Text("Whole Screen").tag(Target.screen)
            Divider()
            ForEach(recorder.apps) { Text($0.name).tag($0.id) }
            if isMissingApp { Text("\(GameDetector.name(of: target)) (not running)").tag(target) }
        }
    }
}
