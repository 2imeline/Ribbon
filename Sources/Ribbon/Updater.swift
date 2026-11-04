import AppKit
import RibbonCore

/// Updates from GitHub Releases: github.com/2imeline/Ribbon/releases/latest (Ribbon.zip).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published private(set) var available: String?
    @Published private(set) var busy = false

    static let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let assets: [Asset]
    }

    /// `interactive`: the user clicked, so show results and offer to install. Otherwise just set `available`.
    func check(interactive: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/2imeline/Ribbon/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw RibbonError("GitHub didn't answer. Try again in a bit.")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let build = buildNumber(fromTag: release.tag_name), build > Self.currentBuild,
                  let asset = release.assets.first(where: { $0.name == "Ribbon.zip" }) else {
                available = nil
                if interactive { alert("You're up to date", "Ribbon \(Self.currentVersion) is the latest version.") }
                return
            }
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            available = version
            guard interactive, confirm(version) else { return }
            try await install(from: asset.browser_download_url)
        } catch {
            if interactive { alert("Update failed", error.localizedDescription) }
        }
    }

    private func install(from url: URL) async throws {
        guard url.scheme == "https", url.host == "github.com" else { throw RibbonError("Unexpected download address.") }
        let target = Bundle.main.bundleURL
        guard !target.path.contains("/AppTranslocation/") else {
            throw RibbonError("Move Ribbon to your Applications folder first, then open it from there.")
        }

        let (zip, _) = try await URLSession.shared.download(from: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RibbonUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path)
        try? FileManager.default.removeItem(at: zip)

        let newApp = dir.appendingPathComponent("Ribbon.app")
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw RibbonError("The download isn't a Ribbon app.")
        }
        try Self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)

        // After Ribbon quits: swap the app in place (restoring the old one if anything fails), then relaunch.
        let script = """
        while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
        rm -rf "$1.old"
        mv "$1" "$1.old" || { open "$1"; exit 1; }
        if mv "$2" "$1"; then rm -rf "$1.old"; else mv "$1.old" "$1"; fi
        open "$1"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", target.path, newApp.path, String(ProcessInfo.processInfo.processIdentifier)]
        try swap.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RibbonError("The update couldn't be verified (\(tool) failed).") }
    }

    private func confirm(_ version: String) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Ribbon \(version) is available"
        a.informativeText = "You have \(Self.currentVersion). Ribbon will download the update and restart. Your clips and settings stay as they are."
        a.addButton(withTitle: "Update Now")
        a.addButton(withTitle: "Later")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
