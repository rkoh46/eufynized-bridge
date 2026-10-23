import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared measuring for panoramas made by panning a camera a step at a time (the S340's pan step isn't a fixed
/// angle, so each step's shift is measured from the pictures). Works on small grayscale copies, `w`×`h`.
public enum PanoramaMath {
    public static let w = 160, h = 90

    /// The horizontal offset that best lines `b` up with `a`: `b[x] ≈ a[x + s]`. Positive when `b` shows what was to
    /// the right in `a` (the camera panned right). Mean absolute difference over the overlap, skipping the top rows
    /// (the timestamp).
    public static func signedShift(from a: [UInt8], to b: [UInt8]) -> Int {
        guard a.count == w * h, b.count == w * h else { return 0 }
        let maxShift = w * 3 / 4
        var best = 0, bestScore = Double.infinity
        for s in -maxShift...maxShift {
            let x0 = max(0, -s), x1 = min(w, w - s)
            guard x1 - x0 >= w / 5 else { continue }
            var sum = 0
            for y in stride(from: h / 8, to: h, by: 2) {
                let row = y * w
                for x in stride(from: x0, to: x1, by: 2) { sum += abs(Int(a[row + x + s]) - Int(b[row + x])) }
            }
            let score = Double(sum) / Double((x1 - x0) * (h - h / 8))
            if score < bestScore { bestScore = score; best = s }
        }
        return best
    }

    /// `signedShift` in both directions: `b[x, y] ≈ a[x + dx, y + dy]`. dy covers a small range (the camera's
    /// tilt drifts a few pixels across a pan).
    public static func shift2D(from a: [UInt8], to b: [UInt8]) -> (dx: Int, dy: Int) {
        guard a.count == w * h, b.count == w * h else { return (0, 0) }
        let maxDX = w * 3 / 4, maxDY = h / 6
        var best = (dx: 0, dy: 0), bestScore = Double.infinity
        for dy in -maxDY...maxDY {
            let y0 = max(h / 8, -dy), y1 = min(h, h - dy)
            for dx in -maxDX...maxDX {
                let x0 = max(0, -dx), x1 = min(w, w - dx)
                guard x1 - x0 >= w / 5 else { continue }
                var sum = 0, n = 0
                for y in stride(from: y0, to: y1, by: 2) {
                    let ra = (y + dy) * w, rb = y * w
                    for x in stride(from: x0, to: x1, by: 2) { sum += abs(Int(a[ra + x + dx]) - Int(b[rb + x])); n += 1 }
                }
                let score = Double(sum) / Double(max(1, n))
                if score < bestScore { bestScore = score; best = (dx, dy) }
            }
        }
        return best
    }

    /// Joins RGB frames (all `width`×`height`, 3 bytes per pixel) left to right with the given shifts between
    /// neighbours (in the small copies' units), feathering where they overlap so the joins fade instead of cut.
    public static func stitchRGB(_ frames: [[UInt8]], width: Int, height: Int, shifts: [(dx: Int, dy: Int)])
        -> (pixels: [UInt8], width: Int, height: Int)? {
        guard !frames.isEmpty, frames.count == shifts.count + 1, frames.allSatisfy({ $0.count == width * height * 3 }) else { return nil }
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        var xs = [0], ys = [0]
        for s in shifts {
            xs.append(xs.last! + max(1, Int((Double(s.dx) * sx).rounded())))
            ys.append(ys.last! + Int((Double(s.dy) * sy).rounded()))
        }
        let minY = ys.min()!, maxY = ys.max()!
        let W = xs.last! + width, H = height + (maxY - minY)
        // Each column belongs to the picture whose centre is nearest (the sharpest view of it), with a short
        // crossfade at each boundary. Blending whole overlaps instead would mix several slightly different lens
        // views of the same thing and ghost everything.
        let centres = xs.map { Double($0) + Double(width) / 2 }
        let band = Double(width) / 16
        func weight(_ i: Int, _ X: Int) -> Float {
            let x = Double(X)
            let left = i > 0 ? (centres[i - 1] + centres[i]) / 2 : -Double.infinity
            let right = i + 1 < centres.count ? (centres[i] + centres[i + 1]) / 2 : Double.infinity
            let a = min(1, max(0, (x - (left - band)) / (2 * band)))
            let b = min(1, max(0, ((right + band) - x) / (2 * band)))
            return Float(a * b)
        }
        var acc = [Float](repeating: 0, count: W * H * 3), wsum = [Float](repeating: 0, count: W * H)
        for (i, frame) in frames.enumerated() {
            let x0 = xs[i], y0 = ys[i] - minY
            let weights = (0..<width).map { weight(i, x0 + $0) }
            frame.withUnsafeBufferPointer { f in
                for y in 0..<height {
                    let row = (y0 + y) * W
                    for x in 0..<width where weights[x] > 0 {
                        let wgt = weights[x]
                        let o = row + x0 + x, src = (y * width + x) * 3
                        acc[o * 3] += Float(f[src]) * wgt
                        acc[o * 3 + 1] += Float(f[src + 1]) * wgt
                        acc[o * 3 + 2] += Float(f[src + 2]) * wgt
                        wsum[o] += wgt
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: W * H * 3)
        for o in 0..<(W * H) where wsum[o] > 0 {
            let inv = 1 / wsum[o]
            out[o * 3] = UInt8(min(255, acc[o * 3] * inv))
            out[o * 3 + 1] = UInt8(min(255, acc[o * 3 + 1] * inv))
            out[o * 3 + 2] = UInt8(min(255, acc[o * 3 + 2] * inv))
        }
        return (out, W, H)
    }

    /// Where each picture's centre falls in the stitched panorama, as a fraction of its width, given the shifts
    /// between neighbours (leftmost first).
    public static func centres(shifts: [Int]) -> [Double] {
        let width = Double(w) + Double(shifts.reduce(0, +))
        var x = Double(w) / 2
        var out = [x / width]
        for s in shifts { x += Double(s); out.append(x / width) }
        return out
    }

    #if canImport(CoreGraphics)
    /// A `w`×`h` grayscale copy of an image, for `signedShift`.
    public static func gray(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }

    /// An image as packed RGB bytes at `width`×`height`.
    public static func rgb(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { out[i * 3] = rgba[i * 4]; out[i * 3 + 1] = rgba[i * 4 + 1]; out[i * 3 + 2] = rgba[i * 4 + 2] }
        return out
    }

    public static func image(rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2] }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Joins pictures left to right with feathered overlaps (`stitchRGB`).
    public static func stitch(_ images: [CGImage], shifts: [(dx: Int, dy: Int)], height: Int = 720) -> CGImage? {
        guard let first = images.first else { return nil }
        let width = Int((Double(first.width) * Double(height) / Double(first.height)).rounded()) / 2 * 2
        let frames = images.compactMap { rgb($0, width: width, height: height) }
        guard frames.count == images.count, let r = stitchRGB(frames, width: width, height: height, shifts: shifts) else { return nil }
        return image(rgb: r.pixels, width: r.width, height: r.height)
    }

    /// The strip-based join, kept for comparison.
    public static func stitchStrips(_ images: [CGImage], shifts: [Int], height: Int = 720) -> CGImage? {
        guard let first = images.first, images.count == shifts.count + 1 else { return nil }
        let frameWidth = Double(first.width) * Double(height) / Double(first.height)
        let scale = frameWidth / Double(w)
        let strips = shifts.map { max(1, Int((Double($0) * scale).rounded())) }
        let width = Int(frameWidth.rounded()) + strips.reduce(0, +)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(first, in: CGRect(x: 0, y: 0, width: frameWidth, height: Double(height)))
        var x = frameWidth
        for (image, strip) in zip(images.dropFirst(), strips) {
            // Draw the whole frame so its right edge lines up at x + strip; only its new strip is uncovered.
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x, y: 0, width: Double(strip), height: Double(height)))
            ctx.draw(image, in: CGRect(x: x + Double(strip) - frameWidth, y: 0, width: frameWidth, height: Double(height)))
            ctx.restoreGState()
            x += Double(strip)
        }
        return ctx.makeImage()
    }
    #endif
}
