import AppKit

// MARK: - PNG I/O

/// Writes images and raw pixel buffers to disk as PNG, for debug inspection
/// (transparency masks, button-group hit regions, rendered frames, …).
public enum ImageDebugIO {
    public enum DebugIOError: Error, CustomStringConvertible {
        case noCGImage
        case noPNGData

        public var description: String {
            switch self {
            case .noCGImage: return "Could not obtain a CGImage to encode"
            case .noPNGData: return "Failed to encode PNG data"
            }
        }
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw DebugIOError.noPNGData
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: url)
    }

    public static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DebugIOError.noCGImage
        }
        try writePNG(cg, to: url)
    }

    /// Writes a raw RGBA buffer (as stored in `MapData`) as a PNG.
    public static func writePNG(rgba bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let ctx = makeBitmapContext(width: width, height: height), let data = ctx.data else {
            throw DebugIOError.noCGImage
        }
        bytes.withUnsafeBytes { src in
            data.copyMemory(from: src.baseAddress!, byteCount: min(src.count, width * height * 4))
        }
        guard let cg = ctx.makeImage() else { throw DebugIOError.noCGImage }
        try writePNG(cg, to: url)
    }
}

// MARK: - Image transforms

/// Pixel-level transforms for layering debug — render an asset fully transparent
/// (to see what's beneath it) or as a black silhouette (to see its shape/bounds).
public enum ImageDebugTransform {
    /// Returns a copy of `image`, fully transparent, same dimensions.
    public static func transparent(_ image: NSImage) -> NSImage {
        transformPixels(image) { pixels, count in
            for i in 0 ..< count {
                let o = i * 4
                pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
            }
        }
    }

    /// Returns a copy of `image` with RGB forced to `rgb` (default black), alpha preserved.
    public static func silhouette(_ image: NSImage, rgb: (UInt8, UInt8, UInt8) = (0, 0, 0)) -> NSImage {
        transformPixels(image) { pixels, count in
            for i in 0 ..< count {
                let o = i * 4
                pixels[o] = rgb.0; pixels[o + 1] = rgb.1; pixels[o + 2] = rgb.2
            }
        }
    }

    private static func transformPixels(_ image: NSImage,
                                          _ transform: (UnsafeMutablePointer<UInt8>, Int) -> Void) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = makeBitmapContext(width: cg.width, height: cg.height)
        else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = ctx.data else { return image }
        let pixels = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        transform(pixels, cg.width * cg.height)
        guard let result = ctx.makeImage() else { return image }
        return NSImage(cgImage: result, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Image overrides

/// A debug override applied to a loaded asset image, for layering checks.
public enum ImageOverride: Sendable {
    case transparent
    case black

    func apply(to image: NSImage) -> NSImage {
        switch self {
        case .transparent: return ImageDebugTransform.transparent(image)
        case .black:       return ImageDebugTransform.silhouette(image)
        }
    }
}

/// Parses `SKINNER_IMG_TRANSPARENT` / `SKINNER_IMG_BLACK` (comma-separated, lowercased
/// filenames) from the environment into an override map keyed by lowercased filename.
/// Used by `AppDelegate` to pass `imageOverrides:` into `AssetCache.build`.
public func imageOverridesFromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> [String: ImageOverride] {
    var result: [String: ImageOverride] = [:]
    func add(_ value: String?, _ override: ImageOverride) {
        guard let value else { return }
        for name in value.split(separator: ",") {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            result[key] = override
        }
    }
    add(env["SKINNER_IMG_TRANSPARENT"], .transparent)
    add(env["SKINNER_IMG_BLACK"], .black)
    return result
}

// MARK: - AssetCache buffer dump

extension AssetCache {
    /// Writes every cached `mapData` buffer, button-group mask, and clip mask in this
    /// cache to `directory` as PNGs, for inspecting transparency, button-group hit
    /// regions, and clip shapes outside the running app.
    public func dumpDebugImages(to directory: URL) throws {
        for (name, md) in mapData {
            try ImageDebugIO.writePNG(rgba: md.bytes, width: md.width, height: md.height,
                                       to: directory.appendingPathComponent("mapdata_\(name).png"))
        }
        for (mappingName, assets) in buttonGroupsByMappingImage {
            if let full = assets.fullMask {
                try ImageDebugIO.writePNG(full, to: directory.appendingPathComponent(
                    "buttongroup_\(mappingName)_full.png"))
            }
            for (color, mask) in assets.masks {
                let safeColor = color.replacingOccurrences(of: "#", with: "")
                try ImageDebugIO.writePNG(mask, to: directory.appendingPathComponent(
                    "buttongroup_\(mappingName)_\(safeColor).png"))
            }
        }
        for (name, mask) in clipMasks {
            try ImageDebugIO.writePNG(mask, to: directory.appendingPathComponent("clipmask_\(name).png"))
        }
    }
}
