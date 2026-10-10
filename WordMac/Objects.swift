import AppKit

extension NSAttributedString.Key {
    /// JSON of ImageProps on the attachment character of an inline picture.
    static let wcImage = NSAttributedString.Key("wc.image")
    /// JSON of EquationProps on the attachment character of an inline equation.
    static let wcEquation = NSAttributedString.Key("wc.equation")
    /// Id of a floating object anchored at this character.
    static let wcObject = NSAttributedString.Key("wc.object")
}

struct ImageProps: Codable, Equatable {
    var asset: String
    var width: CGFloat
    var height: CGFloat
    /// Fractions cropped from left, top, right, bottom (0 ..< 0.5).
    var crop: [CGFloat] = [0, 0, 0, 0]
    var lockAspect = true
    var alt = ""

    var json: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
    static func decode(_ s: Any?) -> ImageProps? {
        guard let s = s as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ImageProps.self, from: d)
    }
}

struct EquationProps: Codable, Equatable {
    var source: String
    var size: CGFloat

    var json: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
    static func decode(_ s: Any?) -> EquationProps? {
        guard let s = s as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EquationProps.self, from: d)
    }
}

/// Original image files of the document, stored in the package and shared by inline and floating pictures.
final class AssetStore {
    var data: [String: Data] = [:]
    private var cache: [String: NSImage] = [:]

    func add(_ d: Data) -> String {
        let id = String(UUID().uuidString.prefix(10))
        data[id] = d
        return id
    }

    func image(_ id: String) -> NSImage? {
        if let c = cache[id] { return c }
        guard let d = data[id], let img = NSImage(data: d) else { return nil }
        cache[id] = img
        return img
    }

    /// Pixel size of the original, in points at 72 dpi-independent units (largest representation).
    func naturalSize(_ id: String) -> NSSize {
        guard let img = image(id) else { return NSSize(width: 100, height: 100) }
        if let rep = img.representations.max(by: { $0.pixelsWide < $1.pixelsWide }), rep.pixelsWide > 0 {
            return img.size.width > 0 ? img.size : NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return img.size
    }

    /// The picture with its crop applied, drawn at the given point size.
    func rendered(asset id: String, crop: [CGFloat], size: NSSize) -> NSImage {
        guard let src = image(id), size.width > 0, size.height > 0 else { return NSImage(size: NSSize(width: 1, height: 1)) }
        let s = src.size
        let l = crop[0], t = crop[1], r = crop[2], b = crop[3]
        let from = NSRect(x: l * s.width, y: b * s.height, width: s.width * (1 - l - r), height: s.height * (1 - t - b))
        return NSImage(size: size, flipped: false) { rect in
            src.draw(in: rect, from: from, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return true
        }
    }
}

enum AttachmentBuilder {
    static func imageAttachment(_ p: ImageProps, assets: AssetStore) -> NSTextAttachment {
        let att = NSTextAttachment()
        let img = assets.rendered(asset: p.asset, crop: p.crop, size: NSSize(width: p.width, height: p.height))
        img.accessibilityDescription = p.alt.isEmpty ? "Picture" : p.alt
        att.image = img
        att.bounds = CGRect(x: 0, y: 0, width: p.width, height: p.height)
        return att
    }

    static func equationAttachment(_ p: EquationProps) -> NSTextAttachment {
        let r = MathRenderer.render(p.source, fontSize: p.size)
        let att = NSTextAttachment()
        r.image.accessibilityDescription = "Equation: " + p.source
        att.image = r.image
        att.bounds = CGRect(x: 0, y: -r.descent, width: r.image.size.width, height: r.image.size.height)
        return att
    }

    /// Rebuilds attachments that were stripped when the document was saved.
    static func restore(_ storage: NSMutableAttributedString, assets: AssetStore) {
        let full = NSRange(location: 0, length: storage.length)
        var imgs: [(NSRange, ImageProps)] = []
        var eqs: [(NSRange, EquationProps)] = []
        storage.enumerateAttribute(.wcImage, in: full, options: []) { v, r, _ in
            if let p = ImageProps.decode(v) { imgs.append((r, p)) }
        }
        storage.enumerateAttribute(.wcEquation, in: full, options: []) { v, r, _ in
            if let p = EquationProps.decode(v) { eqs.append((r, p)) }
        }
        for (r, p) in imgs where storage.attribute(.attachment, at: r.location, effectiveRange: nil) == nil {
            storage.addAttribute(.attachment, value: imageAttachment(p, assets: assets), range: r)
        }
        for (r, p) in eqs where storage.attribute(.attachment, at: r.location, effectiveRange: nil) == nil {
            storage.addAttribute(.attachment, value: equationAttachment(p), range: r)
        }
    }

    /// A copy safe to archive: attachment objects are dropped, the markers that rebuild them stay.
    static func stripped(_ storage: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: storage)
        m.removeAttribute(.attachment, range: NSRange(location: 0, length: m.length))
        return m
    }
}


// MARK: - Floating objects

enum WrapMode: String, Codable, CaseIterable, Identifiable {
    case square, topBottom, front, behind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .square: "Square (text wraps around)"
        case .topBottom: "Top and Bottom"
        case .front: "In Front of Text"
        case .behind: "Behind Text"
        }
    }
    var wrapsText: Bool { self == .square || self == .topBottom }
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rect, rounded, ellipse, triangle, diamond, line, arrow, star
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rect: "Rectangle"
        case .rounded: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .diamond: "Diamond"
        case .line: "Line"
        case .arrow: "Arrow"
        case .star: "Star"
        }
    }
    var symbol: String {
        switch self {
        case .rect: "rectangle"
        case .rounded: "rectangle.roundedtop"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        case .line: "line.diagonal"
        case .arrow: "arrow.right"
        case .star: "star"
        }
    }
}

/// A picture, shape or text box positioned on a page, anchored at a character so it follows its paragraph's page.
struct FloatingObject: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case image, shape, textbox }
    var id: String
    var kind: Kind
    var shape: ShapeKind = .rect
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
    var wrap: WrapMode = .square
    var fill: [CGFloat]? = nil
    var stroke: [CGFloat]? = [0, 0, 0, 1]
    var strokeWidth: CGFloat = 1
    var image: ImageProps? = nil
    var rtf: Data? = nil
    var z = 0
    var alt = ""

    static func color(_ a: [CGFloat]?) -> NSColor? {
        guard let a, a.count >= 4 else { return nil }
        return NSColor(srgbRed: a[0], green: a[1], blue: a[2], alpha: a[3])
    }

    static func components(_ c: NSColor?) -> [CGFloat]? {
        guard let c, let s = c.usingColorSpace(.sRGB) else { return nil }
        return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
    }
}

struct PlacedObject {
    var obj: FloatingObject
    var page: Int
}

enum ObjectDrawing {
    static func path(_ kind: ShapeKind, in r: NSRect) -> NSBezierPath {
        switch kind {
        case .rect: return NSBezierPath(rect: r)
        case .rounded: return NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) * 0.16, yRadius: min(r.width, r.height) * 0.16)
        case .ellipse: return NSBezierPath(ovalIn: r)
        case .triangle:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.maxY)); p.close()
            return p
        case .diamond:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
            p.line(to: NSPoint(x: r.midX, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.midY)); p.close()
            return p
        case .line:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX, y: r.midY)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
            return p
        case .arrow:
            let p = NSBezierPath()
            let head = min(r.height * 0.8, r.width * 0.3)
            p.move(to: NSPoint(x: r.minX, y: r.midY)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
            p.move(to: NSPoint(x: r.maxX - head, y: r.midY - head / 2)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
            p.line(to: NSPoint(x: r.maxX - head, y: r.midY + head / 2))
            return p
        case .star:
            let p = NSBezierPath()
            let c = NSPoint(x: r.midX, y: r.midY + r.height * 0.04)
            let ro = min(r.width, r.height) / 2 * 1.05, ri = ro * 0.4
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let rad = i % 2 == 0 ? ro : ri
                let pt = NSPoint(x: c.x + cos(a) * rad * (r.width / min(r.width, r.height)), y: c.y + sin(a) * rad * (r.height / min(r.width, r.height)))
                if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
            }
            p.close()
            return p
        }
    }

    /// Draws the object into `r` in a flipped coordinate system.
    static func draw(_ o: FloatingObject, in r: NSRect, assets: AssetStore?) {
        switch o.kind {
        case .image:
            guard let p = o.image, let img = assets?.image(p.asset) else { return }
            let s = img.size
            let c = p.crop
            let from = NSRect(x: c[0] * s.width, y: c[3] * s.height, width: s.width * (1 - c[0] - c[2]), height: s.height * (1 - c[1] - c[3]))
            img.draw(in: r, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
            if let stroke = FloatingObject.color(o.stroke), o.strokeWidth > 0, o.fill != nil {
                stroke.setStroke(); let b = NSBezierPath(rect: r); b.lineWidth = o.strokeWidth; b.stroke()
            }
        case .shape, .textbox:
            let kind: ShapeKind = o.kind == .textbox ? (o.shape == .rounded ? .rounded : .rect) : o.shape
            let inset = r.insetBy(dx: o.strokeWidth / 2, dy: o.strokeWidth / 2)
            let path = Self.path(kind, in: inset)
            if kind != .line && kind != .arrow, let f = FloatingObject.color(o.fill) { f.setFill(); path.fill() }
            if let s = FloatingObject.color(o.stroke), o.strokeWidth > 0 {
                s.setStroke(); path.lineWidth = o.strokeWidth; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
            }
        }
    }
}
