import CoreGraphics
import CoreVideo
import Foundation
import simd

struct CameraIntrinsics {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

struct PointSample {
    let position: SIMD3<Float>
    let u: Int
    let v: Int
}

func depthToPointCloud(
    depth: CVPixelBuffer,
    intrinsics: CameraIntrinsics,
    zMin: Float = 0.10,
    zMax: Float = 0.80,
    roi: CGRect? = nil
) -> [(Float, Float, Float)] {
    let samples = depthToPointSamples(
        depth: depth,
        intrinsics: intrinsics,
        zMin: zMin,
        zMax: zMax,
        roi: roi
    )
    return samples.map { sample in
        let position = sample.position
        return (position.x, position.y, position.z)
    }
}

func depthToPointSamples(
    depth: CVPixelBuffer,
    intrinsics: CameraIntrinsics,
    zMin: Float = 0.10,
    zMax: Float = 0.80,
    roi: CGRect? = nil
) -> [PointSample] {
    let width = CVPixelBufferGetWidth(depth)
    let height = CVPixelBufferGetHeight(depth)
    guard width > 0, height > 0 else {
        return []
    }

    let region = roi ?? CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    if region.isNull || region.isEmpty {
        return []
    }

    let xStart = max(0, Int(floor(region.minX)))
    let yStart = max(0, Int(floor(region.minY)))
    let xEnd = min(width, Int(ceil(region.maxX)))
    let yEnd = min(height, Int(ceil(region.maxY)))
    if xStart >= xEnd || yStart >= yEnd {
        return []
    }

    var samples: [PointSample] = []
    samples.reserveCapacity((xEnd - xStart) * (yEnd - yStart))

    CVPixelBufferLockBaseAddress(depth, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(depth) else {
        return []
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(depth)
    let pixelFormat = CVPixelBufferGetPixelFormatType(depth)

    func appendPoint(u: Int, v: Int, z: Float) {
        if z.isFinite, z > 0, z >= zMin, z <= zMax {
            let x = (Float(u) - intrinsics.cx) * z / intrinsics.fx
            let y = (Float(v) - intrinsics.cy) * z / intrinsics.fy
            let position = SIMD3<Float>(x, y, z)
            samples.append(PointSample(position: position, u: u, v: v))
        }
    }

    switch pixelFormat {
    case kCVPixelFormatType_OneComponent32Float:
        let pointer = baseAddress.assumingMemoryBound(to: Float.self)
        let rowStride = bytesPerRow / MemoryLayout<Float>.size
        for v in yStart..<yEnd {
            let rowPointer = pointer.advanced(by: v * rowStride)
            for u in xStart..<xEnd {
                let z = rowPointer[u]
                appendPoint(u: u, v: v, z: z)
            }
        }
    case kCVPixelFormatType_OneComponent16Half:
        let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
        let rowStride = bytesPerRow / MemoryLayout<UInt16>.size
        for v in yStart..<yEnd {
            let rowPointer = pointer.advanced(by: v * rowStride)
            for u in xStart..<xEnd {
                let depthValue = Float(Float16(bitPattern: rowPointer[u]))
                appendPoint(u: u, v: v, z: depthValue)
            }
        }
    default:
        return []
    }

    return samples
}
