import AppKit

final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    private struct Snapshot { var base: NSImage; var annotations: [Annotation]; var stamp: Int }
    private enum Drag { case none, create, move, resize(Int) }

    private(set) var base: NSImage
    private(set) var annotations: [Annotation] = []
    var tool: Tool = .select {
        didSet { endTextEditing(returnToSelect: false); needsDisplay = true; onToolChange?(tool) }
    }
    var onToolChange: ((Tool) -> Void)?
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var onChange: (() -> Void)?
    /// Called when the selection changes (nil when nothing is selected).
    var onSelect: ((Annotation?) -> Void)?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var current: Annotation?
    private(set) var selected: Int?
    private var drag: Drag = .none
    private var didCommit = false
    private var lastPoint: CGPoint = .zero
    private var nextStamp = 1
    private var cropRect: NSRect?
    private var editor: NSTextField?
    private var editingIndex: Int?
    private var editorOrigin: CGPoint = .zero
    private let handleSize: CGFloat = 9

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage) {
        base = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drawing

    private func drawContent(includeUI: Bool) {
        for i in annotations.indices where annotations[i].kind == .text {
            annotations[i].wrapLimit = annotations[i].customWidth ?? wrapWidth(from: annotations[i].a.x)
        }
        base.draw(in: NSRect(origin: .zero, size: base.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for (i, a) in annotations.enumerated() where i != editingIndex { a.draw(base: base) }
        if let c = current, c.kind != .crop { c.draw(base: base) }
        guard includeUI else { return }
        if let i = selected, annotations.indices.contains(i), i != editingIndex {
            let ann = annotations[i]
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: ann.bounds.insetBy(dx: -4, dy: -4))
            p.setLineDash([4, 3], count: 2, phase: 0)
            p.lineWidth = 1
            p.stroke()
            for h in ann.handles {
                let r = NSRect(x: h.x - handleSize / 2, y: h.y - handleSize / 2, width: handleSize, height: handleSize)
                NSColor.white.setFill()
                NSColor.controlAccentColor.setStroke()
                let hp = NSBezierPath(ovalIn: r)
                hp.fill(); hp.lineWidth = 1.5; hp.stroke()
            }
        }
        if let r = cropRect {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let outer = NSBezierPath(rect: bounds)
            outer.append(NSBezierPath(rect: r))
            outer.windingRule = .evenOdd
            outer.fill()
            NSColor.white.setStroke()
            NSBezierPath(rect: r).stroke()
        }
    }

    override func draw(_ dirtyRect: NSRect) { drawContent(includeUI: true) }

    // MARK: Export

    func flattened() -> NSImage {
        let saved = (current, selected, cropRect, editingIndex)
        current = nil; selected = nil; cropRect = nil; editingIndex = nil
        defer { (current, selected, cropRect, editingIndex) = saved }
        return NSImage(size: base.size, flipped: true) { [self] _ in drawContent(includeUI: false); return true }
    }

    private var pixelScale: CGFloat {
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return max(1, CGFloat(cg.width) / base.size.width)
    }

    func bitmap() -> NSBitmapImageRep? {
        endTextEditing()
        let img = flattened()
        let s = pixelScale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(base.size.width * s), pixelsHigh: Int(base.size.height * s),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = base.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: base.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func exportData(_ type: NSBitmapImageRep.FileType, quality: Double = 0.9) -> Data? {
        guard let rep = bitmap() else { return nil }
        if type == .jpeg {
            let flat = NSImage(size: rep.size)
            flat.lockFocus()
            NSColor.white.setFill(); NSRect(origin: .zero, size: rep.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: rep.size))
            flat.unlockFocus()
            guard let t = flat.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { return nil }
            return r.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        return rep.representation(using: type, properties: [:])
    }

    func copyToPasteboard() {
        guard let rep = bitmap(), let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    // MARK: Undo

    private func snapshot() -> Snapshot { Snapshot(base: base, annotations: annotations, stamp: nextStamp) }

    private func restore(_ s: Snapshot) {
        endTextEditing()
        base = s.base; annotations = s.annotations; nextStamp = s.stamp
        setFrameSize(base.size)
        select(nil)
        cropRect = nil
        needsDisplay = true
        onChange?()
    }

    private func commit() {
        undoStack.append(snapshot())
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    @objc func undoEdit(_ sender: Any?) {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(s)
    }

    @objc func redoEdit(_ sender: Any?) {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(s)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @objc func deleteSelection(_ sender: Any?) {
        guard let i = selected, annotations.indices.contains(i) else { return }
        commit()
        annotations.remove(at: i)
        select(nil)
        needsDisplay = true
        onChange?()
    }

    // MARK: Clipboard

    private static let annotationType = NSPasteboard.PasteboardType("local.zquig.annotation")
    private var pasteCount = 0

    /// ⌘C: copy the selected object; with nothing selected, copy the whole annotated image.
    @objc func copy(_ sender: Any?) {
        guard let i = selected, annotations.indices.contains(i) else { return copyToPasteboard() }
        let a = annotations[i]
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = try? PropertyListSerialization.data(fromPropertyList: a.plist, format: .binary, options: 0) {
            pb.setData(data, forType: Self.annotationType)
        }
        if a.kind == .text { pb.setString(a.text, forType: .string) }
        pasteCount = 0
    }

    @objc func cut(_ sender: Any?) {
        guard selected != nil else { return }
        copy(nil)
        deleteSelection(nil)
    }

    /// ⌘V: paste a copied object (offset a little each time), or text as a new text object,
    /// or open an image from the clipboard in a new window.
    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.annotationType),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           var a = Annotation(plist: obj) {
            pasteCount += 1
            let off = CGFloat(14 * pasteCount)
            a.move(by: CGSize(width: off, height: off))
            if a.kind == .stamp { a.number = nextStamp; nextStamp += 1 }
            commit()
            annotations.append(a)
            select(annotations.count - 1)
            onChange?()
        } else if NSImage.canInit(with: pb) {
            NSApp.sendAction(NSSelectorFromString("newFromClipboardOrBlank"), to: nil, from: self)
        } else if let str = pb.string(forType: .string), !str.isEmpty {
            let o = CGPoint(x: visibleRect.minX + 24, y: visibleRect.minY + 24)
            commit()
            annotations.append(Annotation(kind: .text, a: o, b: o, color: color, width: lineWidth, text: str))
            select(annotations.count - 1)
            onChange?()
        } else {
            NSSound.beep()
        }
    }

    // MARK: Selection and styling

    private func select(_ i: Int?) {
        selected = i
        didStyleCommit = false
        if let i = i, annotations.indices.contains(i) {
            let a = annotations[i]
            color = a.color; lineWidth = a.width
            onSelect?(a)
        } else {
            onSelect?(nil)
        }
        needsDisplay = true
    }

    /// Applies a style change to the selected annotation (and remembers it for new ones).
    func applyColor(_ c: NSColor) {
        color = c
        guard let i = selected, annotations.indices.contains(i) else { return }
        if !didStyleCommit { commit(); didStyleCommit = true }
        annotations[i].color = c
        needsDisplay = true
    }

    func applyWidth(_ w: CGFloat) {
        lineWidth = w
        guard let i = selected, annotations.indices.contains(i) else { return }
        if !didStyleCommit { commit(); didStyleCommit = true }
        annotations[i].width = w
        needsDisplay = true
    }
    private var didStyleCommit = false
    func endStyleChange() { didStyleCommit = false }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "a": tool = .select; return
            case "t": tool = .text; return
            case "q": tool = .arrow; return
            default: break
            }
        }
        switch event.keyCode {
        case 51, 117: deleteSelection(nil)
        case 53: select(nil)
        case 123, 124, 125, 126:
            guard let i = selected, annotations.indices.contains(i) else { return super.keyDown(with: event) }
            commit()
            let d: CGSize = event.keyCode == 123 ? CGSize(width: -step, height: 0) : event.keyCode == 124 ? CGSize(width: step, height: 0)
                : event.keyCode == 125 ? CGSize(width: 0, height: step) : CGSize(width: 0, height: -step)
            annotations[i].move(by: d)
            needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEdit(_:)): return !undoStack.isEmpty
        case #selector(redoEdit(_:)): return !redoStack.isEmpty
        case #selector(deleteSelection(_:)), #selector(cut(_:)): return selected != nil
        case #selector(paste(_:)):
            let pb = NSPasteboard.general
            return pb.data(forType: Self.annotationType) != nil || NSImage.canInit(with: pb) || pb.string(forType: .string) != nil
        default: return true
        }
    }

    // MARK: Mouse

    private func handleIndex(at p: CGPoint) -> Int? {
        guard let i = selected, annotations.indices.contains(i) else { return nil }
        return annotations[i].handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= handleSize }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEditing()  // finishing text returns to the Select tool; this click then acts as a Select click
        let p = convert(event.locationInWindow, from: nil)
        lastPoint = p
        didCommit = false
        drag = .none
        let forceNew = event.modifierFlags.contains(.option)

        if !forceNew && tool != .crop {
            if let h = handleIndex(at: p) {
                drag = .resize(h)
                return
            }
            if let i = annotations.lastIndex(where: { $0.hitTest(p) }) {
                select(i)
                if annotations[i].kind == .text && (event.clickCount == 2 || tool == .text) {
                    beginTextEditing(index: i)
                } else {
                    drag = .move
                }
                return
            }
        }
        select(nil)
        if event.clickCount == 2 && tool != .crop {
            tool = .text
            beginTextEditing(at: p)
            return
        }
        switch tool {
        case .select:
            break
        case .text:
            beginTextEditing(at: p)
        case .stamp:
            commit()
            annotations.append(Annotation(kind: .stamp, a: p, b: p, color: color, width: lineWidth, number: nextStamp))
            nextStamp += 1
            select(annotations.count - 1)
            onChange?()
        case .crop:
            cropRect = NSRect(origin: p, size: .zero)
            current = Annotation(kind: .crop, a: p, b: p, color: color, width: lineWidth)
            drag = .create
        case .pen:
            current = Annotation(kind: .pen, a: p, b: p, points: [p], color: color, width: lineWidth)
            drag = .create
        default:
            current = Annotation(kind: tool, a: p, b: p, color: color, width: lineWidth)
            drag = .create
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { lastPoint = p; needsDisplay = true }
        switch drag {
        case .none: return
        case .move:
            guard let i = selected else { return }
            if !didCommit { commit(); didCommit = true }
            annotations[i].move(by: CGSize(width: p.x - lastPoint.x, height: p.y - lastPoint.y))
        case .resize(let h):
            guard let i = selected else { return }
            if !didCommit { commit(); didCommit = true }
            var q = p
            if event.modifierFlags.contains(.shift), [.line, .arrow].contains(annotations[i].kind) {
                q = snapped(p, from: annotations[i].handles[h == 0 ? 1 : 0])
            }
            annotations[i].moveHandle(h, to: q)
        case .create:
            guard var c = current else { return }
            c.b = p
            if c.kind == .pen { c.points.append(p) }
            if c.kind == .crop { cropRect = c.rect.intersection(bounds) }
            if event.modifierFlags.contains(.shift), [.line, .arrow].contains(c.kind) { c.b = snapped(p, from: c.a) }
            current = c
        }
    }

    private func snapped(_ p: CGPoint, from a: CGPoint) -> CGPoint {
        let dx = p.x - a.x, dy = p.y - a.y
        if abs(dx) > abs(dy) * 2 { return CGPoint(x: p.x, y: a.y) }
        if abs(dy) > abs(dx) * 2 { return CGPoint(x: a.x, y: p.y) }
        return p
    }

    override func mouseUp(with event: NSEvent) {
        defer { current = nil; drag = .none; needsDisplay = true; onChange?() }
        guard case .create = drag, let c = current else { return }
        if c.kind == .crop {
            if let r = cropRect, r.width > 4, r.height > 4 { applyCrop(r) }
            cropRect = nil
            return
        }
        let moved = hypot(c.b.x - c.a.x, c.b.y - c.a.y)
        guard moved > 3 || (c.kind == .pen && c.points.count > 1) else { return }
        commit()
        annotations.append(c)
        select(annotations.count - 1)
    }

    private func applyCrop(_ r: NSRect) {
        let img = flattened()
        let s = pixelScale
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cut = cg.cropping(to: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral) else { return }
        commit()
        base = NSImage(cgImage: cut, size: r.size)
        annotations = []
        nextStamp = 1
        select(nil)
        setFrameSize(base.size)
    }

    // MARK: Text (new and existing)

    private func wrapWidth(from x: CGFloat) -> CGFloat { max(40, base.size.width - x - 8) }

    private func beginTextEditing(at p: CGPoint) {
        editingIndex = nil
        startEditor(origin: p, text: "", color: color, width: lineWidth, wrap: wrapWidth(from: p.x))
    }

    private func beginTextEditing(index i: Int) {
        let a = annotations[i]
        editingIndex = i
        startEditor(origin: a.a, text: a.text, color: a.color, width: a.width, wrap: a.customWidth ?? wrapWidth(from: a.a.x))
    }

    private func startEditor(origin p: CGPoint, text: String, color: NSColor, width: CGFloat, wrap: CGFloat) {
        let font = NSFont.systemFont(ofSize: 14 + width * 3, weight: .bold)
        let f = NSTextField(frame: NSRect(x: p.x - 2, y: p.y - 2, width: wrap + 4, height: font.pointSize * 1.4))
        f.stringValue = text
        f.font = font
        f.textColor = color
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.placeholderString = "Type…"
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.delegate = self
        addSubview(f)
        resizeEditor(f)
        window?.makeFirstResponder(f)
        editor = f
        editorOrigin = p
        needsDisplay = true
    }

    private func resizeEditor(_ f: NSTextField) {
        let h = f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: f.frame.width, height: 100_000)).height ?? 0
        f.setFrameSize(NSSize(width: f.frame.width, height: max(h, (f.font?.pointSize ?? 14) * 1.4)))
    }

    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSTextField, f === editor { resizeEditor(f) }
    }

    /// Return inserts a new line; ⌘Return (or Esc, or clicking elsewhere) finishes the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                window?.makeFirstResponder(self)
            } else {
                textView.insertNewlineIgnoringFieldEditor(nil)
                if let f = editor { resizeEditor(f) }
            }
            return true
        default:
            return false
        }
    }

    /// Commits the open text box. Unless the caller is itself changing tools, finishing text
    /// drops back to the Select tool so the next click doesn't open another text box.
    private func endTextEditing(returnToSelect: Bool = true) {
        guard let f = editor else { return }
        defer { if returnToSelect && tool == .text { tool = .select } }
        editor = nil
        let s = f.stringValue
        let idx = editingIndex
        editingIndex = nil
        f.removeFromSuperview()
        if let i = idx, annotations.indices.contains(i) {
            if s == annotations[i].text { needsDisplay = true; return }
            commit()
            if s.isEmpty { annotations.remove(at: i); select(nil) } else { annotations[i].text = s }
        } else if !s.isEmpty {
            commit()
            annotations.append(Annotation(kind: .text, a: editorOrigin, b: editorOrigin, color: color, width: lineWidth, text: s))
            select(annotations.count - 1)
        }
        needsDisplay = true
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditing()
        window?.makeFirstResponder(self)
    }

    // MARK: Image replacement and drag-in

    func setImage(_ image: NSImage) {
        endTextEditing()
        commit()
        base = image
        annotations = []
        nextStamp = 1
        select(nil)
        setFrameSize(image.size)
        needsDisplay = true
        onChange?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let img = NSImage(pasteboard: sender.draggingPasteboard) else { return false }
        setImage(img)
        return true
    }
}
