import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Small "drag me" handle: drag it to Finder, Mail, Messages, etc. to hand over the annotated image as a PNG.
final class DragHandle: NSView, NSDraggingSource {
    var provider: (() -> Data?)?
    var name = "Zquig"

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 28) }

    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    /// Icon only, drawn like the other toolbar icons (with the standard soft highlight on hover).
    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: "Drag out")?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.secondaryLabelColor.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    /// The dragged PNG lives in a per-drag temp folder; remove it shortly after the drop (the receiver may read it lazily).
    private var dragDir: URL?

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let dir = dragDir else { return }
        dragDir = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: dir) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let data = provider?(), data.count > 0 else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zquig-drag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dragDir = dir
        let url = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".png")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 64, height: 48), contents: NSImage(data: data))
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

/// Remembers the last-used colours and thickness between windows and launches.
enum Prefs {
    private static let d = UserDefaults.standard

    private static func store(_ c: NSColor, _ key: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true) { d.set(data, forKey: key) }
    }
    private static func load(_ key: String) -> NSColor? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    static var color: NSColor { get { load("color") ?? .systemRed } set { store(newValue, "color") } }
    static var textOutline: Bool {
        get { d.object(forKey: "textOutline") as? Bool ?? true }
        set { d.set(newValue, forKey: "textOutline") }
    }
    static var width: CGFloat {
        get { let w = d.double(forKey: "width"); return w > 0 ? CGFloat(w) : 4 }
        set { d.set(Double(newValue), forKey: "width") }
    }
}

/// Scroll-view clip view that keeps a document smaller than the viewport centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if doc.frame.width < r.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if doc.frame.height < r.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

private extension NSColor {
    static let mustard = NSColor(srgbRed: 0.84, green: 0.63, blue: 0.08, alpha: 1)
}

private extension NSToolbarItem.Identifier {
    static let tools = NSToolbarItem.Identifier("tools")
    static let style = NSToolbarItem.Identifier("style")
    static let history = NSToolbarItem.Identifier("history")
    static let save = NSToolbarItem.Identifier("save")
    static let dragOut = NSToolbarItem.Identifier("dragOut")
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let canvas: CanvasView
    private let handle = DragHandle()
    private let scroll = NSScrollView()
    private var toolGroup: NSToolbarItemGroup?
    private var historyGroup: NSToolbarItemGroup?
    private let styleButton = NSButton()
    private var stylePopover: NSPopover?
    var onClose: ((DocumentWindowController) -> Void)?
    /// The file this window was opened from or last saved to; ⌘S overwrites it.
    var fileURL: URL?

    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .mustard, .systemGreen, .systemBlue, .systemPurple,
        .black, .white, .systemGray,
    ]
    private static let sizes: [CGFloat] = [2, 4, 8, 16, 32]

    init(image: NSImage, title: String, fileURL: URL? = nil) {
        self.fileURL = fileURL
        canvas = CanvasView(image: image)
        canvas.color = Prefs.color
        canvas.lineWidth = Prefs.width
        canvas.textOutline = Prefs.textOutline
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI(in: window)
        window.initialFirstResponder = canvas
        fitWindow(to: image.size)
        window.center()
        handle.name = title
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI(in window: NSWindow) {
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        window.contentView = scroll

        handle.provider = { [weak self] in self?.canvas.exportData(.png) }
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.toolTip = "Drag the annotated image into another app"
        handle.widthAnchor.constraint(equalToConstant: 36).isActive = true
        handle.heightAnchor.constraint(equalToConstant: 28).isActive = true

        styleButton.bezelStyle = .texturedRounded
        styleButton.imagePosition = .imageOnly
        styleButton.target = self
        styleButton.action = #selector(showStylePopover(_:))
        styleButton.toolTip = "Colour and thickness"

        let toolbar = NSToolbar(identifier: "ZquigToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        canvas.onChange = { [weak self] in self?.refresh(); self?.window?.isDocumentEdited = true }
        canvas.onSelect = { [weak self] a in
            if a != nil { self?.updateStyleButton() }
        }
        canvas.onToolChange = { [weak self] t in self?.toolGroup?.selectedIndex = t.rawValue }
        updateStyleButton()
        refresh()
    }

    private func refresh() {
        let s = canvas.base.size
        window?.subtitle = "\(Int(s.width)) × \(Int(s.height))"
        historyGroup?.subitems.first?.isEnabled = canvas.canUndo
        historyGroup?.subitems.last?.isEnabled = canvas.canRedo
    }

    /// Sizes the window around the image. Images larger than the screen are scaled down to fit
    /// (via scroll-view magnification); smaller ones stay at 100%.
    private func fitWindow(to size: NSSize) {
        guard let screen = NSScreen.main, size.width > 0, size.height > 0, let window = window else { return }
        let maxW = screen.visibleFrame.width * 0.9, maxH = screen.visibleFrame.height * 0.85
        let scale = min(1, (maxW - 40) / size.width, (maxH - 40) / size.height)
        let w = min(max(size.width * scale + 40, 640), maxW), h = min(max(size.height * scale + 40, 400), maxH)
        window.setContentSize(NSSize(width: w, height: h))
        window.layoutIfNeeded()
        // Fit against the real visible area (toolbar and title bar already excluded), never enlarging.
        let view = scroll.contentSize
        let fit = min(1, view.width / size.width, view.height / size.height)
        scroll.magnification = fit
        if let clip = scroll.contentView as? NSClipView {
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Keeps the toolbar's selected tool in step with the canvas (also re-applied once the window is on screen).
    func syncToolSelection() { toolGroup?.selectedIndex = canvas.tool.rawValue }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .style, .flexibleSpace, .history, .save, .dragOut]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .tools:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: Tool.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage() },
                                       selectionMode: .selectOne,
                                       labels: Tool.allCases.map { $0.title },
                                       target: self, action: #selector(toolGroupChanged(_:)))
            for (i, t) in Tool.allCases.enumerated() { g.subitems[i].toolTip = t.title }
            g.selectedIndex = canvas.tool.rawValue
            g.label = "Tools"
            g.paletteLabel = "Tools"
            toolGroup = g
            return g
        case .style:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = styleButton
            item.label = "Style"
            item.paletteLabel = "Style"
            item.toolTip = "Colour and thickness"
            return item
        case .history:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo") ?? NSImage(),
                                                NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo") ?? NSImage()],
                                       selectionMode: .momentary, labels: ["Undo", "Redo"],
                                       target: self, action: #selector(historyAction(_:)))
            g.subitems[0].toolTip = "Undo"
            g.subitems[1].toolTip = "Redo"
            g.label = "History"
            g.paletteLabel = "History"
            historyGroup = g
            refresh()
            return g
        case .save:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
            item.label = "Save"
            item.paletteLabel = "Save"
            item.toolTip = "Save (⌘S)"
            item.target = self
            item.action = #selector(saveDocument(_:))
            return item
        case .dragOut:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = handle
            item.label = "Drag Out"
            item.paletteLabel = "Drag Out"
            item.toolTip = "Drag the annotated image into another app"
            return item
        default:
            return nil
        }
    }

    @objc private func toolGroupChanged(_ g: NSToolbarItemGroup) {
        canvas.tool = Tool(rawValue: g.selectedIndex) ?? .select
        window?.makeFirstResponder(canvas)
    }

    @objc private func historyAction(_ g: NSToolbarItemGroup) {
        if g.selectedIndex == 0 { canvas.undoEdit(nil) } else { canvas.redoEdit(nil) }
        window?.makeFirstResponder(canvas)
    }

    // MARK: Style popover

    private func updateStyleButton() {
        let c = canvas.color
        styleButton.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            c.setFill(); circle.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 1; circle.stroke()
            return true
        }
    }

    @objc private func showStylePopover(_ sender: NSButton) {
        if let p = stylePopover, p.isShown { p.close(); return }
        let pop = NSPopover()
        pop.behavior = .transient
        let vc = NSViewController()
        vc.view = makeStyleView()
        pop.contentViewController = vc
        stylePopover = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func sectionLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func makeStyleView() -> NSView {
        func same(_ a: NSColor, _ b: NSColor) -> Bool { a.usingColorSpace(.sRGB) == b.usingColorSpace(.sRGB) }

        var swatches: [NSButton] = []
        for (i, c) in Self.palette.enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 11
            let on = same(c, canvas.color)
            b.layer?.borderWidth = on ? 3 : 1
            b.layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            b.tag = i
            b.target = self
            b.action = #selector(swatchPicked(_:))
            b.toolTip = ["Red", "Orange", "Mustard", "Green", "Blue", "Purple", "Black", "White", "Gray"][i]
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            swatches.append(b)
        }
        let well = NSColorWell()
        well.color = canvas.color
        well.target = self
        well.action = #selector(customColorPicked(_:))
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let rows = stride(from: 0, to: swatches.count, by: 5).map { i -> NSStackView in
            let r = NSStackView(views: Array(swatches[i..<min(i + 5, swatches.count)]))
            r.spacing = 8
            return r
        }
        let colorStack = NSStackView(views: rows + [well])
        colorStack.orientation = .vertical
        colorStack.alignment = .leading
        colorStack.spacing = 8

        let seg = NSSegmentedControl(images: Self.sizes.map { w in
            NSImage(size: NSSize(width: 26, height: 18), flipped: false) { r in
                NSColor.labelColor.setFill()
                let d = 2 + 2.8 * log2(w)  // log scale keeps the biggest dot inside the 18pt icon
                NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
                return true
            }
        }, trackingMode: .selectOne, target: self, action: #selector(sizePicked(_:)))
        let nearest = Self.sizes.enumerated().min { abs($0.element - canvas.lineWidth) < abs($1.element - canvas.lineWidth) }?.offset ?? 1
        seg.selectedSegment = nearest
        for i in 0..<Self.sizes.count { seg.setWidth(44, forSegment: i) }

        let outline = NSButton(checkboxWithTitle: "Text border & shadow", target: self, action: #selector(outlineToggled(_:)))
        outline.state = canvas.textOutline ? .on : .off

        let root = NSStackView(views: [sectionLabel("COLOUR"), colorStack, sectionLabel("THICKNESS"), seg, sectionLabel("TEXT"), outline])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.setCustomSpacing(14, after: colorStack)
        root.setCustomSpacing(14, after: seg)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return root
    }

    @objc private func swatchPicked(_ b: NSButton) {
        applyColor(Self.palette[b.tag])
        stylePopover?.close()
    }

    @objc private func customColorPicked(_ w: NSColorWell) { applyColor(w.color) }

    private func applyColor(_ c: NSColor) {
        canvas.applyColor(c)
        Prefs.color = c
        updateStyleButton()
    }

    @objc private func outlineToggled(_ b: NSButton) {
        let on = b.state == .on
        canvas.applyOutline(on)
        canvas.endStyleChange()
        Prefs.textOutline = on
    }

    @objc private func sizePicked(_ s: NSSegmentedControl) {
        let w = Self.sizes[s.selectedSegment]
        canvas.applyWidth(w)
        canvas.endStyleChange()
        Prefs.width = w
    }

    func windowWillClose(_ notification: Notification) { onClose?(self) }

    /// Closing (red button or ⌘W) with unsaved edits asks first; a clean window closes silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.isDocumentEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(sender.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self = self, let sender = sender else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save { saved in if saved { sender.close() } }
            case .alertThirdButtonReturn:
                sender.isDocumentEdited = false
                sender.close()
            default: break
            }
        }
        return false
    }

    // MARK: Saving

    /// ⌘S: overwrite the original file. Windows with no file yet (captures, clipboard) and PDFs
    /// (a multi-page PDF can't be rewritten from one flattened image) fall back to Save As.
    @objc func saveDocument(_ sender: Any?) { save(completion: nil) }

    private func save(completion: ((Bool) -> Void)?) {
        guard let url = fileURL, url.pathExtension.lowercased() != "pdf" else { return saveAs(completion: completion) }
        let ok = write(to: url)
        if ok { window?.isDocumentEdited = false }
        completion?(ok)
    }

    @objc func saveDocumentAs(_ sender: Any?) { saveAs(completion: nil) }

    private func saveAs(completion: ((Bool) -> Void)?) {
        guard let window = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf]
        panel.nameFieldStringValue = window.title.replacingOccurrences(of: "/", with: "-") + ".png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self = self else { completion?(false); return }
            let ok = self.write(to: url)
            if ok {
                self.fileURL = url
                window.title = url.deletingPathExtension().lastPathComponent
                self.handle.name = window.title
                window.isDocumentEdited = false
            }
            completion?(ok)
        }
    }

    @objc func exportImage(_ sender: Any?) { saveDocumentAs(sender) }

    @discardableResult
    private func write(to url: URL) -> Bool {
        let data: Data?
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": data = canvas.exportData(.jpeg)
        case "tif", "tiff": data = canvas.exportData(.tiff)
        case "pdf":
            let doc = PDFDocument()
            if let page = PDFPage(image: canvas.flattened()) { doc.insert(page, at: 0) }
            data = doc.dataRepresentation()
        default: data = canvas.exportData(.png)
        }
        do {
            guard let data = data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc func copyImage(_ sender: Any?) { canvas.copyToPasteboard() }
}
