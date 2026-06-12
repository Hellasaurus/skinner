import AppKit

// MARK: - MapData

/// Raw RGBA pixel data decoded from an asset image, used for hit-testing.
public struct MapData {
    public let bytes: [UInt8]
    public let width: Int
    public let height: Int
}

// MARK: - ButtonGroupAssets

/// Pre-built CGImage masks for one ButtonGroup's mapping image.
///
/// `masks` is keyed by `ButtonElement.mappingColor` (lowercased, e.g. `"#33ff00"`).
/// `fullMask` is the union of all recognised button regions and is used to clip the
/// normal image so pixels outside any button region are hidden.
public struct ButtonGroupAssets {
    public let groupID:  String?
    public let fullMask: CGImage?
    public let masks:    [String: CGImage]
}

// MARK: - AssetCache

/// All image assets needed to render a Theme, loaded once at skin-open time.
public final class AssetCache {
    /// Magenta-cleaned `NSImage` for every referenced asset filename (key: lowercased).
    public let images: [String: NSImage]
    /// Raw RGBA pixel data for every referenced asset (key: lowercased filename).
    public let mapData: [String: MapData]
    /// Mask data for every `ButtonGroup` found in the theme, keyed by lowercased mappingImage filename.
    public let buttonGroupsByMappingImage: [String: ButtonGroupAssets]
    /// Filenames (lowercased) used as `clippingImage` on any button or buttonGroup.
    /// Subview `backgroundImage` entries in this set are clip masks, not visual backgrounds.
    public let clipImageNames: Set<String>
    /// CGImage alpha masks built from `clippingImage` files (non-transparent pixels → 255).
    /// Used to clip button and buttonGroup drawing to the skin's shaped regions.
    public let clipMasks: [String: CGImage]

    /// Returns pre-built mask assets for the given mapping image filename, or `nil` if not found.
    public func buttonGroupAssets(forMappingImage name: String?) -> ButtonGroupAssets? {
        guard let name else { return nil }
        return buttonGroupsByMappingImage[name.lowercased()]
    }

    private init(images: [String: NSImage],
                 mapData: [String: MapData],
                 buttonGroupsByMappingImage: [String: ButtonGroupAssets],
                 clipImageNames: Set<String>,
                 clipMasks: [String: CGImage]) {
        self.images = images
        self.mapData = mapData
        self.buttonGroupsByMappingImage = buttonGroupsByMappingImage
        self.clipImageNames = clipImageNames
        self.clipMasks = clipMasks
    }

    // MARK: - Factory

    public static func build(from bundle: SkinBundle, theme: Theme,
                              imageOverrides: [String: ImageOverride] = [:]) -> AssetCache {
        var filenames = Set<String>()
        for view in theme.views {
            collectFilenames(from: view.elements, into: &filenames)
        }

        // Collect per-image transparent colors (clippingColor + transparencyColor from every
        // element) so they can be zeroed alongside magenta during image loading.
        var extraTransparentColors: [String: [(UInt8, UInt8, UInt8)]] = [:]
        for view in theme.views {
            collectImageTransparentColors(from: view.elements, into: &extraTransparentColors)
        }

        var images:  [String: NSImage] = [:]
        var mapData: [String: MapData] = [:]
        for name in filenames {
            let url = bundle.assetURL(named: name)
            let key = name.lowercased()
            if let img = loadMagentaFree(url: url, extraTransparent: extraTransparentColors[key] ?? []) {
                images[key] = imageOverrides[key]?.apply(to: img) ?? img
            }
            if let md  = loadMapData(url: url)     { mapData[key] = md }
        }

        // Scripts reference image filenames not declared in the WMS (e.g. shutter_open2.gif
        // set via element.backgroundImage at runtime).  Load everything in the bundle directory
        // so those assets are available when the canvas draws them.
        let scriptImageExts: Set<String> = ["png", "gif", "bmp", "jpg", "jpeg"]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: bundle.directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for fileURL in entries
            where scriptImageExts.contains(fileURL.pathExtension.lowercased()) {
                let key = fileURL.lastPathComponent.lowercased()
                if images[key]  == nil, let img = loadMagentaFree(url: fileURL, extraTransparent: extraTransparentColors[key] ?? []) {
                    images[key] = imageOverrides[key]?.apply(to: img) ?? img
                }
                if mapData[key] == nil, let md  = loadMapData(url: fileURL)     { mapData[key] = md  }
            }
        }

        var groupsByMappingImage: [String: ButtonGroupAssets] = [:]
        for view in theme.views {
            for group in allButtonGroups(in: view.elements) {
                let assets = buildGroupAssets(group, mapData: mapData)
                if let key = group.mappingImage?.lowercased() {
                    groupsByMappingImage[key] = assets
                }
            }
        }

        // Collect every filename used as a clippingImage, then build shape masks for them.
        var clipNames = Set<String>()
        for view in theme.views {
            collectClipImageNames(from: view.elements, into: &clipNames)
        }
        var clipMasks: [String: CGImage] = [:]
        for name in clipNames {
            if let md = mapData[name] {
                if let mask = buildClipMask(from: md) { clipMasks[name] = mask }
            }
        }

        return AssetCache(images: images, mapData: mapData,
                          buttonGroupsByMappingImage: groupsByMappingImage,
                          clipImageNames: clipNames,
                          clipMasks: clipMasks)
    }
}

// MARK: - Filename collection (recursive element walk)

private func collectFilenames(from elements: [SkinElement], into set: inout Set<String>) {
    for element in elements {
        switch element {
        case .subview(let sv):
            if let img = sv.backgroundImage { set.insert(img) }
            collectFilenames(from: sv.children, into: &set)
        case .button(let b):
            [b.image, b.hoverImage, b.downImage, b.disabledImage, b.hoverDownImage, b.clippingImage]
                .forEach { if let s = $0 { set.insert(s) } }
        case .buttonGroup(let bg):
            [bg.image, bg.hoverImage, bg.downImage, bg.disabledImage, bg.mappingImage, bg.clippingImage]
                .forEach { if let s = $0 { set.insert(s) } }
        case .slider(let s):
            [s.thumbImage, s.thumbDownImage, s.foregroundImage, s.image, s.positionImage]
                .forEach { if let f = $0 { set.insert(f) } }
        default:
            break
        }
    }
}

// MARK: - ButtonGroup traversal (recursive)

private func allButtonGroups(in elements: [SkinElement]) -> [ButtonGroup] {
    var result: [ButtonGroup] = []
    for element in elements {
        switch element {
        case .buttonGroup(let bg): result.append(bg)
        case .subview(let sv):     result += allButtonGroups(in: sv.children)
        default: break
        }
    }
    return result
}

// MARK: - Per-image transparent color collection

/// Walks every element and records all `clippingColor` / `transparencyColor` values that
/// apply to each image file.  Both attributes act as chroma-keys: pixels matching any
/// collected color are zeroed (made transparent) alongside magenta when the image is loaded.
///
/// Handles hex strings (`#RRGGBB`) and CSS named colors (`white`, `green`, …).
/// `"none"`, `"auto"`, and empty strings are silently ignored.
private func collectImageTransparentColors(from elements: [SkinElement],
                                            into map: inout [String: [(UInt8, UInt8, UInt8)]]) {
    func add(_ name: String?, _ colorStr: String?) {
        guard let name, let colorStr, let rgb = parseAnyColor(colorStr) else { return }
        let key = name.lowercased()
        map[key, default: []].append(rgb)
    }

    for element in elements {
        switch element {
        case .subview(let sv):
            // Both clippingColor and transparencyColor apply to the background image.
            add(sv.backgroundImage, sv.clippingColor)
            add(sv.backgroundImage, sv.base.transparencyColor)
            collectImageTransparentColors(from: sv.children, into: &map)

        case .button(let b):
            let tc = b.base.transparencyColor
            for name in [b.image, b.hoverImage, b.downImage, b.disabledImage, b.hoverDownImage] {
                add(name, tc)
            }

        case .buttonGroup(let bg):
            let tc = bg.base.transparencyColor
            for name in [bg.image, bg.hoverImage, bg.downImage, bg.disabledImage] {
                add(name, tc)
            }

        default: break
        }
    }
}

// MARK: - Clip image name collection

private func collectClipImageNames(from elements: [SkinElement], into set: inout Set<String>) {
    for element in elements {
        switch element {
        case .button(let b):
            if let name = b.clippingImage { set.insert(name.lowercased()) }
        case .buttonGroup(let bg):
            if let name = bg.clippingImage { set.insert(name.lowercased()) }
            collectClipImageNames(from: bg.elements.compactMap { _ in nil }, into: &set)
        case .subview(let sv):
            collectClipImageNames(from: sv.children, into: &set)
        default: break
        }
    }
}

// MARK: - Clip mask builder

/// Builds a grayscale CGImage mask where pixels that are NOT "transparent" in the
/// clipping image map to 255 (show) and "transparent" pixels map to 0 (clip away).
/// WMP skins use white (r>240, g>240, b>240) as the clip-transparent colour in
/// clippingImage files; magenta and zero-alpha are also treated as transparent.
private func buildClipMask(from md: MapData) -> CGImage? {
    let region = (0 ..< md.width * md.height).map { i -> Bool in
        let o = i * 4
        let r = md.bytes[o], g = md.bytes[o + 1], b = md.bytes[o + 2], a = md.bytes[o + 3]
        guard a > 10 else { return false }
        if isMagenta(r, g, b)                  { return false }
        if r > 240 && g > 240 && b > 240       { return false } // white = transparent
        return true
    }
    return makeGrayMask(region: region, width: md.width, height: md.height)
}

// MARK: - ButtonGroupAssets builder

private func buildGroupAssets(_ group: ButtonGroup,
                               mapData: [String: MapData]) -> ButtonGroupAssets {
    guard let mapName = group.mappingImage,
          let md = mapData[mapName.lowercased()]
    else {
        return ButtonGroupAssets(groupID: group.base.id, fullMask: nil, masks: [:])
    }

    let parsedColors: [(key: String, r: UInt8, g: UInt8, b: UInt8)] =
        group.elements.compactMap { elem in
            parseHexColor(elem.mappingColor).map { (elem.mappingColor.lowercased(), $0.0, $0.1, $0.2) }
        }

    var perButton: [String: [Bool]] = [:]
    var fullRegion = [Bool](repeating: false, count: md.width * md.height)

    for i in 0 ..< md.width * md.height {
        let base = i * 4
        let r = md.bytes[base], g = md.bytes[base + 1],
            b = md.bytes[base + 2], a = md.bytes[base + 3]
        guard a > 128 else { continue }
        // A pixel matching one of this group's mappingColors belongs to that button even
        // if the colour happens to be magenta or white (e.g. a `#FF00FF` nextelement) —
        // only fall back to the magenta/white "no button here" convention otherwise.
        if let match = parsedColors.first(where: { colorMatches(r, g, b, $0.r, $0.g, $0.b) }) {
            fullRegion[i] = true
            if perButton[match.key] == nil {
                perButton[match.key] = [Bool](repeating: false, count: md.width * md.height)
            }
            perButton[match.key]![i] = true
        } else if !isMagenta(r, g, b), !(r > 240 && g > 240 && b > 240) {
            fullRegion[i] = true
        }
    }

    var masks: [String: CGImage] = [:]
    for (colorKey, region) in perButton {
        if let img = makeGrayMask(region: region, width: md.width, height: md.height) {
            masks[colorKey] = img
        }
    }
    let fullMask = makeGrayMask(region: fullRegion, width: md.width, height: md.height)

    return ButtonGroupAssets(groupID: group.base.id, fullMask: fullMask, masks: masks)
}

// MARK: - Image loading

private func loadMagentaFree(url: URL,
                              extraTransparent: [(UInt8, UInt8, UInt8)] = []) -> NSImage? {
    guard let raw = NSImage(contentsOf: url),
          let cg  = raw.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = makeBitmapContext(width: cg.width, height: cg.height)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let data = ctx.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
    for i in 0 ..< cg.width * cg.height {
        let o = i * 4
        let r = pixels[o], g = pixels[o + 1], b = pixels[o + 2]
        let erase = isMagenta(r, g, b) ||
            extraTransparent.contains { colorMatches(r, g, b, $0.0, $0.1, $0.2) }
        if erase {
            pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
        }
    }
    guard let result = ctx.makeImage() else { return nil }
    return NSImage(cgImage: result, size: NSSize(width: cg.width, height: cg.height))
}

private func loadMapData(url: URL) -> MapData? {
    guard let raw = NSImage(contentsOf: url),
          let cg  = raw.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = makeBitmapContext(width: cg.width, height: cg.height)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let data = ctx.data else { return nil }
    let count = cg.width * cg.height * 4
    let src = data.bindMemory(to: UInt8.self, capacity: count)
    return MapData(bytes: Array(UnsafeBufferPointer(start: src, count: count)),
                   width: cg.width, height: cg.height)
}

// MARK: - Mask building

private func makeGrayMask(region: [Bool], width: Int, height: Int) -> CGImage? {
    // `region` is indexed in MapData row order (row 0 = visual top), but
    // `ctx.clip(to:mask:)` mirrors the mask vertically relative to the destination
    // in this isFlipped view, so the mask bytes must be row-flipped here.
    var bytes = [UInt8](repeating: 0, count: width * height)
    for row in 0 ..< height {
        let srcRow = height - 1 - row
        for x in 0 ..< width {
            bytes[row * width + x] = region[srcRow * width + x] ? 255 : 0
        }
    }
    guard let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
    let cfData = Data(bytes) as CFData
    guard let provider = CGDataProvider(data: cfData) else { return nil }
    return CGImage(width: width, height: height,
                   bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: width,
                   space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: false,
                   intent: .defaultIntent)
}

// MARK: - Pixel helpers
