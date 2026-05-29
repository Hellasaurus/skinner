import Foundation

/// The runtime flavors an XML attribute value can take in a WMS skin file.
public enum AttributeValue: Hashable, Sendable {
    /// A plain literal: `"364"`, `"true"`, `"#ff00ff"`, `"mainback.png"`.
    case literal(String)
    /// A JScript arithmetic expression: `jscript:view.width - 166`.
    case jsExpr(String)
    /// A live WMP property binding: `wmpprop:player.settings.volume`.
    case wmpProp(String)
    /// A conditional-enable binding: `wmpenabled:player.controls.pause`.
    case wmpEnabled(String)
}

public extension AttributeValue {
    init(_ raw: String) {
        let lower = raw.lowercased()
        if lower.hasPrefix("jscript:") {
            self = .jsExpr(String(raw.dropFirst(8)))
        } else if lower.hasPrefix("wmpprop:") {
            self = .wmpProp(String(raw.dropFirst(8)))
        } else if lower.hasPrefix("wmpenabled:") {
            self = .wmpEnabled(String(raw.dropFirst(11)))
        } else {
            self = .literal(raw)
        }
    }

    /// Non-nil only for `.literal`.
    var literalString: String? {
        guard case .literal(let s) = self else { return nil }
        return s
    }

    var boolValue: Bool? {
        literalString.map { $0.lowercased() == "true" || $0 == "1" }
    }

    var intValue: Int? { literalString.flatMap(Int.init) }
    var doubleValue: Double? { literalString.flatMap(Double.init) }
}
