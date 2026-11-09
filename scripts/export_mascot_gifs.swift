import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Offline export using the application's actual artwork, layer tree and tracks.
@main
struct ExportMascotGIFs {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let poses = [("working", "工作"), ("idle", "休息"), ("attention", "等待审批"),
                     ("question", "有个问题"), ("error", "运行中断")]
        let views = poses.map { pose in
            let view = MascotAnimationView()
            view.configure(state: pose.0, mini: false, active: false, reduced: true)
            return view
        }
        defer { views.forEach { $0.stopObserving() } }
        let fps = 25
        let frameCount = fps * 8
        let width = 192, height = 240
        let names = poses.map { "mascot-\($0.0).gif" } + ["mascot-five-states.gif"]
        let destinations = try names.map { name -> CGImageDestination in
            guard let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                                    UTType.gif.identifier as CFString, frameCount, nil) else {
                throw NSError(domain: "GIFExport", code: 1)
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            return destination
        }
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)]] as CFDictionary
        for frame in 0..<frameCount {
            try autoreleasepool {
                let time = Double(frame) / Double(fps)
                let overview = context(width: width * poses.count, height: height)
                for (index, pose) in poses.enumerated() {
                    let view = views[index]
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for track in MascotAnimation.tracks(for: pose.0) {
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
                    let label = NSAttributedString(string: pose.1, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                                                                                .foregroundColor: NSColor(white: 0.9, alpha: 1)])
                    label.draw(at: CGPoint(x: (CGFloat(width) - label.size().width) / 2, y: 17))
                    NSGraphicsContext.restoreGraphicsState()
                    guard let image = canvas.makeImage() else { throw NSError(domain: "GIFExport", code: 2) }
                    CGImageDestinationAddImage(destinations[index], image, properties)
                    overview.draw(image, in: CGRect(x: index * width, y: 0, width: width, height: height))
                    // Keep a real frame for visual QA, including idle's open eyes.
                    if frame == 80 {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                            .write(to: output.appendingPathComponent("preview-\(pose.0).png"))
                    }
                }
                CGImageDestinationAddImage(destinations.last!, overview.makeImage()!, properties)
            }
        }
        for (index, destination) in destinations.enumerated() {
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "GIFExport", code: 3) }
            let url = output.appendingPathComponent(names[index])
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            guard CGImageSourceGetCount(source) == frameCount else { throw NSError(domain: "GIFExport", code: 4) }
            print("Exported \(url.path): \(frameCount) frames, 8 seconds, \(fps) fps")
        }
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
            func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
                3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
            }
            var lower = 0.0, upper = 1.0
            for _ in 0..<24 {
                let middle = (lower + upper) / 2
                if bezier(middle, 0.22, 0.3) < fraction { lower = middle } else { upper = middle }
            }
            fraction = bezier((lower + upper) / 2, 0.7, 1)
        }
        return track.values[start] + (track.values[end] - track.values[start]) * fraction
    }
}
