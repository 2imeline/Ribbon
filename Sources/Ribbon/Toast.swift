import AppKit
import SwiftUI

/// A small popup at the top of the screen that shows over fullscreen games and never takes focus.
/// It stays out of clips: whole-screen capture excludes Ribbon's windows and app capture only includes the game.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hide: Task<Void, Never>?

    static func show(_ text: String, icon: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = NSHostingView(rootView: ToastView(text: text, icon: icon))
        panel.contentView = view
        let size = view.fittingSize
        let screen = NSScreen.main?.frame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 48,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }

        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.35; panel.animator().alphaValue = 0 }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.sharingType = .none
        p.alphaValue = 0
        return p
    }
}

private struct ToastView: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.tint)
            Text(text).font(.headline)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .padding(16)  // room for the shadow inside the panel
    }
}
