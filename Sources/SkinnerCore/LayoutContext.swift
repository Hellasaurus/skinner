import CoreGraphics

/// Resolves `AttributeValue` layout attributes to concrete `CGFloat` values
/// within the coordinate space of a single skin view.
public struct LayoutContext {
    public let viewWidth:  CGFloat
    public let viewHeight: CGFloat

    public init(viewWidth: CGFloat, viewHeight: CGFloat) {
        self.viewWidth  = viewWidth
        self.viewHeight = viewHeight
    }

    /// Returns the resolved point value, or `nil` for unresolvable expressions.
    public func resolve(_ av: AttributeValue?) -> CGFloat? {
        guard let av else { return nil }
        switch av {
        case .literal(let s):
            return Double(s).map { CGFloat($0) }
        case .jsExpr(let expr):
            return evalJScript(expr)
        case .wmpProp, .wmpEnabled:
            return nil
        }
    }

    // MARK: - JScript evaluator
    //
    // Handles: integer/float literals, `view.width`, `view.height`,
    // operators + - * / with standard precedence, and parentheses.

    private enum Token {
        case number(CGFloat)
        case ident(String)
        case op(Character)
        case lparen, rparen
    }

    private func evalJScript(_ expr: String) -> CGFloat? {
        var tokens = tokenize(expr)
        return parseExpr(&tokens)
    }

    private func tokenize(_ expr: String) -> [Token] {
        var tokens: [Token] = []
        var i = expr.startIndex
        while i < expr.endIndex {
            let c = expr[i]
            if c.isWhitespace          { i = expr.index(after: i); continue }
            if c == "("                { tokens.append(.lparen);  i = expr.index(after: i); continue }
            if c == ")"                { tokens.append(.rparen);  i = expr.index(after: i); continue }
            if "+-*/".contains(c)      { tokens.append(.op(c));   i = expr.index(after: i); continue }
            if c.isNumber || c == "." {
                var j = i
                while j < expr.endIndex && (expr[j].isNumber || expr[j] == ".") {
                    j = expr.index(after: j)
                }
                if let v = Double(expr[i..<j]) { tokens.append(.number(CGFloat(v))) }
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < expr.endIndex &&
                      (expr[j].isLetter || expr[j].isNumber || expr[j] == "_" || expr[j] == ".") {
                    j = expr.index(after: j)
                }
                tokens.append(.ident(String(expr[i..<j])))
                i = j
                continue
            }
            i = expr.index(after: i)
        }
        return tokens
    }

    // expr = term (('+' | '-') term)*
    private func parseExpr(_ tokens: inout [Token]) -> CGFloat? {
        guard var left = parseTerm(&tokens) else { return nil }
        while let tok = tokens.first, case .op(let op) = tok, op == "+" || op == "-" {
            tokens.removeFirst()
            guard let right = parseTerm(&tokens) else { return nil }
            left = op == "+" ? left + right : left - right
        }
        return left
    }

    // term = unary (('*' | '/') unary)*
    private func parseTerm(_ tokens: inout [Token]) -> CGFloat? {
        guard var left = parseUnary(&tokens) else { return nil }
        while let tok = tokens.first, case .op(let op) = tok, op == "*" || op == "/" {
            tokens.removeFirst()
            guard let right = parseUnary(&tokens) else { return nil }
            if op == "*" { left *= right }
            else if right != 0 { left /= right }
            else { return nil }
        }
        return left
    }

    // unary = '-' unary | primary
    private func parseUnary(_ tokens: inout [Token]) -> CGFloat? {
        if let tok = tokens.first, case .op(let op) = tok, op == "-" {
            tokens.removeFirst()
            return parseUnary(&tokens).map { -$0 }
        }
        return parsePrimary(&tokens)
    }

    // primary = number | ident | '(' expr ')'
    private func parsePrimary(_ tokens: inout [Token]) -> CGFloat? {
        guard let first = tokens.first else { return nil }
        switch first {
        case .number(let v):
            tokens.removeFirst()
            return v
        case .ident(let name):
            tokens.removeFirst()
            switch name.lowercased() {
            case "view.width":  return viewWidth
            case "view.height": return viewHeight
            default:            return nil
            }
        case .lparen:
            tokens.removeFirst()
            let v = parseExpr(&tokens)
            if case .rparen? = tokens.first { tokens.removeFirst() }
            return v
        default:
            return nil
        }
    }
}
