import Foundation
import CoreGraphics
@testable import SkinnerCore

/// Result of comparing two images pixel-by-pixel.
struct ImageDiffResult: CustomStringConvertible {
    let matches: Bool
    let differingPixelCount: Int
    let maxChannelDelta: UInt8

    var description: String {
        "matches=\(matches) differingPixels=\(differingPixelCount) maxChannelDelta=\(maxChannelDelta)"
    }
}

/// Compares two images pixel-by-pixel (RGBA), allowing up to `tolerance` difference per channel.
/// Dimension mismatches always fail.
func compareImages(_ a: CGImage, _ b: CGImage, tolerance: UInt8 = 0) -> ImageDiffResult {
    guard a.width == b.width, a.height == b.height else {
        return ImageDiffResult(matches: false, differingPixelCount: max(a.width * a.height, b.width * b.height),
                                maxChannelDelta: 255)
    }
    guard let bytesA = rgbaBytes(of: a), let bytesB = rgbaBytes(of: b) else {
        return ImageDiffResult(matches: false, differingPixelCount: a.width * a.height, maxChannelDelta: 255)
    }

    var differingPixels = 0
    var maxDelta: UInt8 = 0
    let pixelCount = a.width * a.height
    for i in 0 ..< pixelCount {
        let o = i * 4
        var pixelDiffers = false
        for c in 0 ..< 4 {
            let delta = UInt8(abs(Int(bytesA[o + c]) - Int(bytesB[o + c])))
            maxDelta = max(maxDelta, delta)
            if delta > tolerance { pixelDiffers = true }
        }
        if pixelDiffers { differingPixels += 1 }
    }

    return ImageDiffResult(matches: differingPixels == 0, differingPixelCount: differingPixels,
                            maxChannelDelta: maxDelta)
}

private func rgbaBytes(of image: CGImage) -> [UInt8]? {
    guard let ctx = makeBitmapContext(width: image.width, height: image.height) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = ctx.data else { return nil }
    let count = image.width * image.height * 4
    return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
}
