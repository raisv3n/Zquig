import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [DocumentWindowController] = []
    private var counter = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        if windows.isEmpty { newFromClipboardOrBlank() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newFromClipboardOrBlank() }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { open(url: URL(fileURLWithPath: $0)) }
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: Windows

    private func present(_ image: NSImage, title: String, fileURL: URL? = nil) {
        let wc = DocumentWindowController(image: image, title: title, fileURL: fileURL)
        wc.onClose = { [weak self] c in self?.windows.removeAll { $0 === c } }
        windows.append(wc)
        wc.showWindow(nil)
        DispatchQueue.main.async { wc.syncToolSelection() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func nextTitle() -> String { counter += 1; return "Snap \(counter)" }

    private var activeController: DocumentWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last
    }

    // MARK: Opening

    func open(url: URL) {
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            if pdf.isEncrypted && pdf.isLocked {
                let a = NSAlert(); a.messageText = "Cannot open encrypted PDF"; a.runModal(); return
            }
            if let img = Self.render(pdf: pdf) { present(img, title: url.deletingPathExtension().lastPathComponent) }
        } else if let img = NSImage(contentsOf: url) {
            present(img, title: url.deletingPathExtension().lastPathComponent, fileURL: url)
        } else {
            let a = NSAlert(); a.messageText = "Cannot open \(url.lastPathComponent)"; a.runModal()
        }
    }

    /// Stacks up to 50 pages vertically into a single image.
    static func render(pdf: PDFDocument) -> NSImage? {
        let scale: CGFloat = 2
        let pages = (0..<min(pdf.pageCount, 50)).compactMap { pdf.page(at: $0) }
        guard !pages.isEmpty else { return nil }
        let sizes = pages.map { $0.bounds(for: .mediaBox).size }
        let width = sizes.map(\.width).max() ?? 0
        let gap: CGFloat = 12
        let height = sizes.map(\.height).reduce(0, +) + gap * CGFloat(pages.count - 1)
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = height
        for (p, s) in zip(pages, sizes) {
            top -= s.height
            let thumb = p.thumbnail(of: NSSize(width: s.width * scale, height: s.height * scale), for: .mediaBox)
            thumb.draw(in: NSRect(x: (width - s.width) / 2, y: top, width: s.width, height: s.height))
            top -= gap
        }
        img.unlockFocus()
        return img
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open(url:))
    }

    @objc func newFromClipboardOrBlank() {
        if let img = NSImage(pasteboard: .general) {
            present(img, title: nextTitle())
        } else {
            let size = NSSize(width: 800, height: 500)
            let blank = NSImage(size: size)
            blank.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill(); blank.unlockFocus()
            present(blank, title: nextTitle())
        }
    }

    // MARK: Capture (uses the system screencapture tool; everything stays local)

    @objc func captureRegion(_ s: Any?) { capture(args: ["-i"]) }
    @objc func captureWindow(_ s: Any?) { capture(args: ["-i", "-w"]) }
    @objc func captureScreen(_ s: Any?) { capture(args: [], delay: true) }

    private func capture(args: [String], delay: Bool = false) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zquig-\(UUID().uuidString).png")
        let hidden = windows.compactMap { $0.window }.filter { $0.isVisible }
        hidden.forEach { $0.orderOut(nil) }
        DispatchQueue.global().async {
            if delay { Thread.sleep(forTimeInterval: 0.4) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x"] + args + [file.path]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                hidden.forEach { $0.orderFront(nil) }
                if let img = NSImage(contentsOf: file) {
                    self.present(img, title: self.nextTitle())
                }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func mi(_ t: String, _ a: Selector?, _ k: String = "", _ m: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = m
            i.target = target
            return i
        }
        let name = "Zquig"
        add(name, [
            mi("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            mi("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            mi("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let opt: NSEvent.ModifierFlags = [.command, .option]
        add("File", [
            mi("New from Clipboard", #selector(newFromClipboardOrBlank), "n", target: self),
            mi("Capture Region", #selector(captureRegion(_:)), "r", opt, target: self),
            mi("Capture Window", #selector(captureWindow(_:)), "w", opt, target: self),
            mi("Capture Full Screen", #selector(captureScreen(_:)), "f", opt, target: self),
            .separator(),
            mi("Open…", #selector(openDocument(_:)), "o", target: self),
            mi("Save", #selector(DocumentWindowController.saveDocument(_:)), "s"),
            mi("Save As…", #selector(DocumentWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            .separator(),
            mi("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        add("Edit", [
            mi("Undo", #selector(CanvasView.undoEdit(_:)), "z"),
            mi("Redo", #selector(CanvasView.redoEdit(_:)), "z", [.command, .shift]),
            .separator(),
            mi("Cut", #selector(NSText.cut(_:)), "x"),
            mi("Copy", #selector(NSText.copy(_:)), "c"),
            mi("Paste", #selector(NSText.paste(_:)), "v"),
            mi("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            mi("Copy Whole Image", #selector(DocumentWindowController.copyImage(_:)), "c", [.command, .shift]),
            mi("Delete Annotation", #selector(CanvasView.deleteSelection(_:)), "\u{8}", []),
        ])
        add("Window", [
            mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            mi("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
