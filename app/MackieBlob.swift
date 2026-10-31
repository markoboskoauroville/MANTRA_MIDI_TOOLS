// MIDI TO MK CONTROL, part 4: THE COMMAND BLOB, the toast (was MANTRA_MACKIE/blob.lua). Marko, 21.9.2026: "it just
// displays the name of the command while it's activated ... MIDI message ... and then two pipes, and then command
// name." One line at the top of Live's screen (A1's clock owns the bottom), "CC 13  ||  JOG WHEEL". Dragged anywhere,
// its corner pulled to make the letters bigger, the ✕ turns it off. Where it sits and how big are kept in the settings
// file in the Lua's own coordinates (top-left of the main screen, y downwards), so both versions agree.
import AppKit

final class MKBlobView: NSView {
    weak var blob: MKBlob?
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.x > bounds.width - 26 && p.y > bounds.height - 24 { blob?.closed?(); return }     // the ✕, top right
        blob?.press(at: NSEvent.mouseLocation, grip: p.x > bounds.width - 22 && p.y < 22)        // the grip, bottom right
    }
    override func mouseDragged(with e: NSEvent) { blob?.drag(to: NSEvent.mouseLocation) }
    override func mouseUp(with e: NSEvent) { blob?.release() }
}

final class MKBlob {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 46), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    let view = MKBlobView()
    let label = NSTextField(labelWithString: "")
    let close = NSTextField(labelWithString: "\u{2715}")
    let grip = NSTextField(labelWithString: "\u{25E2}")
    var size: CGFloat
    var hide: DispatchWorkItem?
    var moved: ((CGFloat?, CGFloat?) -> Void)?
    var resized: ((CGFloat) -> Void)?
    var closed: (() -> Void)?
    var screen: () -> NSRect           // Live's screen, visible frame, Cocoa coordinates
    var start: (mouse: NSPoint, frame: NSRect, grip: Bool)?
    let PAD_X: CGFloat = 22, PAD_Y: CGFloat = 10

    init(size: CGFloat, pos: (x: CGFloat, y: CGFloat)?, screen: @escaping () -> NSRect) {
        self.size = size; self.screen = screen
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        view.blob = self; view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor; view.layer?.cornerRadius = 12
        label.font = NSFont(name: "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        label.textColor = .white; label.alignment = .center
        for t in [close, grip] { t.font = NSFont(name: "Menlo", size: 12); t.textColor = NSColor(white: 1, alpha: 0.45); view.addSubview(t) }
        view.addSubview(label)
        panel.contentView = view
        fit()
        if let p = pos, let f = MKBlob.fromLua(p.x, p.y, panel.frame.size), NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }) {
            panel.setFrameOrigin(f.origin)
        } else { home() }
    }
    // the Lua's coordinates: top-left origin on the main screen, y downwards
    static func fromLua(_ x: CGFloat, _ y: CGFloat, _ s: NSSize) -> NSRect? {
        guard let h = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: x, y: h - y - s.height, width: s.width, height: s.height)
    }
    static func toLua(_ f: NSRect) -> (CGFloat, CGFloat) {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return (f.minX, h - f.maxY)
    }
    func fit() {
        label.font = NSFont(name: "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        label.sizeToFit()
        let w = max(220, ceil(label.frame.width) + 2 * PAD_X), h = max(40, ceil(label.frame.height) + 2 * PAD_Y)
        var f = panel.frame
        if f.width != w || f.height != h { f.origin.y += f.height - h; f.size = NSSize(width: w, height: h); panel.setFrame(f, display: true) }
        label.frame = NSRect(x: PAD_X / 2, y: (h - label.frame.height) / 2, width: w - PAD_X, height: label.frame.height)
        close.frame = NSRect(x: w - 22, y: h - 22, width: 18, height: 18)
        grip.frame = NSRect(x: w - 18, y: 3, width: 14, height: 16)
    }
    func home() {
        let s = screen()
        panel.setFrameOrigin(NSPoint(x: s.midX - panel.frame.width / 2, y: s.maxY - 28 - panel.frame.height))
    }
    func say(_ text: String, seconds: Double) {
        if text != label.stringValue { label.stringValue = text; fit() }
        if !panel.isVisible { panel.orderFrontRegardless() }
        hide?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hide = job
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: job)
    }
    func hideNow() { hide?.cancel(); panel.orderOut(nil) }
    func press(at m: NSPoint, grip g: Bool) { start = (m, panel.frame, g) }
    func drag(to m: NSPoint) {
        guard let s = start else { return }
        if s.grip {
            let h = max(28, s.frame.maxY - m.y)
            let ns = max(10, min(120, floor((h - 2 * PAD_Y) / 1.35)))
            if ns != size { size = ns; fit() }
        } else {
            panel.setFrameOrigin(NSPoint(x: s.frame.minX + m.x - s.mouse.x, y: s.frame.minY + m.y - s.mouse.y))
        }
    }
    func release() {
        guard let s = start else { return }
        start = nil
        if s.grip { resized?(size) } else { let p = MKBlob.toLua(panel.frame); moved?(p.0, p.1) }
    }
    func delete() { hideNow(); panel.close() }
    static func line(_ from: String, _ command: String) -> String { "\(from)  ||  \(command)" }
}
