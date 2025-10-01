import Foundation
import simd

struct VolumeStats {
    let volumeML: Double
    let bboxMin: SIMD3<Float>
    let bboxMax: SIMD3<Float>
    let numPointsUsed: Int
    let numPointsTotal: Int
    let confidence: Double
}

enum VolumeUnit: String {
    case ml
    case cm3
    case m3

    var displayName: String {
        rawValue
    }
}

func computeAABBVolume(points: UnsafeBufferPointer<SIMD3<Float>>, unit: VolumeUnit = .ml) -> VolumeStats {
    guard let first = points.first else {
        let zero = SIMD3<Float>(repeating: 0)
        return VolumeStats(
            volumeML: 0,
            bboxMin: zero,
            bboxMax: zero,
            numPointsUsed: 0,
            numPointsTotal: 0,
            confidence: 0
        )
    }

    var minPoint = first
    var maxPoint = first

    for point in points {
        minPoint = simd_min(minPoint, point)
        maxPoint = simd_max(maxPoint, point)
    }

    let dx = Double(maxPoint.x - minPoint.x)
    let dy = Double(maxPoint.y - minPoint.y)
    let dz = Double(maxPoint.z - minPoint.z)
    let volumeMeters = max(0, dx * dy * dz)

    let convertedVolume: Double
    switch unit {
    case .ml, .cm3:
        convertedVolume = volumeMeters * 1_000_000
    case .m3:
        convertedVolume = volumeMeters
    }

    return VolumeStats(
        volumeML: convertedVolume,
        bboxMin: minPoint,
        bboxMax: maxPoint,
        numPointsUsed: points.count,
        numPointsTotal: points.count,
        confidence: points.isEmpty ? 0 : 1
    )
}
