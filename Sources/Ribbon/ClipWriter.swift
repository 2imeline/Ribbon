import AVFoundation

/// Turns a replay-buffer snapshot into an .mp4. Video is never re-encoded (pure copy);
/// audio sources are mixed into one AAC track so Discord, browsers and phones play everything.
enum ClipWriter {
    private typealias Job = (AVAssetWriterInput, () -> CMSampleBuffer?)

    static func write(video: [Chunk], audio: [[Chunk]], game: String, to url: URL) async throws {
        guard let first = video.first else { throw RibbonError("Nothing recorded yet.") }
        let tracks = audio.map { $0.filter { $0.time >= first.time - 0.1 } }.filter { !$0.isEmpty }
        let tmp = FileManager.default.temporaryDirectory
        let raw = tmp.appendingPathComponent(UUID().uuidString + ".mov")
        let final = tmp.appendingPathComponent(UUID().uuidString + ".mp4")
        defer {
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.removeItem(at: final)
        }

        // Pass 1: video passthrough + each audio source as PCM.
        let writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: first.buffer.formatDescription)
        writer.add(v)
        var jobs: [Job] = [(v, iterate(video))]
        for track in tracks {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings(track[0].buffer.formatDescription))
            writer.add(a)
            jobs.append((a, iterate(track)))
        }
        try await run(writer, from: first.buffer.presentationTimeStamp, jobs)

        // Pass 2: mix audio down to one AAC track, fast-start mp4. Takes a fraction of a second.
        try await remux(raw, to: final)
        Library.setGame(game, for: final)
        // Move in only when complete, so the library never sees a half-written file.
        try FileManager.default.moveItem(at: final, to: url)
    }

    private static func remux(_ src: URL, to dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw RibbonError("The recording has no video.") }
        let aTracks = try await asset.loadTracks(withMediaType: .audio)

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        reader.add(vOut)

        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                     sourceFormatHint: try await vTrack.load(.formatDescriptions).first)
        writer.add(vIn)

        var aOut: AVAssetReaderAudioMixOutput?
        var aIn: AVAssetWriterInput?
        if !aTracks.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(mix)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            writer.add(input)
            aOut = mix
            aIn = input
        }

        guard reader.startReading() else { throw reader.error ?? RibbonError("Couldn't read the recording.") }
        guard let firstVideo = vOut.copyNextSampleBuffer() else { throw RibbonError("The recording is empty.") }
        var pending: CMSampleBuffer? = firstVideo
        var jobs: [Job] = [(vIn, {
            if let p = pending { pending = nil; return p }
            return vOut.copyNextSampleBuffer()
        })]
        if let aOut, let aIn { jobs.append((aIn, { aOut.copyNextSampleBuffer() })) }

        try await run(writer, from: firstVideo.presentationTimeStamp, jobs)
        if reader.status == .failed { throw reader.error ?? RibbonError("Couldn't read the recording.") }
    }

    private static func run(_ writer: AVAssetWriter, from start: CMTime, _ jobs: [Job]) async throws {
        guard writer.startWriting() else { throw writer.error ?? RibbonError("Couldn't start writing the clip.") }
        writer.startSession(atSourceTime: start)
        await withTaskGroup(of: Void.self) { group in
            for (input, next) in jobs {
                group.addTask { await pump(input, writer, next) }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RibbonError("Couldn't finish the clip.") }
    }

    /// Feeds one input until `next` runs dry. Inputs run concurrently so the writer can interleave them.
    private static func pump(_ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ next: @escaping () -> CMSampleBuffer?) async {
        let queue = DispatchQueue(label: "app.ribbon.write", qos: .utility)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while !finished && input.isReadyForMoreMediaData {
                    guard writer.status == .writing, let sample = next(), input.append(sample) else {
                        finished = true
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    private static func iterate(_ chunks: [Chunk]) -> () -> CMSampleBuffer? {
        var it = chunks.makeIterator()
        return { it.next()?.buffer }
    }

    private static func pcmSettings(_ format: CMFormatDescription?) -> [String: Any] {
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: asbd?.mSampleRate ?? 48_000,
            AVNumberOfChannelsKey: Int(asbd?.mChannelsPerFrame ?? 2),
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
