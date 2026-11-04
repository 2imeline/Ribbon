import AppKit
import AVFoundation
import RibbonCore
import ScreenCaptureKit

struct Chunk: TimedSample {
    let buffer: CMSampleBuffer
    let time: Double
    let isKeyframe: Bool
}

enum AudioSource { case system, mic, discord }

/// The capture hot path. All mutable state is touched only on `queue`.
final class ReplayBuffer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.ribbon.capture", qos: .userInitiated)
    var onStop: (@MainActor (Error) -> Void)?

    private var encoder: Encoder?
    private weak var discordStream: SCStream?
    private var seconds: Double = 30
    private var video = ClipRing<Chunk>(maxDuration: 30)
    private var audio: [AudioSource: ClipRing<Chunk>] = [:]

    func reset(encoder: Encoder?, seconds: Int) {
        queue.sync {
            self.encoder?.invalidate()
            self.encoder = encoder
            self.discordStream = nil
            self.seconds = Double(seconds)
            self.video = ClipRing(maxDuration: Double(seconds))
            self.audio = [:]
        }
    }

    func setSeconds(_ s: Int) {
        queue.async {
            self.seconds = Double(s)
            self.video.maxDuration = self.seconds
            for key in self.audio.keys { self.audio[key]?.maxDuration = self.seconds + 1 }
        }
    }

    func setDiscordStream(_ stream: SCStream) { queue.sync { discordStream = stream } }

    func snapshot() -> (video: [Chunk], audio: [[Chunk]]) {
        queue.sync { (video.samples, audio.values.map(\.samples)) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // SCK only sends .complete when the screen actually changed; idle frames cost nothing.
            guard stream !== discordStream, let encoder, Self.isComplete(sb), let pb = sb.imageBuffer else { return }
            encoder.encode(pb, at: sb.presentationTimeStamp)
        case .audio:
            appendAudio(sb, to: stream === discordStream ? .discord : .system)
        case .microphone:
            appendAudio(sb, to: .mic)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onStop?(error) }
    }

    /// Called from VideoToolbox's thread with an encoded frame.
    func appendVideo(_ sb: CMSampleBuffer, from enc: Encoder) {
        queue.async {
            guard enc === self.encoder else { return }  // drop late frames from a previous session
            self.video.append(Chunk(buffer: sb, time: sb.presentationTimeStamp.seconds, isKeyframe: sb.isKeyframe))
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to source: AudioSource) {
        guard let copy = sb.deepCopiedAudio() else { return }
        audio[source, default: ClipRing(maxDuration: seconds + 1)]
            .append(Chunk(buffer: copy, time: copy.presentationTimeStamp.seconds, isKeyframe: true))
    }

    private static func isComplete(_ sb: CMSampleBuffer) -> Bool {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}

@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var status = "Starting…"
    @Published var userPaused = false { didSet { if oldValue != userPaused { restart() } } }
    /// Apps that can be picked as a capture target (refreshed when apps launch or quit).
    @Published private(set) var apps: [RunningApp] = []
    /// The game Auto mode found, if any (bundle ID).
    @Published private(set) var detectedGame: String?
    /// Name of the app being captured on its own, or nil for the whole screen.
    @Published private(set) var targetName: String?

    private var systemPaused = false
    private let buffer = ReplayBuffer()
    private var streams: [SCStream] = []
    private var running: Config?
    private var task: Task<Void, Never>?

    private init() {
        buffer.onStop = { [weak self] error in self?.streamStopped(error) }

        let ws = NSWorkspace.shared.notificationCenter
        let pausing: [(NSNotification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, paused) in pausing {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSystemPaused(paused) }
            }
        }
        let dnc = DistributedNotificationCenter.default()
        for (name, paused) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSystemPaused(paused) }
            }
        }
        // Game detection and target apps only change when apps launch, quit or switch: no polling.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                let activation = note.name == NSWorkspace.didActivateApplicationNotification
                Task { @MainActor in self?.appsChanged(id: id, activation: activation) }
            }
        }
        apps = GameDetector.pickableApps()
        updateDetectedGame()
    }

    private func appsChanged(id: String?, activation: Bool) {
        if !activation { apps = GameDetector.pickableApps() }
        updateDetectedGame()
        // Discord's windows/audio are resolved when capture starts, so refresh if it opens or quits.
        if !activation, let id, discordBundleIDs.contains(id), let c = running, !(c.game && c.discord && c.target == nil) {
            restart()
        } else {
            applySettings()
        }
    }

    /// Auto mode: the frontmost game wins; otherwise keep the last one while it runs; otherwise any running game.
    private func updateDetectedGame() {
        let launched = NSWorkspace.shared.runningApplications
        if let front = NSWorkspace.shared.frontmostApplication, GameDetector.isGame(front) {
            detectedGame = front.bundleIdentifier
        } else if let current = detectedGame, launched.contains(where: { $0.bundleIdentifier == current }) {
            return
        } else {
            detectedGame = launched.first { GameDetector.isGame($0) }?.bundleIdentifier
        }
    }

    /// What to capture right now: an app's bundle ID (only if it's running), or nil for the whole screen.
    private func resolvedTarget() -> String? {
        let choice = UserDefaults.standard.string(forKey: K.target) ?? Target.auto
        switch choice {
        case Target.screen: return nil
        case Target.auto: return detectedGame
        default: return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == choice } ? choice : nil
        }
    }

    // MARK: Control

    func restart() {
        let previous = task
        task = Task {
            await previous?.value
            await stopStreams()
            if !userPaused && !systemPaused { await startStreams() }
        }
    }

    /// Called (debounced) whenever settings change. Clip length applies live; everything else restarts capture.
    func applySettings() {
        let new = Config.current(target: resolvedTarget())
        guard new != running else { return }
        if var old = running, isRecording {
            old.clipSeconds = new.clipSeconds
            if old == new {
                running = new
                buffer.setSeconds(new.clipSeconds)
                status = recordingStatus(new)
                return
            }
        }
        if !userPaused && !systemPaused { restart() }
    }

    func saveClip() {
        let snap = buffer.snapshot()
        guard !snap.video.isEmpty else { NSSound.beep(); return }
        let front = NSWorkspace.shared.frontmostApplication
        let frontName = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front?.localizedName
        let game = targetName ?? frontName ?? "Clip"
        let url = Library.newClipURL(game: game)
        let sound = UserDefaults.standard.bool(forKey: K.sound)
        Task.detached(priority: .utility) {
            do {
                try await ClipWriter.write(video: snap.video, audio: snap.audio, game: game, to: url)
                if sound { await MainActor.run { _ = NSSound(named: "Tink")?.play() } }
            } catch {
                await MainActor.run {
                    Recorder.shared.status = "Couldn't save clip: \(error.localizedDescription)"
                    _ = NSSound(named: "Basso")?.play()
                }
            }
        }
    }

    // MARK: Pipeline

    private func setSystemPaused(_ paused: Bool) {
        guard systemPaused != paused else { return }
        systemPaused = paused
        restart()
    }

    private func streamStopped(_ error: Error) {
        guard isRecording else { return }
        if (error as NSError).code == SCStreamError.Code.userStopped.rawValue {
            userPaused = true  // stopped from the macOS screen-recording menu: respect it
            return
        }
        status = "Recording stopped: \(error.localizedDescription)"
        Task {
            try? await Task.sleep(for: .seconds(2))
            restart()
        }
    }

    private func stopStreams() async {
        for stream in streams { try? await stream.stopCapture() }
        streams = []
        buffer.reset(encoder: nil, seconds: 30)
        running = nil
        isRecording = false
        targetName = nil
        status = userPaused ? "Paused" : systemPaused ? "Paused while the screen is off" : "Starting…"
    }

    private func startStreams() async {
        let cfg = Config.current(target: resolvedTarget())
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            status = "Allow Ribbon in System Settings › Privacy & Security › Screen Recording, then reopen Ribbon."
            return
        }
        if cfg.mic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let discordApps = content.applications.filter { discordBundleIDs.contains($0.bundleIdentifier) }
            let targetApp = cfg.target.flatMap { id in content.applications.first { $0.bundleIdentifier == id } }

            // Capture the display the target app's biggest window is on (else the main display).
            let targetWindow = targetApp.flatMap { app in
                content.windows
                    .filter { $0.isOnScreen && $0.owningApplication?.processID == app.processID && $0.frame.width > 100 }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            }
            let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
            guard let display = targetWindow.flatMap({ w in
                content.displays.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }
            }) ?? mainDisplay else { throw RibbonError("No display found.") }

            // Scale on the GPU (inside ScreenCaptureKit) to the target height, keeping the display's aspect.
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let nativeW = mode?.pixelWidth ?? display.width, nativeH = mode?.pixelHeight ?? display.height
            let h = (cfg.height > 0 ? min(cfg.height, nativeH) : nativeH) & ~1
            let w = (nativeW * h / nativeH) & ~1

            let encoder = try Encoder(width: w, height: h, fps: cfg.fps, bitrateMbps: cfg.bitrate, hevc: cfg.hevc)
            encoder.onOutput = { [weak buffer = self.buffer] sample, enc in buffer?.appendVideo(sample, from: enc) }
            buffer.reset(encoder: encoder, seconds: cfg.clipSeconds)

            let sc = SCStreamConfiguration()
            sc.width = w
            sc.height = h
            sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
            sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // the encoder's native format
            sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            sc.colorSpaceName = CGColorSpace.itur_709
            sc.queueDepth = 4
            sc.showsCursor = true
            sc.capturesAudio = cfg.game
            sc.excludesCurrentProcessAudio = true
            sc.sampleRate = 48_000
            sc.channelCount = 2
            sc.captureMicrophone = cfg.mic
            if cfg.mic && !cfg.micID.isEmpty { sc.microphoneCaptureDeviceID = cfg.micID }

            // A target app is captured on its own: only its windows and only its audio.
            // Whole screen: everything except Ribbon (and Discord, when Discord is off).
            let filter = targetApp.map { SCContentFilter(display: display, including: [$0], exceptingWindows: []) }
                ?? SCContentFilter(display: display, excludingApplications: cfg.discord ? me : me + discordApps, exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: sc, delegate: buffer)
            try stream.addStreamOutput(buffer, type: .screen, sampleHandlerQueue: buffer.queue)
            if cfg.game { try stream.addStreamOutput(buffer, type: .audio, sampleHandlerQueue: buffer.queue) }
            if cfg.mic { try stream.addStreamOutput(buffer, type: .microphone, sampleHandlerQueue: buffer.queue) }
            streams = [stream]
            try await stream.startCapture()

            // Discord audio that the main stream doesn't include: a tiny audio-only stream of just Discord.
            let targetIsDiscord = targetApp.map { discordBundleIDs.contains($0.bundleIdentifier) } ?? false
            if cfg.discord && !discordApps.isEmpty && !targetIsDiscord && (!cfg.game || targetApp != nil) {
                let ac = SCStreamConfiguration()
                ac.width = 2
                ac.height = 2
                ac.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                ac.queueDepth = 3
                ac.capturesAudio = true
                ac.sampleRate = 48_000
                ac.channelCount = 2
                let ds = SCStream(filter: SCContentFilter(display: display, including: discordApps, exceptingWindows: []),
                                  configuration: ac, delegate: buffer)
                buffer.setDiscordStream(ds)
                try ds.addStreamOutput(buffer, type: .screen, sampleHandlerQueue: buffer.queue)
                try ds.addStreamOutput(buffer, type: .audio, sampleHandlerQueue: buffer.queue)
                streams.append(ds)
                try await ds.startCapture()
            }

            running = cfg
            isRecording = true
            targetName = targetApp?.applicationName
            status = recordingStatus(cfg)
        } catch {
            await stopStreams()
            status = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    private func recordingStatus(_ c: Config) -> String {
        "Recording \(targetName ?? "whole screen") · last \(Config.describe(seconds: c.clipSeconds))"
    }
}
