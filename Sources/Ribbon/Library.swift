import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct Clip: Identifiable, Hashable {
    let url: URL
    let date: Date
    let game: String
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// File-level helpers for the clips folder.
enum Library {
    private static let gameAttribute = "app.ribbon.game"

    static var folder: URL {
        let path = UserDefaults.standard.string(forKey: K.folder) ?? Defaults.folder
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newClipURL(game: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return unique(folder.appendingPathComponent("\(sanitize(game)) \(f.string(from: Date())).mp4"))
    }

    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unique(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var candidate = url, i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return candidate
    }

    // The game is stored as an extended attribute so it survives renames.
    static func setGame(_ game: String, for url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let bytes = Array(game.utf8)
            _ = setxattr(path, gameAttribute, bytes, bytes.count, 0, 0)
        }
    }

    static func game(of url: URL) -> String {
        let value = url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let length = getxattr(path, gameAttribute, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: length)
            guard getxattr(path, gameAttribute, &bytes, length, 0, 0) == length else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        return value ?? "Other"
    }

    static func thumbURL(_ url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".thumbs", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent + ".jpg")
    }

    /// Cached JPEG next to the clips (hidden folder); generated on first view.
    static func thumbnail(for url: URL) async -> NSImage? {
        let thumb = thumbURL(url)
        if let image = NSImage(contentsOf: thumb) { return image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.appliesPreferredTrackTransform = true
        guard let cg = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
        try? FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(thumb as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    static func copyToPasteboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    /// Lossless trim (no re-encode). Cuts land on the nearest keyframe, about 1 s accuracy.
    static func trim(_ url: URL, from start: CMTime, to end: CMTime) async throws -> URL {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough)
        else { throw RibbonError("This clip can't be trimmed.") }
        session.timeRange = CMTimeRange(start: start, end: end)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try await session.export(to: tmp, as: .mp4)
        setGame(game(of: url), for: tmp)
        let out = unique(url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (trimmed).mp4"))
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published var error: String?
    private var watcher: DispatchSourceFileSystemObject?

    func start() {
        reload()
        guard watcher == nil else { return }
        let fd = open(Library.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.reload() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Library.folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        clips = urls
            .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
            .map { url in
                Clip(url: url,
                     date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                     game: Library.game(of: url))
            }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        let clean = Library.sanitize(name)
        guard !clean.isEmpty else { return nil }
        let dest = url.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension(url.pathExtension)
        guard dest != url else { return url }
        if FileManager.default.fileExists(atPath: dest.path) && dest.path.lowercased() != url.path.lowercased() {
            error = "A clip named “\(clean)” already exists."
            return nil
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            try? FileManager.default.moveItem(at: Library.thumbURL(url), to: Library.thumbURL(dest))
            reload()
            return dest
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            try? FileManager.default.removeItem(at: Library.thumbURL(url))
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }
}
