/// Returns true when the pixel is the chroma-key magenta used by WMP skins.
func isMagenta(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
    r > 240 && g < 15 && b > 240
}

/// Squared-distance colour match; threshold 1200 = 20² × 3, matching the prototype.
func colorMatches(_ r: UInt8, _ g: UInt8, _ b: UInt8,
                  _ cr: UInt8, _ cg: UInt8, _ cb: UInt8) -> Bool {
    let dr = Int(r) - Int(cr), dg = Int(g) - Int(cg), db = Int(b) - Int(cb)
    return dr * dr + dg * dg + db * db < 1200
}

/// Parses `"#rrggbb"` or `"rrggbb"` into component bytes. Returns `nil` for malformed input.
func parseHexColor(_ hex: String) -> (UInt8, UInt8, UInt8)? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s = String(s.dropFirst()) }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    return (UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value         & 0xFF))
}
