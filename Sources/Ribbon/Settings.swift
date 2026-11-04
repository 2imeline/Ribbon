import Carbon.HIToolbox
import Foundation

/// UserDefaults keys. Views use @AppStorage with these; the capture side reads `Config.current()`.
enum K {
    static let clipSeconds = "clipSeconds"
    static let height = "height"          // 0 = native
    static let fps = "fps"
    static let bitrate = "bitrateMbps"
    static let hevc = "hevc"
    static let game = "gameAudio"
    static let discord = "discordAudio"
    static let mic = "micAudio"
    static let micID = "micDeviceID"      // "" = system default
    static let folder = "saveFolder"
    static let sound = "saveSound"
    static let hotkeyCode = "hotkeyCode"
    static let hotkeyMods = "hotkeyMods"
    static let hotkeyLabel = "hotkeyLabel"
}

enum Defaults {
    static let folder = "~/Movies/Ribbon"
    static let hotkeyLabel = "⌥⇧C"
    static let values: [String: Any] = [
        K.clipSeconds: 30, K.height: 1080, K.fps: 60, K.bitrate: 15, K.hevc: false,
        K.game: true, K.discord: true, K.mic: true, K.micID: "",
        K.folder: folder, K.sound: true,
        K.hotkeyCode: kVK_ANSI_C, K.hotkeyMods: optionKey | shiftKey, K.hotkeyLabel: hotkeyLabel,
    ]
}

let discordBundleIDs: Set<String> = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]

/// Everything that requires rebuilding the capture pipeline when it changes (except clipSeconds).
struct Config: Equatable {
    var clipSeconds: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var hevc: Bool
    var game: Bool
    var discord: Bool
    var mic: Bool
    var micID: String

    static func current() -> Config {
        let d = UserDefaults.standard
        return Config(
            clipSeconds: min(max(d.integer(forKey: K.clipSeconds), 5), 600),
            height: max(d.integer(forKey: K.height), 0),
            fps: min(max(d.integer(forKey: K.fps), 1), 120),
            bitrate: min(max(d.integer(forKey: K.bitrate), 1), 100),
            hevc: d.bool(forKey: K.hevc),
            game: d.bool(forKey: K.game),
            discord: d.bool(forKey: K.discord),
            mic: d.bool(forKey: K.mic),
            micID: d.string(forKey: K.micID) ?? ""
        )
    }

    static func describe(seconds s: Int) -> String {
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }
}

struct RibbonError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
