import AppKit

struct RunningApp: Hashable, Identifiable {
    let id: String   // bundle identifier
    let name: String
}

/// Decides whether a running app is a game. Checked only when apps launch, quit or switch,
/// and cached per bundle ID, so it costs nothing while you play.
@MainActor
enum GameDetector {
    private static let known: Set<String> = [
        "com.roblox.RobloxPlayer",
        "com.riotgames.LeagueofLegends.GameClient",
        "com.blizzard.worldofwarcraft",
        "com.blizzard.starcraft2",
        "com.blizzard.diablo3",
        "com.blizzard.hearthstone",
        "com.mojang.minecraftpe",
        "com.nvidia.gfnpc.mall",          // GeForce NOW
        "com.valvesoftware.dota2",
        "com.valvesoftware.portal2",
        "unity.Innersloth.Among Us",
    ]
    private static let notGames: Set<String> = [
        "com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "com.roblox.RobloxStudio",
        "com.riotgames.RiotGames.RiotClient", "com.blizzard.bnetlauncher",
    ]
    private static var cache: [String: Bool] = [:]

    static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        if let hit = cache[id] { return hit }
        let result = check(id: id, url: app.bundleURL)
        cache[id] = result
        return result
    }

    private static func check(id: String, url: URL?) -> Bool {
        if notGames.contains(id) { return false }
        if known.contains(id) { return true }
        guard let url else { return false }
        // Steam/Epic installs, and anything that declares a games category (App Store, Arcade, most ports).
        let path = url.path
        if path.contains("/steamapps/common/") || path.contains("/Epic Games/") { return true }
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
        return category.hasPrefix("public.app-category.") && category.hasSuffix("games")
    }

    /// Apps you can pick as a capture target: regular (Dock) apps, not Ribbon itself.
    static func pickableApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { RunningApp(id: $0, name: app.localizedName ?? $0) } }
            .reduce(into: [RunningApp]()) { list, app in if !list.contains(where: { $0.id == app.id }) { list.append(app) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func name(of bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

/// Values stored in K.target besides a bundle ID.
enum Target {
    static let auto = "auto"
    static let screen = "screen"  // the main display; "screen:<CGDirectDisplayID>" is a specific one

    static func isScreen(_ value: String) -> Bool { value == screen || value.hasPrefix(screen + ":") }
}
