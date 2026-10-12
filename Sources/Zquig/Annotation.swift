import AppKit
import CoreImage

enum Tool: Int, CaseIterable {
    case select, arrow, line, rect, ellipse, pen, highlight, text, stamp, pixelate, crop

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .stamp: return "number.circle"
        case .pixelate: return "square.grid.3x3"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlight: return "Highlighter"
        case .text: return "Text"
        case .stamp: return "Numbered Stamp"
        case .pixelate: return "Pixelate"
        case .crop: return "Crop"
        }
    }
}

struct Annotation {
    var kind: Tool
    var a: CGPoint
    var b: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var number: Int = 0
    /// Text wraps at this width (the space between the text origin and the canvas's right edge); set by the canvas.
    var wrapLimit: CGFloat = 10_000
    /// Set when the user drags a text block's side handles; nil means "wrap at the canvas edge".
    var customWidth: CGFloat?
    /// Text only: white border plus soft shadow around the glyphs.
    var outline = true

    var rect: NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private var font: NSFont { NSFont.systemFont(ofSize: 14 + width * 3, weight: .bold) }

    var bounds: NSRect {
        switch kind {
        case .pen:
            guard let f = points.first else { return .zero }
            var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text:
            let ls = layoutSize()  // border/shadow are decoration; selection hugs the glyphs (or the user-set box)
            return NSRect(origin: a, size: NSSize(width: customWidth ?? ls.width, height: ls.height))
        case .stamp:
            return NSRect(x: a.x - 15, y: a.y - 15, width: 30, height: 30)
        default:
            return rect
        }
    }

    func hitTest(_ p: CGPoint) -> Bool {
        let slop = max(6, width)
        switch kind {
        case .line, .arrow:
            return distance(from: p, toSegment: a, b) <= slop + 2
        case .pen:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= slop + 2 }
        case .rect, .ellipse:
            let outer = bounds.insetBy(dx: -slop, dy: -slop)
            let inner = bounds.insetBy(dx: slop * 2, dy: slop * 2)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        default:
            return bounds.insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    /// Resize handles: endpoints for lines/arrows, corners (TL, TR, BR, BL) for box-like shapes.
    var handles: [CGPoint] {
        switch kind {
        case .line, .arrow: return [a, b]
        case .text:
            let r = bounds
            return [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        case .rect, .ellipse, .highlight, .pixelate:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        default: return []
        }
    }

    mutating func moveHandle(_ i: Int, to p: CGPoint) {
        switch kind {
        case .line, .arrow:
            if i == 0 { a = p } else { b = p }
        case .text:
            // 0 = left edge, 1 = right edge: changing the box width re-wraps the text.
            let right = a.x + (customWidth ?? layoutSize().width)
            if i == 1 {
                customWidth = max(40, p.x - a.x)
            } else {
                let newX = min(p.x, right - 40)
                a.x = newX
                customWidth = right - newX
            }
        default:
            let h = handles
            guard h.indices.contains(i) else { return }
            let fixed = h[(i + 2) % 4]
            a = fixed; b = p
        }
    }

    mutating func move(by d: CGSize) {
        a.x += d.width; a.y += d.height
        b.x += d.width; b.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }

    func draw(base: NSImage?) {
        color.setStroke()
        color.setFill()
        switch kind {
        case .line:
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            path.lineWidth = width; path.lineCapStyle = .round
            path.stroke()
        case .arrow:
            drawArrow()
        case .rect:
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = width
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = width
            path.stroke()
        case .pen:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = width
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.stroke()
        case .highlight:
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .multiply
            color.withAlphaComponent(0.45).setFill()
            rect.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        case .text:
            drawText()
        case .stamp:
            let r = bounds
            NSBezierPath(ovalIn: r).fill()
            let label = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.white]
            let s = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        case .pixelate:
            drawPixelated(base: base)
        case .select, .crop:
            break
        }
    }

    /// White border drawn *outside* the glyphs, with a soft shadow underneath.
    private func drawText() {
        let size = font.pointSize
        let radius = max(1, size * 0.05)
        let pad = ceil(size * 0.6)
        let ts = layoutSize()
        guard outline else {
            (text as NSString).draw(with: NSRect(x: a.x, y: a.y, width: wrapLimit, height: ts.height + 4),
                                    options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: color])
            return
        }
        let shadow = Self.shadowImage(text: text, font: font, radius: radius, pad: pad, wrap: wrapLimit, size: ts)
        let dy = max(1.5, size * 0.09)
        shadow.draw(in: NSRect(x: a.x - pad, y: a.y - pad + dy, width: ts.width + 2 * pad, height: ts.height + 2 * pad),
                    from: .zero, operation: .sourceOver, fraction: 0.32, respectFlipped: true, hints: nil)

        func put(_ dx: CGFloat, _ dyy: CGFloat, _ attrs: [NSAttributedString.Key: Any]) {
            (text as NSString).draw(with: NSRect(x: a.x + dx, y: a.y + dyy, width: wrapLimit, height: ts.height + 4),
                                    options: [.usesLineFragmentOrigin], attributes: attrs)
        }
        let borderAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let steps = 32
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            put(cos(t) * radius, sin(t) * radius, borderAttrs)
        }
        put(0, 0, [.font: font, .foregroundColor: color])
    }

    // The shadow is rendered once per (text, size) into its own upright image and then drawn with
    // AppKit's flip-aware image drawing, so it always falls *below* the text in views and exports alike.
    private static var shadowCache: [String: NSImage] = [:]
    private static let ciContext = CIContext()

    private static func shadowImage(text: String, font: NSFont, radius: CGFloat, pad: CGFloat, wrap: CGFloat, size ts: NSSize) -> NSImage {
        let key = "\(font.pointSize)|\(wrap)|\(text)"
        if let hit = shadowCache[key] { return hit }
        let size = NSSize(width: ts.width + 2 * pad, height: ts.height + 2 * pad)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        for i in 0..<32 {
            let t = CGFloat(i) / 32 * 2 * .pi
            // unflipped image: the text block hangs from the top of its rect
            (text as NSString).draw(with: NSRect(x: pad + cos(t) * radius, y: pad + sin(t) * radius, width: wrap, height: ts.height),
                                    options: [.usesLineFragmentOrigin], attributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        var result = NSImage(size: size)
        if let cg = rep.cgImage {
            let input = CIImage(cgImage: cg)
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.setValue(input, forKey: kCIInputImageKey)
            blur?.setValue(font.pointSize * 0.07 * scale, forKey: kCIInputRadiusKey)
            if let out = blur?.outputImage, let blurred = ciContext.createCGImage(out, from: input.extent) {
                result = NSImage(cgImage: blurred, size: size)
            }
        }
        if shadowCache.count > 200 { shadowCache.removeAll() }
        shadowCache[key] = result
        return result
    }

    /// Size of the text laid out within `wrapLimit` (wrapping on words, honouring newlines).
    func layoutSize() -> NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: wrapLimit, height: 100_000),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return NSSize(width: ceil(r.width), height: ceil(r.height))
    }

    private func drawArrow() {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let headLen = min(len, 10 + width * 3)
        let headW = 5 + width * 2
        let shaft = max(1, width * 0.5)
        let neck = CGPoint(x: b.x - ux * headLen, y: b.y - uy * headLen)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: a.x + nx * 0.5, y: a.y + ny * 0.5))
        path.line(to: CGPoint(x: neck.x + nx * shaft, y: neck.y + ny * shaft))
        path.line(to: CGPoint(x: neck.x + nx * headW, y: neck.y + ny * headW))
        path.line(to: b)
        path.line(to: CGPoint(x: neck.x - nx * headW, y: neck.y - ny * headW))
        path.line(to: CGPoint(x: neck.x - nx * shaft, y: neck.y - ny * shaft))
        path.line(to: CGPoint(x: a.x - nx * 0.5, y: a.y - ny * 0.5))
        path.close()
        path.fill()
    }

    private func drawPixelated(base: NSImage?) {
        guard let base = base,
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let r = rect.intersection(NSRect(origin: .zero, size: base.size))
        guard r.width > 2, r.height > 2 else { return }
        let scale = CGFloat(cg.width) / base.size.width
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        guard let piece = cg.cropping(to: px) else { return }
        let block = max(6, width * 2.5) * scale
        let w = max(1, Int(CGFloat(piece.width) / block)), h = max(1, Int(CGFloat(piece.height) / block))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: small, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let l2 = dx * dx + dy * dy
    guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: Pasteboard serialisation (copy/paste of annotations within Zquig)

extension Annotation {
    var plist: [String: Any] {
        let c = color.usingColorSpace(.sRGB) ?? color
        var d: [String: Any] = [
            "kind": kind.rawValue,
            "a": [Double(a.x), Double(a.y)], "b": [Double(b.x), Double(b.y)],
            "points": points.map { [Double($0.x), Double($0.y)] },
            "color": [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)],
            "width": Double(width), "text": text, "number": number,
        ]
        if let w = customWidth { d["customWidth"] = Double(w) }
        return d
    }

    init?(plist d: [String: Any]) {
        func pt(_ v: Any?) -> CGPoint? {
            guard let x = v as? [Double], x.count == 2 else { return nil }
            return CGPoint(x: x[0], y: x[1])
        }
        guard let raw = d["kind"] as? Int, let kind = Tool(rawValue: raw),
              let a = pt(d["a"]), let b = pt(d["b"]),
              let c = d["color"] as? [Double], c.count == 4,
              let width = d["width"] as? Double else { return nil }
        self.init(kind: kind, a: a, b: b, color: NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]), width: CGFloat(width))
        points = (d["points"] as? [[Double]])?.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } ?? []
        text = d["text"] as? String ?? ""
        number = d["number"] as? Int ?? 0
        if let w = d["customWidth"] as? Double { customWidth = CGFloat(w) }
    }
}
