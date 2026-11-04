import XCTest
@testable import RibbonCore

private struct F: TimedSample {
    let time: Double
    let isKeyframe: Bool
}

final class ClipBufferTests: XCTestCase {
    /// 60 fps, keyframe every second.
    private func fill(_ ring: inout ClipRing<F>, frames: Range<Int>) {
        for i in frames { ring.append(F(time: Double(i) / 60, isKeyframe: i % 60 == 0)) }
    }

    func testKeepsAtLeastMaxDurationStartingOnKeyframe() {
        var ring = ClipRing<F>(maxDuration: 3)
        fill(&ring, frames: 0..<600)
        XCTAssertTrue(ring.samples.first!.isKeyframe)
        XCTAssertGreaterThanOrEqual(ring.duration, 3)
        XCTAssertLessThan(ring.duration, 4.1)
    }

    func testIgnoresLeadingNonKeyframes() {
        var ring = ClipRing<F>(maxDuration: 3)
        ring.append(F(time: 0, isKeyframe: false))
        XCTAssertTrue(ring.samples.isEmpty)
        ring.append(F(time: 0.1, isKeyframe: true))
        XCTAssertEqual(ring.samples.count, 1)
    }

    func testShrinkingClipLength() {
        var ring = ClipRing<F>(maxDuration: 10)
        fill(&ring, frames: 0..<1200)
        XCTAssertGreaterThanOrEqual(ring.duration, 10)
        ring.maxDuration = 2
        fill(&ring, frames: 1200..<1260)
        XCTAssertGreaterThanOrEqual(ring.duration, 2)
        XCTAssertLessThan(ring.duration, 3.05)
        XCTAssertTrue(ring.samples.first!.isKeyframe)
    }

    func testAudioStyleAllKeyframes() {
        var ring = ClipRing<F>(maxDuration: 5)
        for i in 0..<1000 { ring.append(F(time: Double(i) * 0.02, isKeyframe: true)) }
        XCTAssertEqual(ring.duration, 5, accuracy: 0.03)
    }

    func testBuildNumber() {
        XCTAssertEqual(buildNumber(fromTag: "v1.0.42"), 42)
        XCTAssertEqual(buildNumber(fromTag: "v1.0.7"), 7)
        XCTAssertNil(buildNumber(fromTag: "latest"))
    }
}
