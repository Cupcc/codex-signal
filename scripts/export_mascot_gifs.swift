import AppKit
import ImageIO
import QuartzCore
import SignalCore
import UniformTypeIdentifiers

/// Offline export using the application's actual artwork, layer tree and tracks.
@main
struct ExportMascotGIFs {
    static let fps = 25
    static let overviewFrameCount = fps * 8
    static let width = 192, height = 240

    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let phases: [SessionPhase?] = [.running, nil, .approval, .question, .completed, .failed]
        let poses = phases.map { PhaseAppearance($0) }
        // Catch a newly added artwork state before publishing an incomplete set.
        let layers = Bundle.module.url(forResource: "working-body", withExtension: "png",
                                       subdirectory: "Resources/MascotLayers")!.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: layers.path)
        let states = Set(files.filter { $0.hasSuffix("-body.png") && !$0.hasPrefix("mini-") }
            .map { String($0.dropLast("-body.png".count)) })
        guard states == Set(poses.map(\.asset)) else {
            throw failure("Exported states do not cover the application's artwork: \(states.sorted())")
        }
        for mini in [false, true] {
            try export(poses: poses, mini: mini, to: output)
        }
        let obsolete = output.appendingPathComponent("mascot-five-states.gif")
        if FileManager.default.fileExists(atPath: obsolete.path) {
            try FileManager.default.removeItem(at: obsolete)
        }
    }

    @MainActor
    static func export(poses: [PhaseAppearance], mini: Bool, to output: URL) throws {
        let views = poses.map { pose in
            let view = MascotAnimationView()
            view.configure(state: pose.asset, mini: mini, active: false, reduced: true)
            return view
        }
        defer { views.forEach { $0.stopObserving() } }
        let prefix = mini ? "mascot-mini-" : "mascot-"
        let names = poses.map { "\(prefix)\($0.asset).gif" } + ["\(prefix)six-states.gif"]
        let tracks = poses.map { MascotAnimation.tracks(for: $0.asset) }
        let frameCounts = tracks.map(frameCount) + [overviewFrameCount]
        let destinations = try names.enumerated().map { index, name -> CGImageDestination in
            guard let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                                    UTType.gif.identifier as CFString, frameCounts[index], nil) else {
                throw failure("Cannot create \(name)")
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            return destination
        }
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)]] as CFDictionary
        for frame in 0..<frameCounts.max()! {
            try autoreleasepool {
                let time = Double(frame) / Double(fps)
                let overview = frame < overviewFrameCount ? context(width: width * poses.count, height: height) : nil
                for (index, pose) in poses.enumerated() {
                    guard frame < frameCounts[index] || overview != nil else { continue }
                    let view = views[index]
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for track in tracks[index] {
                        view.parts[track.part]?.setValue(value(track, at: time), forKeyPath: track.keyPath)
                    }
                    CATransaction.commit()
                    let canvas = context(width: width, height: height)
                    canvas.saveGState()
                    canvas.translateBy(x: 0, y: CGFloat(height))
                    canvas.scaleBy(x: 1.5, y: -1.5)
                    view.canvas.render(in: canvas)
                    canvas.restoreGState()
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
                    let label = NSAttributedString(string: pose.title, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                                                                                .foregroundColor: NSColor(white: 0.9, alpha: 1)])
                    label.draw(at: CGPoint(x: (CGFloat(width) - label.size().width) / 2, y: 17))
                    NSGraphicsContext.restoreGraphicsState()
                    guard let image = canvas.makeImage() else { throw failure("Cannot render \(pose.asset)") }
                    if frame < frameCounts[index] {
                        CGImageDestinationAddImage(destinations[index], image, properties)
                    }
                    overview?.draw(image, in: CGRect(x: index * width, y: 0, width: width, height: height))
                    // Keep a real frame for visual QA, including idle's open eyes.
                    if frame == 80 {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                            .write(to: output.appendingPathComponent("preview-\(mini ? "mini-" : "")\(pose.asset).png"))
                    }
                }
                if let overview {
                    CGImageDestinationAddImage(destinations.last!, overview.makeImage()!, properties)
                }
            }
        }
        for (index, destination) in destinations.enumerated() {
            guard CGImageDestinationFinalize(destination) else { throw failure("Cannot finalize \(names[index])") }
            let url = output.appendingPathComponent(names[index])
            let overview = index == poses.count
            let entrance = !overview && !tracks[index].contains(where: \.loops)
            try verify(url, frames: frameCounts[index], entrance: entrance, overview: overview)
            print("Exported \(url.lastPathComponent): \(frameCounts[index]) frames, \(Double(frameCounts[index]) / Double(fps))s, infinite loop, verified")
        }
    }

    static func frameCount(_ tracks: [MascotAnimation.Track]) -> Int {
        let periods = tracks.filter(\.loops).map { Int(($0.duration * Double(fps)).rounded()) }
        guard !periods.isEmpty else { return overviewFrameCount }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        // Include every loop's full cycle so GIF replay preserves blink/fin phase.
        return periods.reduce(1) { $0 / gcd($0, $1) * $1 }
    }

    static func verify(_ url: URL, frames: Int, entrance: Bool, overview: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == frames else {
            throw failure("Wrong frame count: \(url.lastPathComponent)")
        }
        let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let loopCount = gif?[kCGImagePropertyGIFLoopCount as String] as? Int
        guard loopCount == 0 else {
            throw failure("Wrong playback count: \(url.lastPathComponent)")
        }
        for frame in 0..<frames {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [String: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            guard let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double,
                  abs(delay - 1 / Double(fps)) < 0.0001,
                  properties?[kCGImagePropertyPixelWidth as String] as? Int == width * (overview ? 6 : 1),
                  properties?[kCGImagePropertyPixelHeight as String] as? Int == height else {
                throw failure("Wrong frame timing or size: \(url.lastPathComponent), frame \(frame)")
            }
        }
        func pixels(_ frame: Int) throws -> Data {
            guard let image = CGImageSourceCreateImageAtIndex(source, frame, nil) else {
                throw failure("Cannot decode \(url.lastPathComponent), frame \(frame)")
            }
            let canvas = context(width: image.width, height: image.height)
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: canvas.data!, count: canvas.bytesPerRow * image.height)
        }
        guard try pixels(0) != pixels(8) else { throw failure("Animation is static: \(url.lastPathComponent)") }
        if entrance {
            guard try pixels(frames - 2) == pixels(frames - 1) else {
                throw failure("Entrance did not settle: \(url.lastPathComponent)")
            }
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "GIFExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func context(width: Int, height: Int) -> CGContext {
        let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        result.setFillColor(CGColor(red: 0.045, green: 0.052, blue: 0.065, alpha: 1))
        result.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return result
    }

    static func value(_ track: MascotAnimation.Track, at time: Double) -> Double {
        let elapsed = max(0, time - track.delay)
        let position = track.loops ? elapsed.truncatingRemainder(dividingBy: track.duration) / track.duration
            : min(1, elapsed / track.duration)
        guard let end = track.times.firstIndex(where: { $0 > position }), end > 0 else { return track.values.last! }
        let start = end - 1
        var fraction = (position - track.times[start]) / (track.times[end] - track.times[start])
        if !track.linear {
            // Solve x(t) for the same cubic timing curve as Core Animation.
            let timing = track.animation().timingFunctions!.first!
            var first = [Float](repeating: 0, count: 2), second = first
            timing.getControlPoint(at: 1, values: &first)
            timing.getControlPoint(at: 2, values: &second)
            func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
                3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
            }
            var lower = 0.0, upper = 1.0
            for _ in 0..<24 {
                let middle = (lower + upper) / 2
                if bezier(middle, Double(first[0]), Double(second[0])) < fraction { lower = middle } else { upper = middle }
            }
            fraction = bezier((lower + upper) / 2, Double(first[1]), Double(second[1]))
        }
        return track.values[start] + (track.values[end] - track.values[start]) * fraction
    }
}
