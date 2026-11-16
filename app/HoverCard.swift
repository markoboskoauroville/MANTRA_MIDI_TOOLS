// HoverCard.swift (kit menubar-hover). Marko, 16.11.2026: "with all my apps on the menu bar, make a comprehensive pop-up menu.
// When I hover over, I want to see what is it and what is it doing." and: "for my apps always make a pipes before and after so I
// know where one app ends and other begins."
// One module everywhere: copy this file into the app's Swift sources, change nothing in it. The app supplies a provider.
//
//   HoverCard.attach(to: statusItem, provider: { HoverCard.Content(
//       name: "Talk Mode (Mantra)", what: "Talk to Claude with the Space bar",
//       state: "LISTENING", stateColor: .systemGreen,
//       lines: ["Space Bar Mode: on", "Draft: 120 characters"]) })
//
// Hover ~0.4 s over the item: a small non-activating panel under it (never takes focus). The mouse leaves: it goes. A click is
// untouched (the item's own menu or action). Pipes: a thin grey "|" before and after the item's visible title:
//   statusItem.button?.attributedTitle = HoverCard.piped("GROQ EN · 0.8 s")      // text items
//   HoverCard.drawPipes(in: bounds)                                                // first and last call in a view item's draw(_:)
//   wantedWidth += HoverCard.pipeInset * 2                                         // and keep the words inside the inset
// Debug (no real mouse needed): launch with --hovercard-shot, the card shows under the item 1.5 s after launch and stays.
import AppKit

enum HoverCard {
    struct Content {
        var name: String            // name first, (Mantra) last
        var what: String            // one line: what it is
        var state: String           // one or two words, talk-states.md colours where they apply
        var stateColor: NSColor = .white
        var lines: [String] = []    // 2-4 live lines: what it is doing now
    }

    static let pipeInset: CGFloat = 5          // padding between pipe and words
    static let pipeColor = NSColor(white: 0.62, alpha: 0.7)   // grey like the grip rule
    static var debugShot: Bool { CommandLine.arguments.contains("--hovercard-shot") }

    // Pipes -----------------------------------------------------------------
    /// "│ words │" as an attributed title: pipes grey, words in `color`.
    static func piped(_ words: String, color: NSColor = .labelColor,
                      font: NSFont = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)) -> NSAttributedString {
        let pipe: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .ultraLight), .foregroundColor: pipeColor]
        let s = NSMutableAttributedString(string: "\u{2502} ", attributes: pipe)
        s.append(NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color]))
        s.append(NSAttributedString(string: " \u{2502}", attributes: pipe))
        return s
    }
    /// Right pipe only, for items whose icon carries the left pipe (pipedIcon): attributedTitle = rightPipe() (+ words before it).
    static func rightPipe() -> NSAttributedString {
        NSAttributedString(string: " \u{2502}", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .ultraLight), .foregroundColor: pipeColor])
    }
    /// An icon with a thin grey pipe drawn at its left edge (the item then ends with rightPipe()). Template stays template.
    static func pipedIcon(_ img: NSImage?) -> NSImage? {
        guard let img else { return nil }
        let pad: CGFloat = 5, h = max(img.size.height, 16)
        let out = NSImage(size: NSSize(width: img.size.width + pad, height: h), flipped: false) { r in
            (img.isTemplate ? NSColor(white: 0, alpha: 0.5) : pipeColor).setFill()
            NSRect(x: 0, y: (r.height - 14) / 2, width: 1, height: 14).fill()
            img.draw(in: NSRect(x: pad, y: (r.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
            return true
        }
        out.isTemplate = img.isTemplate
        return out
    }
    /// For a view item: ~1 pt wide, ~14 pt tall pipes at both edges (unflipped or flipped view alike).
    static func drawPipes(in b: NSRect) {
        pipeColor.setFill()
        let h: CGFloat = 14, y = b.midY - h / 2
        NSRect(x: b.minX, y: y, width: 1, height: h).fill()
        NSRect(x: b.maxX - 1, y: y, width: 1, height: h).fill()
    }

    /// A view that draws only the two pipes: add it first to a button whose content is another view; place the content inside pipeInset+2.
    final class PipesView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ p: NSPoint) -> NSView? { nil }
        override func draw(_ r: NSRect) { HoverCard.drawPipes(in: bounds) }
    }

    // The card --------------------------------------------------------------
    private static var cards: [ObjectIdentifier: Controller] = [:]

    static func attach(to item: NSStatusItem, autoPipe: Bool = false, provider: @escaping () -> Content) {
        guard let button = item.button else { return }
        let c = Controller(button: button, provider: provider)
        c.autoPipe = autoPipe
        cards[ObjectIdentifier(item)] = c
        c.install()
        if autoPipe { c.wrapTitle() }
        if debugShot { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { c.show() } }   // shows beside the item's own window
    }

    private final class Controller: NSObject {
        let button: NSStatusBarButton, provider: () -> Content
        var panel: NSPanel?, poll: Timer?, refresh: Timer?
        var hovering = false, enteredAt = Date(), autoPipe = false
        init(button: NSStatusBarButton, provider: @escaping () -> Content) { self.button = button; self.provider = provider }

        /// Polled, not tracked: with several displays macOS draws the item once per menu bar, and only one copy owns the button.
        /// The mouse is matched against the button's window and against this app's other status-bar windows of the same width.
        func install() {
            let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common); poll = t
        }
        func itemRect(at m: NSPoint) -> NSRect? {
            guard let win = button.window else { return nil }
            let own = button.convert(button.bounds, to: nil), f = win.convertToScreen(own)
            if f.insetBy(dx: 0, dy: -1).contains(m) { return f }
            let H = NSScreen.screens.first?.frame.height ?? 0
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == getpid() && (w[kCGWindowLayer as String] as? Int) == 25 {
                guard let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d) else { continue }
                let c = NSRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
                if abs(c.width - win.frame.width) < 1.5, c.contains(m) {
                    return NSRect(x: c.minX + (f.minX - win.frame.minX), y: c.minY, width: f.width, height: c.height)
                }
            }
            return nil
        }
        /// autoPipe: text items whose app sets button.title / attributedTitle in many places get the grey pipes wrapped around
        /// whatever the title is (checked at every tick, so a changed title is re-wrapped within 0.12 s).
        func wrapTitle() {
            let a = button.attributedTitle
            guard a.length > 0, !a.string.contains("\u{2502}") else { return }
            let m = NSMutableAttributedString(string: "\u{2502} ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .ultraLight), .foregroundColor: HoverCard.pipeColor])
            m.append(a); m.append(HoverCard.rightPipe())
            button.attributedTitle = m
        }
        func tick() {
            if autoPipe { wrapTitle() }
            let m = NSEvent.mouseLocation
            guard let scr = NSScreen.screens.first(where: { $0.frame.contains(m) }), m.y > scr.frame.maxY - 40,
                  let rect = itemRect(at: m) else {
                if hovering { hovering = false; if !HoverCard.debugShot { hide() } }
                return
            }
            if !hovering { hovering = true; enteredAt = Date() }
            if panel == nil, Date().timeIntervalSince(enteredAt) >= 0.4 { show(at: rect) }
        }

        func hide() { refresh?.invalidate(); panel?.orderOut(nil); panel = nil }

        func show() { if let win = button.window { show(at: win.convertToScreen(button.convert(button.bounds, to: nil))) } }
        func show(at bf: NSRect) {
            let view = CardView(provider())
            let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.titleVisibility = .hidden; p.isFloatingPanel = true; p.level = .statusBar + 1; p.hidesOnDeactivate = false
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = true; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.contentView = view
            let size = view.cardSize
            var x = bf.midX - size.width / 2
            if let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: bf.midX, y: bf.midY)) }) {
                x = min(max(x, scr.frame.minX + 6), scr.frame.maxX - size.width - 6)
            }
            p.setFrame(NSRect(x: x, y: bf.minY - size.height - 4, width: size.width, height: size.height), display: true)
            p.orderFrontRegardless()
            panel = p
            refresh?.invalidate()
            refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let p = self.panel else { return }
                let v = CardView(self.provider()); p.contentView = v
                let s = v.cardSize; var f = p.frame; f.origin.y += f.height - s.height; f.size = s; p.setFrame(f, display: true)
            }
        }
    }

    private final class CardView: NSView {
        override var isFlipped: Bool { true }
        let rows: [(String, NSFont, NSColor)]
        let content: Content
        static let mono = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        init(_ c: Content) {
            content = c
            var r: [(String, NSFont, NSColor)] = [(c.name, .systemFont(ofSize: 12, weight: .semibold), .white),
                                                  (c.what, .systemFont(ofSize: 10.5), NSColor(white: 1, alpha: 0.7)),
                                                  (c.state, CardView.mono, c.stateColor)]
            for l in c.lines.prefix(4) { r.append((l, CardView.mono, NSColor(white: 1, alpha: 0.85))) }
            rows = r
            super.init(frame: .zero)
            frame.size = cardSize
        }
        required init?(coder: NSCoder) { fatalError() }
        var cardSize: NSSize {
            let w = rows.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).width }.max() ?? 80
            let h = rows.reduce(CGFloat(20)) { $0 + ($1.0 as NSString).size(withAttributes: [.font: $1.1]).height + 3 }
            return NSSize(width: ceil(min(max(w, 140), 340)) + 28, height: ceil(h) + 2)
        }
        override func draw(_ r: NSRect) {
            NSColor(white: 0.08, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            HoverCard.pipeColor.setStroke()
            let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); b.lineWidth = 0.5; b.stroke()
            var y: CGFloat = 10
            for (i, row) in rows.enumerated() {
                let s = row.0 as NSString
                let rect = NSRect(x: 14, y: y, width: bounds.width - 28, height: 40)
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                s.draw(with: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 20), options: [.usesLineFragmentOrigin],
                       attributes: [.font: row.1, .foregroundColor: row.2, .paragraphStyle: para])
                y += s.size(withAttributes: [.font: row.1]).height + 3
                if i == 1 { y += 2 }
            }
        }
    }
}
