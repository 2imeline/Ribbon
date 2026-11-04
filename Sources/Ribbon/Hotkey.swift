import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide hotkey via Carbon. Works in fullscreen games and needs no Accessibility permission.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    var action: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register() {
        let d = UserDefaults.standard
        register(keyCode: UInt32(d.integer(forKey: K.hotkeyCode)), modifiers: UInt32(d.integer(forKey: K.hotkeyMods)))
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in Hotkey.shared.action() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5242_4E4E), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// Click, then press the new shortcut. Esc cancels.
struct HotkeyRecorder: View {
    @AppStorage(K.hotkeyLabel) private var label = Defaults.hotkeyLabel
    @State private var monitor: Any?

    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    var body: some View {
        Button(monitor == nil ? label : "Press a shortcut…") { monitor == nil ? start() : stop() }
            .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { stop(); return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let fKey = Self.fKeys[Int(event.keyCode)]
        guard !flags.isEmpty || fKey != nil else { NSSound.beep(); return }  // plain letters would break typing

        var carbon = 0, symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }

        let d = UserDefaults.standard
        d.set(Int(event.keyCode), forKey: K.hotkeyCode)
        d.set(carbon, forKey: K.hotkeyMods)
        label = symbols + (fKey ?? (event.charactersIgnoringModifiers ?? "?").uppercased())
        Hotkey.shared.register()
        stop()
    }
}
