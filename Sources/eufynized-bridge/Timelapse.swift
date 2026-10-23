import Foundation
import EufyKit

/// A day on one camera in half a minute: one picture per recording (the HomeBase's own thumbnail of each), in
/// order, encoded by ffmpeg. With continuous recording on, that's a frame every few minutes all day; with event
/// recording, a frame per event. No clip is downloaded, so the HomeBase isn't busy for it.
final class Timelapse {
    enum State: String { case idle, running, done, failed }

    private let bridge: Bridge
    private let channel: UInt8
    private let date: String
    private let lock = NSLock()
    private var state = State.idle
    private var progress = 0.0
    private var message: String?
    private var frames = 0

    init(bridge: Bridge, channel: UInt8, date: String) {
        self.bridge = bridge
        self.channel = channel
        self.date = date
    }

    var file: URL? {
        let url = bridge.cacheDir.appendingPathComponent("timelapse-\(channel)-\(date).mp4")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var status: [String: Any] {
        lock.withLock {
            ["state": file != nil && state != .running ? "done" : state.rawValue, "progress": (progress * 100).rounded() / 100,
             "frames": frames, "message": message as Any, "date": date, "channel": Int(channel)]
        }
    }

    func start(seconds: Double) {
        let begin = lock.withLock { () -> Bool in
            guard state != .running else { return false }
            state = .running; progress = 0; message = nil; frames = 0
            return true
        }
        guard begin else { return }
        Thread.detachNewThread { [self] in run(seconds: seconds) }
    }

    private func fail(_ text: String) { lock.withLock { state = .failed; message = text } }

    private func run(seconds: Double) {
        guard let camera = bridge.camera(channel) else { return fail("No such camera") }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let day = f.date(from: date) else { return fail("Bad date") }
        let recordings = bridge.recordings
        guard let events = blocking({ try? await recordings.events(on: day, cameraSerials: [camera.serial]) }), !events.isEmpty else {
            return fail("No recordings that day")
        }
        let sorted = events.sorted { $0.startTime < $1.startTime }
        var jpegs: [Data] = []
        for (i, e) in sorted.enumerated() {
            guard let path = e.thumbnailPath else { continue }
            let cached = bridge.cacheDir.appendingPathComponent("thumb-\(abs(path.hashValue)).jpg")
            let jpeg = (try? Data(contentsOf: cached)) ?? blocking({ try? await recordings.image(path: path) })
            if let jpeg { try? jpeg.write(to: cached); jpegs.append(jpeg) }
            lock.withLock { progress = Double(i + 1) / Double(sorted.count) * 0.8; frames = jpegs.count }
        }
        guard jpegs.count >= 2 else { return fail("Not enough pictures that day") }
        let fps = max(2, min(30, Double(jpegs.count) / max(5, seconds)))
        // The thumbnails arrive one after another on stdin as a single JPEG stream.
        let out = bridge.cacheDir.appendingPathComponent("timelapse-\(channel)-\(date).mp4")
        let process = Process(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: FFmpeg.binary)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "image2pipe", "-framerate", String(format: "%.2f", fps), "-i", "pipe:0",
                             "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                             "-movflags", "+faststart", out.path]
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return fail("ffmpeg: \(error)") }
        for jpeg in jpegs { try? stdin.fileHandleForWriting.write(contentsOf: jpeg) }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else { return fail("Couldn't encode the video") }
        lock.withLock { state = .done; progress = 1 }
        log("timelapse ch\(channel) \(date): \(jpegs.count) frames at \(Int(fps)) fps")
    }
}
