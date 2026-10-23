import Foundation
import EufyKit

/// A wide picture from a pan-and-tilt camera (the SoloCam S340), built the way the eufy app builds its own: pan a step
/// at a time, take a picture at each step, and stitch them. The camera's pan step isn't a fixed angle (measured on the
/// S340: roughly a quarter of the frame, varying from step to step), so each step's shift is measured from the pictures
/// themselves, both for stitching and for steering: tapping the panorama pans to the step nearest that spot.
///
/// The camera ends where it started, as near as whole steps allow: it pans back, then compares the live picture with
/// the one it took first and corrects by a step if needed.
final class Panorama: @unchecked Sendable {
    enum State: String { case idle, running, done, failed }

    private let bridge: Bridge
    private let channel: UInt8
    private let lock = NSLock()
    private var state = State.idle
    private var progress = 0.0
    private var message: String?
    private var image: Data?
    private var createdAt: Date?
    /// Each step's position in the panorama (the x of its picture's centre, as a fraction of the panorama's width),
    /// from the leftmost step; `startIndex` is where the camera started, `currentIndex` where it points now.
    private var centres: [Double] = []
    private var startIndex = 0
    private var currentIndex = 0

    /// Steps to each side of where the camera points.
    static let stepsPerSide = 3
    /// After a nudge: time for the motor to stop and a new keyframe to arrive.
    static let settle: TimeInterval = 5

    init(bridge: Bridge, channel: UInt8) {
        self.bridge = bridge
        self.channel = channel
    }

    var status: [String: Any] {
        lock.withLock {
            ["state": state.rawValue, "progress": (progress * 100).rounded() / 100, "message": message as Any,
             "createdAt": createdAt.map { $0.timeIntervalSince1970 } as Any, "centres": centres,
             "current": centres.indices.contains(currentIndex) ? centres[currentIndex] : NSNull()]
        }
    }

    var jpeg: Data? { lock.withLock { image } }

    /// Starts a panorama in the background; false if one is already being made.
    func start() -> Bool {
        let started = lock.withLock { () -> Bool in
            guard state != .running else { return false }
            state = .running; progress = 0; message = nil
            return true
        }
        if started { Thread.detachNewThread { [self] in run() } }
        return started
    }

    /// Pans to the step nearest `x` (0 = the panorama's left edge, 1 = its right edge).
    func aim(x: Double) -> Bool {
        let (steps, target): (Int, Int) = lock.withLock {
            guard state == .done, !centres.isEmpty else { return (0, -1) }
            let target = centres.indices.min { abs(centres[$0] - x) < abs(centres[$1] - x) } ?? currentIndex
            return (target - currentIndex, target)
        }
        guard target >= 0 else { return false }
        nudge(steps > 0 ? .right : .left, times: abs(steps), pause: 1.2)
        lock.withLock { currentIndex = target }
        return true
    }

    private func nudge(_ direction: PTZDirection, times: Int = 1, pause: TimeInterval = Panorama.settle) {
        guard times > 0 else { return }
        let (stream, fresh) = bridge.controlStream(channel)
        if fresh { Thread.sleep(forTimeInterval: 2.5) }
        for _ in 0..<times {
            stream.rotate(direction)
            Thread.sleep(forTimeInterval: pause)
        }
    }

    private func capture() -> (jpeg: Data, gray: [UInt8])? {
        guard let jpeg = bridge.fullSnapshot(channel, settle: 0),
              let raw = FFmpeg.run(["-i", "pipe:0", "-vf", "scale=\(Self.w):\(Self.h),format=gray", "-f", "rawvideo", "pipe:1"], input: jpeg),
              raw.count == Self.w * Self.h else { return nil }
        return (jpeg, [UInt8](raw))
    }

    private func fail(_ text: String) {
        log("panorama ch\(channel): \(text)")
        lock.withLock { state = .failed; message = text }
    }

    private func run() {
        let n = Self.stepsPerSide
        let total = Double(4 * n + 2)
        var done = 0.0
        func tick() { done += 1; lock.withLock { progress = min(1, done / total) } }

        guard let start = capture() else { return fail("No picture from the camera") }
        tick()
        // Left of the start, nearest first; then back, then right of it.
        // A step the camera ignores (it happens) would put the same picture in twice: a nudge is repeated until the
        // picture has moved, and a side ends early when it won't.
        func step(_ direction: PTZDirection, after previous: [UInt8]) -> (jpeg: Data, gray: [UInt8])?? {
            for attempt in 0..<3 {
                nudge(direction)
                guard let shot = capture() else { return .some(nil) }
                if abs(PanoramaMath.shift2D(from: previous, to: shot.gray).dx) >= Self.w / 12 { return shot }
                log("panorama ch\(channel): step \(direction) didn't move (attempt \(attempt + 1))")
            }
            return nil   // three tries, no movement: this side is done
        }
        var left: [(jpeg: Data, gray: [UInt8])] = []
        for _ in 0..<n {
            guard let result = step(.left, after: left.last?.gray ?? start.gray) else { break }
            guard let shot = result else { returnToStart(reference: start.gray, offset: -left.count); return fail("Lost the picture while panning") }
            left.append(shot); tick()
        }
        nudge(.right, times: left.count, pause: 1.2); done += Double(n); tick()
        var right: [(jpeg: Data, gray: [UInt8])] = []
        for _ in 0..<n {
            guard let result = step(.right, after: right.last?.gray ?? start.gray) else { break }
            guard let shot = result else { returnToStart(reference: start.gray, offset: right.count); return fail("Lost the picture while panning") }
            right.append(shot); tick()
        }
        let shots = left.reversed() + [start] + right   // leftmost first
        guard shots.count >= 3 else { returnToStart(reference: start.gray, offset: right.count); return fail("The camera didn't pan") }
        returnToStart(reference: start.gray, offset: right.count)
        tick()

        // How far the picture moved between neighbours, in the small grayscale copies' pixels.
        let shifts = zip(shots, shots.dropFirst()).map { pair -> (dx: Int, dy: Int) in
            let s = PanoramaMath.shift2D(from: pair.0.gray, to: pair.1.gray)
            return (max(1, s.dx), s.dy)
        }
        guard let stitched = stitch(shots.map(\.jpeg), shifts: shifts) else { return fail("Couldn't stitch the pictures") }
        let centres = PanoramaMath.centres(shifts: shifts.map(\.dx))
        lock.withLock {
            image = stitched
            self.centres = centres
            startIndex = left.count
            currentIndex = left.count
            createdAt = Date()
            state = .done
            progress = 1
        }
        log("panorama ch\(channel): \(shots.count) pictures, shifts \(shifts)")
    }

    /// Pans back by `offset` steps (positive: the camera is right of the start), then checks the live picture against
    /// the first one and corrects by a step when it's clearly off.
    private func returnToStart(reference: [UInt8], offset: Int) {
        nudge(offset > 0 ? .left : .right, times: abs(offset), pause: 1.2)
        Thread.sleep(forTimeInterval: Self.settle - 1.2)
        guard let now = capture() else { return }
        // Positive: the live picture shows what was right of the start, so the camera points too far right.
        let s = Self.signedShift(from: reference, to: now.gray)
        if abs(s) > Self.w / 8 { nudge(s > 0 ? .left : .right) }
    }

    /// Joins the pictures with feathered overlaps (`PanoramaMath.stitchRGB`): ffmpeg decodes each JPEG to RGB and
    /// encodes the result.
    private func stitch(_ jpegs: [Data], shifts: [(dx: Int, dy: Int)]) -> Data? {
        let width = 1280, height = 720
        var frames: [[UInt8]] = []
        for jpeg in jpegs {
            guard let raw = FFmpeg.run(["-i", "pipe:0", "-vf", "scale=\(width):\(height)", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], input: jpeg),
                  raw.count == width * height * 3 else { return nil }
            frames.append([UInt8](raw))
        }
        guard let r = PanoramaMath.stitchRGB(frames, width: width, height: height, shifts: shifts) else { return nil }
        return FFmpeg.run(["-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "\(r.width)x\(r.height)", "-i", "pipe:0",
                           "-frames:v", "1", "-q:v", "3", "-f", "image2", "-c:v", "mjpeg", "pipe:1"], input: Data(r.pixels))
    }

    // MARK: Measuring a step

    static var w: Int { PanoramaMath.w }
    static var h: Int { PanoramaMath.h }

    /// How far the scene moved left from `a` to `b` (the camera panned right), in pixels of the small copies.
    static func shift(from a: [UInt8], to b: [UInt8]) -> Int { max(1, PanoramaMath.signedShift(from: a, to: b)) }

    static func signedShift(from a: [UInt8], to b: [UInt8]) -> Int { PanoramaMath.signedShift(from: a, to: b) }
}
