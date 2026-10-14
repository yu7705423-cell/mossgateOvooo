import SwiftUI

/// 网页版的线条图标（Resources/shell.json 的 icons，由 scripts/sync-shell.mjs 从 src/icons/paths.js 抄来）。
///
/// 网页版图标是 24 格的 SVG 片段：path、circle、rect、ellipse，描边 1.6、圆头圆角，
/// 个别写 fill="currentColor"（实心点）、stroke="none"、stroke-opacity、transform="rotate(…)"。
/// 这里只认这几样，够画全部图标；认不出的元素跳过。
struct SvgIcon: View {
    let name: String
    var size: CGFloat = 24
    var lineWidth: CGFloat = 1.6
    var color: Color = .primary

    var body: some View {
        let parts = SvgShapes.parts(name)
        Canvas { ctx, sz in
            let k = sz.width / 24
            let t = CGAffineTransform(scaleX: k, y: k)
            for p in parts {
                let path = Path(p.path).applying(t)
                if p.fill { ctx.fill(path, with: .color(color.opacity(p.opacity))) }
                if p.stroke {
                    ctx.stroke(path, with: .color(color.opacity(p.opacity)),
                               style: StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum SvgShapes {
    struct Part {
        var path: CGPath
        var fill: Bool
        var stroke: Bool
        var opacity: Double
    }

    nonisolated(unsafe) private static var cache: [String: [Part]] = [:]
    private static let lock = NSLock()

    static func parts(_ name: String) -> [Part] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let made = parse(Shell.icons[name] ?? Shell.icons["dashed"] ?? "")
        cache[name] = made
        return made
    }

    /// 一段 SVG 片段 → 若干笔。
    static func parse(_ svg: String) -> [Part] {
        var out: [Part] = []
        let tagRe = try! NSRegularExpression(pattern: "<(path|circle|rect|ellipse)\\b([^>]*)/?>")
        let attrRe = try! NSRegularExpression(pattern: "([a-zA-Z-]+)=\"([^\"]*)\"")
        let ns = svg as NSString
        for m in tagRe.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            let attrText = ns.substring(with: m.range(at: 2)) as NSString
            var a: [String: String] = [:]
            for am in attrRe.matches(in: attrText as String, range: NSRange(location: 0, length: attrText.length)) {
                a[attrText.substring(with: am.range(at: 1))] = attrText.substring(with: am.range(at: 2))
            }
            let n = { (k: String) -> CGFloat in CGFloat(Double(a[k] ?? "") ?? 0) }
            let p = CGMutablePath()
            switch tag {
            case "path": p.addPath(PathData.parse(a["d"] ?? ""))
            case "circle": p.addEllipse(in: CGRect(x: n("cx") - n("r"), y: n("cy") - n("r"), width: n("r") * 2, height: n("r") * 2))
            case "ellipse": p.addEllipse(in: CGRect(x: n("cx") - n("rx"), y: n("cy") - n("ry"), width: n("rx") * 2, height: n("ry") * 2))
            case "rect":
                let r = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
                let rx = min(a["rx"] != nil ? n("rx") : n("ry"), r.width / 2, r.height / 2)
                if rx > 0 { p.addRoundedRect(in: r, cornerWidth: rx, cornerHeight: rx) } else { p.addRect(r) }
            default: continue
            }
            var path: CGPath = p
            if let tr = a["transform"], let t = rotation(tr) {
                var tt = t
                path = p.copy(using: &tt) ?? p
            }
            let fill = a["fill"].map { $0 != "none" } ?? false
            let stroke = a["stroke"] != "none"
            let opacity = Double(a["stroke-opacity"] ?? a["opacity"] ?? "") ?? 1
            out.append(Part(path: path, fill: fill, stroke: stroke, opacity: opacity))
        }
        return out
    }

    /// rotate(角度 cx cy)
    private static func rotation(_ s: String) -> CGAffineTransform? {
        guard s.hasPrefix("rotate(") else { return nil }
        let nums = s.dropFirst(7).dropLast().split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard let deg = nums.first else { return nil }
        let cx = nums.count > 2 ? nums[1] : 0, cy = nums.count > 2 ? nums[2] : 0
        return CGAffineTransform(translationX: cx, y: cy).rotated(by: deg * .pi / 180).translatedBy(x: -cx, y: -cy)
    }
}

/// SVG 路径的 d 属性。支持 M L H V C S Q T A Z 及其小写（相对）形式，
/// 以及网页图标里常见的紧凑写法：「.5.5」「1-2」「a2 2 0 012 2」（弧的两个标志位不用分隔）。
enum PathData {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        let chars = Array(d.utf8)
        var i = 0
        var cmd: UInt8 = 0
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?   // 上一段三次或二次曲线的第二个控制点，S / T 要用
        var lastWasCubic = false, lastWasQuad = false

        func skipSep() { while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 || chars[i] == 9 || chars[i] == 13 { i += 1 } }
        func number() -> CGFloat? {
            skipSep()
            let s = i
            if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
            var dot = false, digits = false
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 { digits = true; i += 1 }
                else if c == 46 && !dot { dot = true; i += 1 }
                else if (c == 101 || c == 69) && digits {
                    i += 1
                    if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
                } else { break }
            }
            guard digits, let v = Double(String(decoding: chars[s..<i], as: UTF8.self)) else { i = s; return nil }
            return CGFloat(v)
        }
        func flag() -> Bool? {
            skipSep()
            guard i < chars.count, chars[i] == 48 || chars[i] == 49 else { return nil }
            defer { i += 1 }
            return chars[i] == 49
        }
        func isCmd(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }

        while true {
            skipSep()
            guard i < chars.count else { break }
            if isCmd(chars[i]) { cmd = chars[i]; i += 1 }
            else if cmd == 0 { break }
            let rel = cmd >= 97
            let base = rel ? cur : .zero
            var cubic = false, quad = false
            switch cmd | 32 {
            case 109: // m
                guard let x = number(), let y = number() else { return path }
                cur = CGPoint(x: base.x + x, y: base.y + y); start = cur
                path.move(to: cur)
                cmd = rel ? 108 : 76   // 之后的坐标对按 l / L
            case 108: // l
                guard let x = number(), let y = number() else { return path }
                cur = CGPoint(x: base.x + x, y: base.y + y); path.addLine(to: cur)
            case 104: // h
                guard let x = number() else { return path }
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y); path.addLine(to: cur)
            case 118: // v
                guard let y = number() else { return path }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); path.addLine(to: cur)
            case 99: // c
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1), c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtrl = c2; cubic = true
            case 115: // s
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let c1 = lastWasCubic && lastCtrl != nil ? CGPoint(x: 2 * cur.x - lastCtrl!.x, y: 2 * cur.y - lastCtrl!.y) : cur
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtrl = c2; cubic = true
            case 113: // q
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return path }
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastCtrl = c; quad = true
            case 116: // t
                guard let x = number(), let y = number() else { return path }
                let c = lastWasQuad && lastCtrl != nil ? CGPoint(x: 2 * cur.x - lastCtrl!.x, y: 2 * cur.y - lastCtrl!.y) : cur
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastCtrl = c; quad = true
            case 97: // a
                guard let rx = number(), let ry = number(), let rot = number(),
                      let large = flag(), let sweep = flag(), let x = number(), let y = number() else { return path }
                let to = CGPoint(x: base.x + x, y: base.y + y)
                arc(path, from: cur, to: to, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = to
            case 122: // z
                path.closeSubpath(); cur = start
            default:
                return path
            }
            lastWasCubic = cubic; lastWasQuad = quad
        }
        return path
    }

    /// SVG 的端点式椭圆弧 → 若干段三次贝塞尔（SVG 规范附录 F.6 的换算）。
    static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                    rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cs = cos(phi), sn = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cs * dx + sn * dy, y1p = -sn * dx + cs * dy
        let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lam > 1 { let s = sqrt(lam); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = cs * cxp - sn * cyp + (p0.x + p1.x) / 2
        let cy = sn * cxp + cs * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / CGFloat(segs)
        let kappa = 4 / 3 * tan(step / 4)
        func pt(_ t: CGFloat) -> CGPoint {
            let x = rx * cos(t), y = ry * sin(t)
            return CGPoint(x: cx + cs * x - sn * y, y: cy + sn * x + cs * y)
        }
        func der(_ t: CGFloat) -> CGPoint {
            let x = -rx * sin(t), y = ry * cos(t)
            return CGPoint(x: cs * x - sn * y, y: sn * x + cs * y)
        }
        var t = t1
        for s in 0..<segs {
            let a = pt(t), b = s == segs - 1 ? p1 : pt(t + step)
            let da = der(t), db = der(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + kappa * da.x, y: a.y + kappa * da.y),
                          control2: CGPoint(x: b.x - kappa * db.x, y: b.y - kappa * db.y))
            t += step
        }
    }
}
