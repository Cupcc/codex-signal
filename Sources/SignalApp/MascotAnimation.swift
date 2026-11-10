import QuartzCore

/// Native counterpart of design/assets/mascot-motion.js, in 128-point art coordinates.
enum MascotAnimation {
    struct Track {
        let part: String
        let keyPath: String
        let values: [Double]
        let times: [Double]
        let duration: Double
        var loops = false
        var delay: Double = 0
        var linear = false

        func animation() -> CAKeyframeAnimation {
            let result = CAKeyframeAnimation(keyPath: keyPath)
            result.values = values
            result.keyTimes = times.map { NSNumber(value: $0) }
            result.duration = duration
            result.repeatCount = loops ? .infinity : 0
            let easing = linear ? CAMediaTimingFunction(name: .linear)
                : CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.3, 1)
            result.timingFunctions = Array(repeating: easing, count: values.count - 1)
            return result
        }
    }

    static func tracks(for state: String, entrance: Bool = true) -> [Track] {
        switch state {
        case "working":
            // Move the entire silhouette: 8 art points remain visible at 22–32pt.
            var result = [Track(part: "character", keyPath: "transform.translation.y",
                                values: [0, -8, 1, -5, 0, 0], times: [0, 0.2, 0.4, 0.6, 0.8, 1], duration: 1.8, loops: true)]
            for (part, sign, delay) in [("left", 1.0, 0.0), ("right", -1.0, 0.12)] {
                result.append(Track(part: part, keyPath: "transform.rotation.z",
                                    values: [0, sign * 22 * .pi / 180, 0, sign * 16 * .pi / 180, 0, 0],
                                    times: [0, 0.16, 0.34, 0.52, 0.72, 1], duration: 1.8, loops: true, delay: delay))
                result.append(Track(part: part, keyPath: "transform.translation.y",
                                    values: [0, -3, 0, -2, 0, 0], times: [0, 0.16, 0.34, 0.52, 0.72, 1],
                                    duration: 1.8, loops: true, delay: delay))
            }
            result.append(Track(part: "eyes", keyPath: "transform.scale.y", values: [1, 1, 0.12, 1, 1],
                                times: [0, 0.9, 0.93, 0.97, 1], duration: 4.6, loops: true, linear: true))
            return result
        case "idle":
            return [Track(part: "character", keyPath: "transform.translation.y", values: [0, -4, 0],
                          times: [0, 0.5, 1], duration: 3.2, loops: true),
                    Track(part: "body", keyPath: "transform.scale.y", values: [1, 1.045, 1],
                          times: [0, 0.5, 1], duration: 3.2, loops: true),
                    Track(part: "open", keyPath: "opacity", values: [0, 0, 1, 1, 0, 0],
                          times: [0, 0.44, 0.47, 0.57, 0.6, 1], duration: 6.4, loops: true, linear: true),
                    Track(part: "eyes", keyPath: "opacity", values: [1, 1, 0, 0, 1, 1],
                          times: [0, 0.44, 0.47, 0.57, 0.6, 1], duration: 6.4, loops: true, linear: true)]
        default:
            guard entrance else { return [] }
            var result: [Track] = []
            switch state {
            case "ready":
                result = [Track(part: "character", keyPath: "transform.translation.y", values: [0, -6, 1, 0],
                                times: [0, 0.35, 0.7, 1], duration: 0.9)]
            case "attention":
                result = [Track(part: "character", keyPath: "transform.translation.y", values: [0, 3, -10, 1, -4, 0],
                                times: [0, 0.12, 0.35, 0.58, 0.76, 1], duration: 1.1),
                          Track(part: "right", keyPath: "transform.rotation.z", values: [0, 38, -18, 28, -10, 0].map { $0 * .pi / 180 },
                                times: [0, 0.18, 0.38, 0.58, 0.78, 1], duration: 1.1)]
            case "question":
                result = [Track(part: "character", keyPath: "transform.rotation.z", values: [0, -12, -12, 4, 0].map { $0 * .pi / 180 },
                                times: [0, 0.28, 0.55, 0.8, 1], duration: 1.2),
                          Track(part: "right", keyPath: "transform.rotation.z", values: [0, 28, 28, -6, 0].map { $0 * .pi / 180 },
                                times: [0, 0.24, 0.5, 0.78, 1], duration: 1.2)]
            case "error":
                result = [Track(part: "character", keyPath: "transform.translation.x", values: [0, -7, 7, -5, 3, 0],
                                times: [0, 0.16, 0.34, 0.52, 0.72, 1], duration: 0.8)]
            default: return []
            }
            result.append(Track(part: "badge", keyPath: "transform.scale", values: [0.72, 1.18, 0.96, 1],
                                times: [0, 0.45, 0.72, 1], duration: 0.6))
            return result
        }
    }
}
