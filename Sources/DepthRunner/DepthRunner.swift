import CoreImage
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import simd
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

@main
struct DepthRunner {
    static func main() {
        do {
            let options = try CommandLineOptions.parse()
            let modelURL = try ModelLocator().locateModel()
            let generator = try DepthMapGenerator(modelURL: modelURL)
            let result = try generator.generateDepthMap(inputPath: options.inputPath, outputPath: options.outputPath)
            print("Depth map saved to \(result.destinationURL.path)")

            if options.requiresPointCloud {
                let (intrinsics, intrinsicsMessages) = options.resolveIntrinsics(width: result.width, height: result.height)
                for message in intrinsicsMessages {
                    if message.hasPrefix("Warning:") {
                        fputs("\(message)\n", stderr)
                    } else {
                        print(message)
                    }
                }

                let roiRect = options.resolveROI(width: result.width, height: result.height)
                if let roiDescription = options.roiDescription {
                    print("Applying ROI: \(roiDescription)")
                }

                if !options.trimMessages.isEmpty {
                    for message in options.trimMessages {
                        fputs("\(message)\n", stderr)
                    }
                }

                let roiInfo = makeROIInfo(width: result.width, height: result.height, roi: roiRect)
                if roiInfo.sampleCount == 0 {
                    fputs("Warning: ROI yielded zero candidate pixels; skipping point cloud and volume computation.\n", stderr)
                } else {
                    let rawPoints = depthToPointCloud(depth: result.depthPixelBuffer, intrinsics: intrinsics, roi: roiInfo.rect)
                    var simdPoints = rawPoints.map { SIMD3<Float>($0.0, $0.1, $0.2) }

                    if let clipConfig = options.groundClipConfig, !simdPoints.isEmpty {
                        if let plane = fitGroundPlaneLSQ(points: simdPoints, percentile: clipConfig.percentile) {
                            let clippedPoints = clipGround(points: simdPoints, plane: plane, eps: clipConfig.eps)
                            let removedCount = simdPoints.count - clippedPoints.count
                            let removalFraction = simdPoints.isEmpty ? 0 : Float(removedCount) / Float(simdPoints.count)
                            print(
                                String(
                                    format: "Ground plane removed: %.1f%% of points (ε=%.3fm, p=%.2f)",
                                    removalFraction * 100,
                                    clipConfig.eps,
                                    clipConfig.percentile
                                )
                            )
                            simdPoints = clippedPoints
                        } else {
                            fputs("Warning: Unable to fit a stable ground plane; skipping ground clipping.\n", stderr)
                        }
                    }

                    let trimResult = trimPoints(simdPoints, config: options.trimConfig)
                    let keptPercent = trimResult.keptFraction * 100
                    print(
                        String(
                            format: "Trim: kept %.1f%% (p=%.3f), Z-band=[%.2f,%.2f] m",
                            keptPercent,
                            options.trimConfig.percentile,
                            options.trimConfig.zMin,
                            options.trimConfig.zMax
                        )
                    )
                    if trimResult.originalCount > 0 && trimResult.points.count < 500 {
                        fputs("Warning: Weniger als 500 Punkte nach Trim; Ergebnis möglicherweise unsicher.\n", stderr)
                    }
                    simdPoints = trimResult.points

                    if options.volumeRequested {
                        computeAndLogVolume(for: simdPoints, roiInfo: roiInfo, unit: options.volumeUnit)
                    }

                    if !options.pointCloudRequests.isEmpty {
                        let tuplePoints = simdPoints.map { ($0.x, $0.y, $0.z) }
                        try exportPointClouds(points: tuplePoints, requests: options.pointCloudRequests)
                    }
                }
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private func exportPointClouds(points: [(Float, Float, Float)], requests: [PointCloudRequest]) throws {
    let locale = Locale(identifier: "en_US_POSIX")
    for request in requests {
        let url = try resolvePointCloudURL(from: request.path, defaultExtension: request.format.defaultExtension)
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        switch request.format {
        case .ply:
            let header = [
                "ply",
                "format ascii 1.0",
                "element vertex \(points.count)",
                "property float x",
                "property float y",
                "property float z",
                "end_header"
            ].joined(separator: "\n")

            var body = points.map { point in
                String(
                    format: "%.6f %.6f %.6f",
                    locale: locale,
                    Double(point.0),
                    Double(point.1),
                    Double(point.2)
                )
            }.joined(separator: "\n")
            if !body.isEmpty {
                body.append("\n")
            }
            let content = header + "\n" + body
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw DepthRunnerError.pointCloudWriteFailed(url.path)
            }
        case .xyz:
            var content = points.map { point in
                String(
                    format: "%.6f %.6f %.6f",
                    locale: locale,
                    Double(point.0),
                    Double(point.1),
                    Double(point.2)
                )
            }.joined(separator: "\n")
            if !content.isEmpty {
                content.append("\n")
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw DepthRunnerError.pointCloudWriteFailed(url.path)
            }
        }

        print("Point cloud (\(request.format.description)) saved to \(url.path) [\(points.count) points]")
    }
}

private struct GroundClipConfig {
    let percentile: Float
    let eps: Float
}

private struct TrimConfig {
    let percentile: Float
    let zMin: Float
    let zMax: Float
}

private struct TrimResult {
    let points: [SIMD3<Float>]
    let keptFraction: Float
    let originalCount: Int
}

private func percentile(_ values: [Float], percentile: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    let clamped = max(0, min(1, percentile))
    let sorted = values.sorted()
    let index = Int(Float(sorted.count - 1) * clamped)
    let clampedIndex = max(0, min(index, sorted.count - 1))
    return sorted[clampedIndex]
}

private func trimPoints(_ points: [SIMD3<Float>], config: TrimConfig) -> TrimResult {
    let originalCount = points.count
    guard !points.isEmpty else {
        return TrimResult(points: points, keptFraction: 0, originalCount: 0)
    }

    let zBandPoints = points.filter { point in
        point.z >= config.zMin && point.z <= config.zMax
    }

    guard !zBandPoints.isEmpty else {
        return TrimResult(points: zBandPoints, keptFraction: 0, originalCount: originalCount)
    }

    var filteredPoints = zBandPoints

    if filteredPoints.count >= 20 {
        let xs = filteredPoints.map { $0.x }
        let ys = filteredPoints.map { $0.y }
        let zs = filteredPoints.map { $0.z }

        let highPercentile = max(0, min(1, config.percentile))
        let lowPercentile = max(0, min(1, 1 - config.percentile))

        if highPercentile >= lowPercentile {
            let xLow = percentile(xs, percentile: lowPercentile)
            let xHigh = percentile(xs, percentile: highPercentile)
            let yLow = percentile(ys, percentile: lowPercentile)
            let yHigh = percentile(ys, percentile: highPercentile)
            let zLow = percentile(zs, percentile: lowPercentile)
            let zHigh = percentile(zs, percentile: highPercentile)

            let trimmed = filteredPoints.filter { point in
                point.x >= xLow && point.x <= xHigh &&
                point.y >= yLow && point.y <= yHigh &&
                point.z >= zLow && point.z <= zHigh
            }

            if !trimmed.isEmpty {
                filteredPoints = trimmed
            }
        }
    }

    let keptFraction = originalCount > 0 ? Float(filteredPoints.count) / Float(originalCount) : 0

    return TrimResult(points: filteredPoints, keptFraction: keptFraction, originalCount: originalCount)
}

private struct ROIInfo {
    let rect: CGRect?
    let sampleCount: Int
}

private func makeROIInfo(width: Int, height: Int, roi: CGRect?) -> ROIInfo {
    guard width > 0, height > 0 else {
        return ROIInfo(rect: nil, sampleCount: 0)
    }

    guard let roi else {
        return ROIInfo(rect: nil, sampleCount: width * height)
    }

    if roi.isNull || roi.isEmpty {
        return ROIInfo(rect: nil, sampleCount: 0)
    }

    let xStart = max(0, Int(floor(roi.minX)))
    let yStart = max(0, Int(floor(roi.minY)))
    let xEnd = min(width, Int(ceil(roi.maxX)))
    let yEnd = min(height, Int(ceil(roi.maxY)))

    if xStart >= xEnd || yStart >= yEnd {
        return ROIInfo(rect: nil, sampleCount: 0)
    }

    let sanitized = CGRect(
        x: CGFloat(xStart),
        y: CGFloat(yStart),
        width: CGFloat(xEnd - xStart),
        height: CGFloat(yEnd - yStart)
    )
    let sampleCount = (xEnd - xStart) * (yEnd - yStart)
    return ROIInfo(rect: sanitized, sampleCount: sampleCount)
}

private func fitGroundPlaneLSQ(points: [SIMD3<Float>], percentile: Float) -> (a: Float, b: Float, c: Float)? {
    guard !points.isEmpty else { return nil }

    let clampedPercentile = max(0, min(1, percentile))
    let sortedZ = points.map { $0.z }.sorted()
    guard let lastIndex = sortedZ.indices.last else { return nil }
    let thresholdIndex = min(max(Int(Float(lastIndex) * clampedPercentile), 0), lastIndex)
    let zThreshold = sortedZ[thresholdIndex]
    let candidates = points.filter { $0.z <= zThreshold }
    guard candidates.count >= 100 else { return nil }

    var ata = simd_float3x3()
    var atz = SIMD3<Float>(repeating: 0)
    for point in candidates {
        let v = SIMD3<Float>(point.x, point.y, 1)
        ata += simd_outer(v, v)
        atz += v * point.z
    }

    let determinant = simd_determinant(ata)
    guard determinant.isFinite, abs(determinant) > 1e-6 else { return nil }

    let coeff = simd_inverse(ata) * atz
    guard coeff.x.isFinite, coeff.y.isFinite, coeff.z.isFinite else { return nil }
    return (coeff.x, coeff.y, coeff.z)
}

private func clipGround(points: [SIMD3<Float>], plane: (a: Float, b: Float, c: Float), eps: Float) -> [SIMD3<Float>] {
    let (a, b, c) = plane
    return points.filter { point in
        let predictedZ = a * point.x + b * point.y + c
        return (point.z - predictedZ) > eps
    }
}

private func computeAndLogVolume(for points: [SIMD3<Float>], roiInfo: ROIInfo, unit: VolumeUnit) {
    let baseStats = points.withUnsafeBufferPointer { buffer -> VolumeStats in
        computeAABBVolume(points: buffer, unit: unit)
    }

    let totalSamples = roiInfo.sampleCount
    let confidence: Double
    if totalSamples > 0 && baseStats.numPointsUsed > 0 {
        confidence = Double(baseStats.numPointsUsed) / Double(totalSamples)
    } else {
        confidence = 0
    }

    let finalStats = VolumeStats(
        volumeML: baseStats.volumeML,
        bboxMin: baseStats.bboxMin,
        bboxMax: baseStats.bboxMax,
        numPointsUsed: baseStats.numPointsUsed,
        numPointsTotal: totalSamples,
        confidence: confidence
    )

    logVolumeStats(finalStats, unit: unit)
}

private func logVolumeStats(_ stats: VolumeStats, unit: VolumeUnit) {
    let confidenceClamped = max(0, min(1, stats.confidence))
    print(
        String(
            format: "Points(total=%d, used=%d, conf=%.2f)",
            stats.numPointsTotal,
            stats.numPointsUsed,
            confidenceClamped
        )
    )

    print(
        String(
            format: "BBox[m]: x:[%.4f, %.4f], y:[%.4f, %.4f], z:[%.4f, %.4f]",
            stats.bboxMin.x,
            stats.bboxMax.x,
            stats.bboxMin.y,
            stats.bboxMax.y,
            stats.bboxMin.z,
            stats.bboxMax.z
        )
    )

    let volumeValue = stats.volumeML
    let volumeString: String
    switch unit {
    case .ml, .cm3:
        volumeString = String(format: "%.2f", volumeValue)
    case .m3:
        volumeString = String(format: "%.6f", volumeValue)
    }

    print("Volume: \(volumeString) \(unit.displayName)")

    if stats.numPointsUsed < 500 {
        fputs("Warning: zu wenig Punkte für robuste AABB, Ergebnis unsicher.\n", stderr)
    }

    let lowerBound: Float = 0.10
    let upperBound: Float = 0.80
    if stats.numPointsUsed > 0 {
        if stats.bboxMin.z <= lowerBound + 0.001 {
            fputs("Warning: Bounding box minimum depth is near the lower filter limit (0.10 m).\n", stderr)
        }
        if stats.bboxMax.z >= upperBound - 0.001 {
            fputs("Warning: Bounding box maximum depth is near the upper filter limit (0.80 m).\n", stderr)
        }
    }
}

private enum PointCloudFormat {
    case ply
    case xyz

    var defaultExtension: String {
        switch self {
        case .ply:
            return "ply"
        case .xyz:
            return "xyz"
        }
    }

    var description: String {
        switch self {
        case .ply:
            return "PLY"
        case .xyz:
            return "XYZ"
        }
    }
}

private struct PointCloudRequest {
    let format: PointCloudFormat
    let path: String
}

private struct DepthGenerationResult {
    let depthPixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let destinationURL: URL
}

private struct CommandLineOptions {
    enum IntrinsicsSpecifier {
        case explicit(CameraIntrinsics)
        case fov(Float)
        case unspecified
        case invalid(String)
    }

    let inputPath: String
    let outputPath: String?
    let pointCloudRequests: [PointCloudRequest]
    let volumeRequested: Bool
    let volumeUnit: VolumeUnit
    let intrinsicsSpecifier: IntrinsicsSpecifier
    let intrinsicsIssues: [String]
    let ignoredFOV: Float?
    let roiSpecifier: ROISpecifier
    let groundClipConfig: GroundClipConfig?
    let trimConfig: TrimConfig
    let trimMessages: [String]

    static func parse() throws -> CommandLineOptions {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            throw DepthRunnerError.invalidUsage("Missing required <eingabe_bildpfad> argument.")
        }

        var inputPath: String?
        var outputPath: String?
        var pointCloudRequests: [PointCloudRequest] = []
        var volumeRequested = false
        var volumeUnit: VolumeUnit = .ml

        var fx: Float?
        var fy: Float?
        var cx: Float?
        var cy: Float?
        var providedFOV: Float?
        var intrinsicsIssues: [String] = []
        var ignoredFOV: Float?
        var roiSpecifier: ROISpecifier = .none
        var clipGround = false
        var groundPercentile: Float = 0.10
        var groundEps: Float = 0.008
        var groundPercentileSpecified = false
        var groundEpsSpecified = false
        var trimPercentile: Float = 0.98
        var trimMessages: [String] = []
        var zBandMin: Float = 0.10
        var zBandMax: Float = 0.80

        func parseFloat(_ value: String, flag: String) -> Float? {
            if let parsed = Float(value) {
                return parsed
            }
            intrinsicsIssues.append("Value for \(flag) must be a valid number (got \(value)).")
            return nil
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--out":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --out option.")
                }
                outputPath = arguments[index]
            case "--ply":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --ply option.")
                }
                pointCloudRequests.append(PointCloudRequest(format: .ply, path: arguments[index]))
            case "--xyz":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --xyz option.")
                }
                pointCloudRequests.append(PointCloudRequest(format: .xyz, path: arguments[index]))
            case "--volume":
                volumeRequested = true
            case "--unit":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --unit option.")
                }
                let value = arguments[index].lowercased()
                guard let parsedUnit = VolumeUnit(rawValue: value) else {
                    throw DepthRunnerError.invalidUsage("Unknown volume unit: \(value). Expected ml, cm3, or m3.")
                }
                volumeUnit = parsedUnit
            case "--fx":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --fx option.")
                }
                fx = parseFloat(arguments[index], flag: "--fx")
            case "--fy":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --fy option.")
                }
                fy = parseFloat(arguments[index], flag: "--fy")
            case "--cx":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --cx option.")
                }
                cx = parseFloat(arguments[index], flag: "--cx")
            case "--cy":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --cy option.")
                }
                cy = parseFloat(arguments[index], flag: "--cy")
            case "--fov":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --fov option.")
                }
                providedFOV = parseFloat(arguments[index], flag: "--fov")
            case "--roi":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --roi option.")
                }
                let value = arguments[index]
                let components = value.split(separator: "=", maxSplits: 1)
                guard components.count == 2 else {
                    throw DepthRunnerError.invalidUsage("ROI must be specified as center=<fraction>.")
                }
                let key = components[0].lowercased()
                let fractionString = String(components[1])
                guard key == "center" else {
                    throw DepthRunnerError.invalidUsage("Unsupported ROI specifier: \(key). Only center=<fraction> is supported.")
                }
                guard let fraction = Float(fractionString) else {
                    throw DepthRunnerError.invalidUsage("ROI fraction must be a valid number (got \(fractionString)).")
                }
                guard fraction > 0, fraction <= 1 else {
                    throw DepthRunnerError.invalidUsage("ROI fraction must be between 0 and 1 (exclusive of 0).")
                }
                roiSpecifier = .center(fraction)
            case "--clip-ground":
                clipGround = true
            case "--ground-percentile":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --ground-percentile option.")
                }
                guard let value = Float(arguments[index]) else {
                    throw DepthRunnerError.invalidUsage("Value for --ground-percentile must be a valid number.")
                }
                groundPercentile = value
                groundPercentileSpecified = true
            case "--ground-eps":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --ground-eps option.")
                }
                guard let value = Float(arguments[index]) else {
                    throw DepthRunnerError.invalidUsage("Value for --ground-eps must be a valid number.")
                }
                groundEps = value
                groundEpsSpecified = true
            case "--trim-percentile":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --trim-percentile option.")
                }
                let valueString = arguments[index]
                if let value = Float(valueString), value >= 0.90, value <= 0.999 {
                    trimPercentile = value
                } else {
                    trimMessages.append("Warning: --trim-percentile must be between 0.90 and 0.999 (got \(valueString)); using default 0.98.")
                    trimPercentile = 0.98
                }
            case "--z-band":
                index += 1
                guard index < arguments.count else {
                    throw DepthRunnerError.invalidUsage("Missing value for --z-band option.")
                }
                let value = arguments[index]
                let components = value.split(separator: ",")
                if components.count == 2,
                   let minValue = Float(components[0].trimmingCharacters(in: .whitespaces)),
                   let maxValue = Float(components[1].trimmingCharacters(in: .whitespaces)),
                   minValue >= 0,
                   minValue < maxValue {
                    zBandMin = minValue
                    zBandMax = maxValue
                } else {
                    trimMessages.append("Warning: --z-band must be specified as min,max with min < max (got \(value)); using default 0.10,0.80.")
                    zBandMin = 0.10
                    zBandMax = 0.80
                }
            default:
                if argument.hasPrefix("--") {
                    throw DepthRunnerError.invalidUsage("Unknown option: \(argument)")
                } else if inputPath == nil {
                    inputPath = argument
                } else {
                    throw DepthRunnerError.invalidUsage("Unexpected extra argument: \(argument)")
                }
            }
            index += 1
        }

        guard let resolvedInputPath = inputPath else {
            throw DepthRunnerError.invalidUsage("Missing required <eingabe_bildpfad> argument.")
        }

        if (groundPercentileSpecified || groundEpsSpecified) && !clipGround {
            throw DepthRunnerError.invalidUsage("--ground-percentile and --ground-eps require --clip-ground.")
        }

        if clipGround {
            if groundPercentile <= 0 || groundPercentile > 1 {
                throw DepthRunnerError.invalidUsage("--ground-percentile must be in the range (0, 1].")
            }
            if groundEps <= 0 {
                throw DepthRunnerError.invalidUsage("--ground-eps must be a positive number.")
            }
        }

        var intrinsicsSpecifier: IntrinsicsSpecifier = .unspecified

        if let fxValue = fx, let fyValue = fy, let cxValue = cx, let cyValue = cy {
            if fxValue > 0, fyValue > 0 {
                intrinsicsSpecifier = .explicit(CameraIntrinsics(fx: fxValue, fy: fyValue, cx: cxValue, cy: cyValue))
            } else {
                intrinsicsIssues.append("fx and fy must be positive numbers.")
            }
        } else if fx != nil || fy != nil || cx != nil || cy != nil {
            intrinsicsIssues.append("All of --fx, --fy, --cx, and --cy must be provided together.")
        }

        if let fovValue = providedFOV {
            if fovValue > 0, fovValue < 180 {
                switch intrinsicsSpecifier {
                case .explicit:
                    ignoredFOV = fovValue
                default:
                    intrinsicsSpecifier = .fov(fovValue)
                }
            } else {
                intrinsicsIssues.append("Field of view must be between 0 and 180 degrees (exclusive).")
            }
        }

        if intrinsicsIssues.contains(where: { !$0.isEmpty }) {
            if case .unspecified = intrinsicsSpecifier {
                intrinsicsSpecifier = .invalid(intrinsicsIssues.joined(separator: " "))
            }
        }

        let groundConfig = clipGround ? GroundClipConfig(percentile: groundPercentile, eps: groundEps) : nil
        let trimConfig = TrimConfig(percentile: trimPercentile, zMin: zBandMin, zMax: zBandMax)

        return CommandLineOptions(
            inputPath: resolvedInputPath,
            outputPath: outputPath,
            pointCloudRequests: pointCloudRequests,
            volumeRequested: volumeRequested,
            volumeUnit: volumeUnit,
            intrinsicsSpecifier: intrinsicsSpecifier,
            intrinsicsIssues: intrinsicsIssues,
            ignoredFOV: ignoredFOV,
            roiSpecifier: roiSpecifier,
            groundClipConfig: groundConfig,
            trimConfig: trimConfig,
            trimMessages: trimMessages
        )
    }

    var requiresPointCloud: Bool {
        volumeRequested || !pointCloudRequests.isEmpty || groundClipConfig != nil
    }

    func resolveIntrinsics(width: Int, height: Int) -> (CameraIntrinsics, [String]) {
        let fallbackFOV: Float = 60
        var messages: [String] = []

        if let ignoredFOV {
            messages.append(String(format: "Warning: Ignoring --fov %.2f° because explicit intrinsics were provided.", ignoredFOV))
        }

        if !intrinsicsIssues.isEmpty, case .unspecified = intrinsicsSpecifier {
            messages.append("Warning: Invalid camera intrinsics input detected (\(intrinsicsIssues.joined(separator: " "))). Falling back to default assumptions.")
        }

        switch intrinsicsSpecifier {
        case .explicit(let intrinsics):
            messages.append(String(format: "Using explicit camera intrinsics (fx=%.2f, fy=%.2f, cx=%.2f, cy=%.2f).", intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy))
            return (intrinsics, messages)
        case .fov(let fovValue):
            let intrinsics = CommandLineOptions.makeIntrinsics(fromFOV: fovValue, width: width, height: height)
            messages.append(String(format: "Using camera intrinsics derived from FOV=%.2f° (fx=%.2f, fy=%.2f, cx=%.2f, cy=%.2f).", fovValue, intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy))
            if !intrinsicsIssues.isEmpty {
                messages.append("Warning: \(intrinsicsIssues.joined(separator: " "))")
            }
            return (intrinsics, messages)
        case .unspecified:
            if !intrinsicsIssues.isEmpty {
                messages.append("Warning: \(intrinsicsIssues.joined(separator: " "))")
            }
            let intrinsics = CommandLineOptions.makeIntrinsics(fromFOV: fallbackFOV, width: width, height: height)
            messages.append(String(format: "Warning: Assuming FOV=%.2f° with cx=%.2f, cy=%.2f (fx=%.2f, fy=%.2f).", fallbackFOV, intrinsics.cx, intrinsics.cy, intrinsics.fx, intrinsics.fy))
            return (intrinsics, messages)
        case .invalid(let reason):
            if !reason.isEmpty {
                messages.append("Warning: \(reason)")
            } else if !intrinsicsIssues.isEmpty {
                messages.append("Warning: \(intrinsicsIssues.joined(separator: " "))")
            }
            let intrinsics = CommandLineOptions.makeIntrinsics(fromFOV: fallbackFOV, width: width, height: height)
            messages.append(String(format: "Warning: Falling back to FOV=%.2f° with cx=%.2f, cy=%.2f (fx=%.2f, fy=%.2f).", fallbackFOV, intrinsics.cx, intrinsics.cy, intrinsics.fx, intrinsics.fy))
            return (intrinsics, messages)
        }
    }

    private static func makeIntrinsics(fromFOV fov: Float, width: Int, height: Int) -> CameraIntrinsics {
        let radians = fov * .pi / 180
        let fx = (0.5 * Float(width)) / tan(radians / 2)
        let fy = fx
        let cx = Float(width) / 2
        let cy = Float(height) / 2
        return CameraIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy)
    }
}

private struct ModelLocator {
    private let fileManager = FileManager.default

    func locateModel() throws -> URL {
        let bundle = Bundle.main
        if let resourceURLs = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil),
           let first = resourceURLs.first {
            return first
        }
        if let resourceURLs = bundle.urls(forResourcesWithExtension: "mlmodel", subdirectory: nil),
           let first = resourceURLs.first {
            return try compileModelIfNeeded(at: first)
        }

#if SWIFT_PACKAGE
        let packageBundle = Bundle.module
        if let resourceURLs = packageBundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil),
           let first = resourceURLs.first {
            return first
        }
        if let resourceURLs = packageBundle.urls(forResourcesWithExtension: "mlmodel", subdirectory: nil),
           let first = resourceURLs.first {
            return try compileModelIfNeeded(at: first)
        }
#endif

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let searchDirectories = [
            workingDirectory.appendingPathComponent("Models", isDirectory: true),
            workingDirectory.appendingPathComponent("DepthPrediction-CoreML/mlmodel", isDirectory: true),
            workingDirectory
        ]

        for directory in searchDirectories {
            if let url = try findModel(in: directory) {
                return url
            }
        }

        if let enumerator = fileManager.enumerator(at: workingDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if let modelURL = try findModel(at: url) {
                    return modelURL
                }
            }
        }

        throw DepthRunnerError.modelNotFound
    }

    private func findModel(in directory: URL) throws -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in contents {
            if let modelURL = try findModel(at: item) {
                return modelURL
            }
        }
        return nil
    }

    private func findModel(at url: URL) throws -> URL? {
        if url.pathExtension == "mlmodelc" {
            return url
        }
        if url.pathExtension == "mlmodel" {
            return try compileModelIfNeeded(at: url)
        }
        return nil
    }

    private func compileModelIfNeeded(at url: URL) throws -> URL {
        let compiledURL = url.appendingPathExtension("mlmodelc")
        if fileManager.fileExists(atPath: compiledURL.path) {
            return compiledURL
        }
        return try MLModel.compileModel(at: url)
    }
}

private struct DepthMapGenerator {
    private struct DepthData {
        let values: [Float]
        let width: Int
        let height: Int
        let pixelBuffer: CVPixelBuffer
    }

    private let model: MLModel

    init(modelURL: URL) throws {
        self.model = try MLModel(contentsOf: modelURL)
    }

    func generateDepthMap(inputPath: String, outputPath: String?) throws -> DepthGenerationResult {
        let expandedInput = (inputPath as NSString).expandingTildeInPath
        let inputURL = URL(fileURLWithPath: expandedInput)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw DepthRunnerError.inputNotFound(inputPath)
        }

        let cgImage = try loadImage(at: inputURL)
        let inputFeatures = try prepareInputFeatures(from: cgImage)
        let output = try model.prediction(from: inputFeatures)

        let depthData = try extractDepthData(from: output)
        let grayscaleData = normalize(values: depthData.values)
        let depthImage = try makeGrayscaleImage(from: grayscaleData, width: depthData.width, height: depthData.height)

        let destinationURL = try resolveOutputURL(from: outputPath)
        try save(image: depthImage, to: destinationURL)

        return DepthGenerationResult(
            depthPixelBuffer: depthData.pixelBuffer,
            width: depthData.width,
            height: depthData.height,
            destinationURL: destinationURL
        )
    }

    private func prepareInputFeatures(from image: CGImage) throws -> MLDictionaryFeatureProvider {
        guard let (name, description) = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = description.imageConstraint else {
            throw DepthRunnerError.unsupportedModel("Model does not expose an image input.")
        }

        let size = CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
        let pixelBuffer = try makePixelBuffer(from: image, size: size)
        let featureValue = try MLFeatureValue(pixelBuffer: pixelBuffer, orientation: .up, constraint: constraint)
        return try MLDictionaryFeatureProvider(dictionary: [name: featureValue])
    }

    private func extractDepthData(from provider: MLFeatureProvider) throws -> DepthData {
        guard let featureName = provider.featureNames.first else {
            throw DepthRunnerError.unsupportedModel("Model produced no output features.")
        }
        guard let featureValue = provider.featureValue(for: featureName) else {
            throw DepthRunnerError.unsupportedModel("Missing output feature \(featureName) in prediction results.")
        }

        if let multiArray = featureValue.multiArrayValue {
            return try extractDepthData(from: multiArray)
        }
        if let buffer = featureValue.imageBufferValue {
            return try extractDepthData(from: buffer)
        }
        throw DepthRunnerError.unsupportedModel("Model output \(featureName) must be an image or multi-array.")
    }

    private func extractDepthData(from multiArray: MLMultiArray) throws -> DepthData {
        let shape = multiArray.shape.map { Int(truncating: $0) }
        let dimensions: (height: Int, width: Int)
        switch shape.count {
        case 2:
            dimensions = (shape[0], shape[1])
        case 3:
            if shape[0] == 1 {
                dimensions = (shape[1], shape[2])
            } else if shape[2] == 1 {
                dimensions = (shape[0], shape[1])
            } else {
                throw DepthRunnerError.unsupportedModel("Unsupported multi-array shape: \(shape)")
            }
        default:
            throw DepthRunnerError.unsupportedModel("Unsupported multi-array shape: \(shape)")
        }

        let floats = try multiArray.toFloatArray()
        let pixelBuffer = try makeDepthPixelBuffer(from: floats, width: dimensions.width, height: dimensions.height)
        return DepthData(values: floats, width: dimensions.width, height: dimensions.height, pixelBuffer: pixelBuffer)
    }

    private func extractDepthData(from pixelBuffer: CVPixelBuffer) throws -> DepthData {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let count = width * height
        var values = [Float](repeating: 0, count: count)

        switch pixelFormat {
        case kCVPixelFormatType_OneComponent32Float:
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw DepthRunnerError.imageCreationFailed
            }
            let pointer = baseAddress.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                values[index] = pointer[index]
            }
        case kCVPixelFormatType_OneComponent16Half:
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw DepthRunnerError.imageCreationFailed
            }
            let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
            for index in 0..<count {
                let float16 = Float16(bitPattern: pointer[index])
                values[index] = Float(float16)
            }
        default:
            throw DepthRunnerError.unsupportedModel("Unsupported pixel buffer format: \(pixelFormat)")
        }

        return DepthData(values: values, width: width, height: height, pixelBuffer: pixelBuffer)
    }

    private func makeDepthPixelBuffer(from values: [Float], width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBufferOptional: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent32Float,
            nil,
            &pixelBufferOptional
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOptional else {
            throw DepthRunnerError.imageCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DepthRunnerError.imageCreationFailed
        }

        let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.size
        values.withUnsafeBufferPointer { buffer in
            let pointer = baseAddress.assumingMemoryBound(to: Float.self)
            for row in 0..<height {
                let destination = pointer.advanced(by: row * rowStride)
                let source = buffer.baseAddress!.advanced(by: row * width)
                destination.assign(from: source, count: width)
            }
        }

        return pixelBuffer
    }

    private func normalize(values: [Float]) -> [UInt8] {
        guard let minValue = values.min(), let maxValue = values.max(), maxValue > minValue else {
            return [UInt8](repeating: 0, count: values.count)
        }
        let range = maxValue - minValue
        return values.map { value in
            let normalized = (value - minValue) / range
            return UInt8(clamping: Int(round(normalized * 255)))
        }
    }

    private func makeGrayscaleImage(from pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw DepthRunnerError.imageCreationFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: [],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw DepthRunnerError.imageCreationFailed
        }
        return image
    }

    private func resolveOutputURL(from providedPath: String?) throws -> URL {
        let baseDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let path = providedPath {
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
            let directoryURL = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if url.pathExtension.isEmpty {
                return url.appendingPathExtension("png")
            }
            return url
        } else {
            let directory = baseDirectory.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("depth_map.png")
        }
    }

    private func save(image: CGImage, to url: URL) throws {
        #if canImport(UniformTypeIdentifiers)
        let pngUTI = UTType.png.identifier as CFString
        #elseif canImport(MobileCoreServices)
        let pngUTI = kUTTypePNG
        #else
        let pngUTI = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, pngUTI, 1, nil) else {
            throw DepthRunnerError.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw DepthRunnerError.imageWriteFailed(url.path)
        }
    }

    enum ROISpecifier {
        case none
        case center(Float)
    }

    func resolveROI(width: Int, height: Int) -> CGRect? {
        switch roiSpecifier {
        case .none:
            return nil
        case .center(let fraction):
            let clampedFraction = max(0, min(1, fraction))
            if clampedFraction == 0 {
                return CGRect.null
            }
            let frameWidth = CGFloat(width)
            let frameHeight = CGFloat(height)
            let roiWidth = frameWidth * CGFloat(clampedFraction)
            let roiHeight = frameHeight * CGFloat(clampedFraction)
            let originX = (frameWidth - roiWidth) / 2
            let originY = (frameHeight - roiHeight) / 2
            return CGRect(x: originX, y: originY, width: roiWidth, height: roiHeight)
        }
    }

    var roiDescription: String? {
        switch roiSpecifier {
        case .none:
            return nil
        case .center(let fraction):
            return String(format: "center=%.2f", fraction)
        }
    }
}

private func loadImage(at url: URL) throws -> CGImage {
    let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
    guard let ciImage = CIImage(contentsOf: url, options: options) else {
        throw DepthRunnerError.imageLoadFailed(url.path)
    }
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
        throw DepthRunnerError.imageLoadFailed(url.path)
    }
    return cgImage
}

private func makePixelBuffer(from image: CGImage, size: CGSize) throws -> CVPixelBuffer {
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    var pixelBufferOptional: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(size.width),
        Int(size.height),
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pixelBufferOptional
    )
    guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOptional else {
        throw DepthRunnerError.imageCreationFailed
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else {
        throw DepthRunnerError.imageCreationFailed
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
    return pixelBuffer
}

private func resolvePointCloudURL(from path: String, defaultExtension: String) throws -> URL {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw DepthRunnerError.invalidUsage("Point cloud output path must not be empty.")
    }

    let baseDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let expandedPath = (trimmed as NSString).expandingTildeInPath
    var url = URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
    if url.pathExtension.isEmpty {
        url.appendPathExtension(defaultExtension)
    }
    return url
}

private enum DepthRunnerError: LocalizedError {
    case invalidUsage(String)
    case inputNotFound(String)
    case modelNotFound
    case unsupportedModel(String)
    case imageLoadFailed(String)
    case imageCreationFailed
    case imageWriteFailed(String)
    case pointCloudWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUsage(let message):
            return "\(message)\nUsage: swift run DepthRunner <eingabe_bildpfad> [--out <ausgabe_pfad>] [--ply <ply_pfad>] [--xyz <xyz_pfad>] [--fov <grad> | --fx <fx> --fy <fy> --cx <cx> --cy <cy>]"
        case .inputNotFound(let path):
            return "Input image not found at path: \(path)"
        case .modelNotFound:
            return "Could not locate a Core ML depth model (.mlmodel or .mlmodelc)."
        case .unsupportedModel(let message):
            return message
        case .imageLoadFailed(let path):
            return "Unable to load image at path: \(path)"
        case .imageCreationFailed:
            return "Failed to create image buffer."
        case .imageWriteFailed(let path):
            return "Failed to write PNG to \(path)"
        case .pointCloudWriteFailed(let path):
            return "Failed to write point cloud to \(path)"
        }
    }
}

private extension MLMultiArray {
    func toFloatArray() throws -> [Float] {
        let totalCount = count
        var result = [Float](repeating: 0, count: totalCount)
        switch dataType {
        case .float32:
            let pointer = dataPointer.bindMemory(to: Float32.self, capacity: totalCount)
            for index in 0..<totalCount {
                result[index] = Float(pointer[index])
            }
        case .double:
            let pointer = dataPointer.bindMemory(to: Double.self, capacity: totalCount)
            for index in 0..<totalCount {
                result[index] = Float(pointer[index])
            }
        case .float16:
            let pointer = dataPointer.bindMemory(to: UInt16.self, capacity: totalCount)
            for index in 0..<totalCount {
                let float16 = Float16(bitPattern: pointer[index])
                result[index] = Float(float16)
            }
        default:
            throw DepthRunnerError.unsupportedModel("Unsupported multi-array data type: \(dataType)")
        }
        return result
    }
}
