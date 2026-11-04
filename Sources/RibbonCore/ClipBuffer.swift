/// A sample in the replay buffer: a timestamp in seconds, and whether a clip may start here.
public protocol TimedSample {
    var time: Double { get }
    var isKeyframe: Bool { get }
}

/// Rolling window of samples that always starts on a keyframe and covers at least `maxDuration`.
/// Whole GOPs are dropped from the front, so a snapshot is always a playable clip.
public struct ClipRing<S: TimedSample> {
    public private(set) var samples: [S] = []
    public var maxDuration: Double

    public init(maxDuration: Double) { self.maxDuration = maxDuration }

    public var duration: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time - first.time
    }

    public mutating func append(_ sample: S) {
        if samples.isEmpty && !sample.isKeyframe { return }
        samples.append(sample)
        guard sample.isKeyframe else { return }  // trim once per GOP, not per frame
        while let next = samples.dropFirst().firstIndex(where: \.isKeyframe),
              sample.time - samples[next].time >= maxDuration {
            samples.removeFirst(next)
        }
    }
}

/// "v1.0.42" -> 42. Release tags carry the CI build number last.
public func buildNumber(fromTag tag: String) -> Int? {
    tag.split(separator: ".").last.flatMap { Int($0) }
}
