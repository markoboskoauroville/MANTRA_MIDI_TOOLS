// MIDI TO KEY STROKE, the module (Marko, 20.9.2026: "First column of the table is CC ... second column is a value,
// and third column is a key on the keyboard ... add a special case system volume"). The engine is MidiKeysEngine.swift;
// this is its place in Mantra MIDI Tools: on/off, the menu rows, and the section of the window, which is what the
// page at :8853 and the separate "MIDI to Key Stroke" window were (MANTRA_CONTROLS), now one face, no server.
// `--midikeys-dry` opens the section in a window of its own with the engine listening and pressing nothing (a test).
import SwiftUI
import AppKit

final class MidiKeysModule: NSObject, LiveModule {
    let id = "midikeys"
    let title = "MIDI TO KEY STROKE"
    let about = "A knob's CC or a key's note becomes a key stroke in the front app, or the Mac's own volume"
    let defaultOn = true
    let engine = KSEngine()
    private var dryWindow: NSWindow?

    override init() {
        super.init()
        if CommandLine.arguments.contains("--midikeys-dry") {
            engine.dry = true
            DispatchQueue.main.async { self.openDry() }
        }
    }
    private func openDry() {
        engine.start()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "MIDI to Key Stroke (dry: listens, presses nothing)"
        w.contentView = NSHostingView(rootView: VStack(spacing: 0) { HStack { Spacer(); CloseX() }.padding(.trailing, 10).padding(.top, 6); ScrollView { KSSection(e: engine).padding(20) } }.background(INK).preferredColorScheme(.dark))
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        dryWindow = w
    }

    // MIDI to Key Stroke works in any front app, not only Live: it runs whenever the module is on
    func setOn(_ on: Bool) { if engine.dry { return }; if on { engine.start() } else { engine.stop() } }
    func liveCame() {}
    func liveLeft() {}
    func hotkeys() -> [(Chord, () -> Void)] { [] }

    func menuItems() -> [NSMenuItem] {
        let p = NSMenuItem(title: engine.on ? "  Stop sending keys" : "  Send keys", action: #selector(menuPower), keyEquivalent: ""); p.target = self
        let d = NSMenuItem(title: engine.device.isEmpty ? "  No device locked" : "  Locked to " + engine.label(engine.device), action: nil, keyEquivalent: ""); d.isEnabled = false
        let n = NSMenuItem(title: "  \(engine.rows.count) row\(engine.rows.count == 1 ? "" : "s") in the table", action: nil, keyEquivalent: ""); n.isEnabled = false
        return [p, d, n]
    }
    @objc func menuPower() { engine.power() }
    func settingsView() -> AnyView { AnyView(KSSection(e: engine)) }
    func status() -> String {
        if !engine.running { return "OFF" }
        if !engine.on { return "STOPPED" }
        return engine.device.isEmpty ? "NO DEVICE" : "LISTENING"
    }
}

// MARK: the look (the pages' own colours: ground, surface, slate, amber, sand)

enum KSInk {
    static func c(_ h: UInt32) -> Color { Color(red: Double((h >> 16) & 255) / 255, green: Double((h >> 8) & 255) / 255, blue: Double(h & 255) / 255) }
    static let ground = c(0x0B0D10), surface = c(0x141A21), slate = c(0x23303D), slateHi = c(0x2C3B4B)
    static let amber = c(0xF59E0B), sand = c(0xF2DDB4), dim = c(0xF2DDB4).opacity(0.45), red = c(0xEF4444), green = c(0x34D399)
    static let mono = Font.system(size: 12, design: .monospaced), monoB = Font.system(size: 12, weight: .semibold, design: .monospaced)
}

struct KSBand<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundColor(KSInk.dim)
            content
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .background(KSInk.surface).cornerRadius(12)
    }
}

struct KSPill: View {
    enum Look { case plain, lit, ghost, danger }
    let title: String; var look: Look = .plain; var width: CGFloat? = nil; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(KSInk.monoB).lineLimit(1)
                .foregroundColor(look == .lit ? .black : (look == .danger ? KSInk.red : KSInk.sand))
                .padding(.horizontal, 12).padding(.vertical, 7).frame(width: width)
                .background(look == .lit ? KSInk.amber : (look == .plain ? KSInk.slate : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(look == .ghost ? KSInk.slate : (look == .danger ? KSInk.red.opacity(0.6) : Color.clear), lineWidth: 1))
                .cornerRadius(8)
        }.buttonStyle(.plain)
    }
}

struct KSTick: View {
    let on: Bool; var dead = false; var tint: Color = KSInk.amber; let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5).fill(on ? tint : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? tint : KSInk.slateHi, lineWidth: 1.5))
                .overlay(Text(on ? "\u{2713}" : "").font(.system(size: 12, weight: .bold)).foregroundColor(.black))
                .frame(width: 22, height: 22).opacity(dead ? 0.25 : 1).contentShape(Rectangle())   // the whole square takes the click
        }.buttonStyle(.plain).disabled(dead)
    }
}

// a box sent on Return or on leaving it; the live state does not overwrite it while he types
struct KSField: View {
    let value: String; var width: CGFloat = 70; var disabled = false; var lit = false; let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text).textFieldStyle(.plain).font(KSInk.mono).foregroundColor(KSInk.sand)
            .padding(.horizontal, 8).padding(.vertical, 6).frame(width: width)
            .background(KSInk.ground).cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(lit || focused ? KSInk.amber : KSInk.slate, lineWidth: 1))
            .focused($focused).disabled(disabled).opacity(disabled ? 0.4 : 1)
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: focused) { _, f in if !f && text != value { commit(text) } }
            .onSubmit { if text != value { commit(text) } }
    }
}

// MARK: the section

struct KSSection: View {
    @ObservedObject var e: KSEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                KSMonitor(e: e)
                Spacer()
                KSPill(title: e.on ? "ON" : "OFF", look: e.on ? .lit : .danger, width: 70) { e.power() }
                    .help(e.on ? "sending: press to stop everything, the table is kept" : "stopped: press to send again")
            }
            if !e.trusted && !e.dry {
                Text("Accessibility: not allowed yet. System Settings \u{2192} Privacy & Security \u{2192} Accessibility \u{2192} Mantra MIDI Tools on. Until then no key is pressed and no key can be captured.")
                    .font(.system(size: 11)).foregroundColor(AMBER).fixedSize(horizontal: false, vertical: true)
            }
            KSDeviceBand(e: e)
            KSTableBand(e: e)
            KSTraceBand(e: e)
        }
    }
}

// THE INCOMING MIDI MONITOR: every message on every port, newest first, always four lines high
struct KSMonitor: View {
    @ObservedObject var e: KSEngine
    var body: some View {
        let _ = e.tick
        VStack(alignment: .leading, spacing: 2) {
            if !e.running { line("not running, so not listening", "", 1, "", false) }
            else if e.incoming.isEmpty { line("no MIDI yet \u{2014} listening on " + (e.listening.isEmpty ? "no port at all" : e.listening.joined(separator: ", ")), "", 1, "", false) }
            else {
                ForEach(Array(e.incoming.enumerated()), id: \.offset) { i, m in
                    let ago = KSEngine.ago(m.at)
                    line(m.text, m.port, m.count, ago, i == 0 && ago == "just now")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 4 * 17, alignment: .top).help("every MIDI message arriving on every port, newest first")
    }
    @ViewBuilder func line(_ text: String, _ port: String, _ count: Int, _ ago: String, _ fresh: Bool) -> some View {
        HStack(spacing: 0) {
            Circle().fill(fresh ? KSInk.amber : Color.clear).frame(width: 7, height: 7).padding(.trailing, 7)
            if !port.isEmpty { Text(port).frame(width: 150, alignment: .leading) }
            Text(text).frame(minWidth: port.isEmpty ? 0 : 170, alignment: .leading)
            if count > 1 { Text("\u{00D7}\(count)").foregroundColor(KSInk.amber).padding(.trailing, 12) }
            Text(ago)
        }.font(KSInk.mono).foregroundColor(fresh ? KSInk.sand : KSInk.dim).lineLimit(1).frame(height: 15)
    }
}

// THE DEVICE: DETECT locks the controller that speaks first
struct KSDeviceBand: View {
    @ObservedObject var e: KSEngine
    var body: some View {
        let _ = e.tick
        KSBand(title: "THE DEVICE \u{2014} WHAT COMES IN") {
            HStack(spacing: 10) {
                KSPill(title: e.detect ? "TURN OR PRESS SOMETHING\u{2026}" : "DETECT DEVICE", look: e.detect ? .lit : .plain) { e.toggleDetect() }
                KSPill(title: "UNLOCK", look: .ghost) { e.unlock() }
                Text(e.device.isEmpty ? "no device locked" : "locked to " + e.label(e.device)).font(KSInk.mono).foregroundColor(e.device.isEmpty ? KSInk.dim : KSInk.sand)
            }
            if let h = e.heard {
                HStack(spacing: 8) {
                    Circle().fill(h.mine ? KSInk.green : KSInk.dim).frame(width: 8, height: 8)
                    Text(h.line).font(KSInk.mono).foregroundColor(KSInk.sand)
                    Text(KSEngine.ago(h.at)).font(KSInk.mono).foregroundColor(KSInk.dim)
                }
            } else { Text("nothing heard yet").font(KSInk.mono).foregroundColor(KSInk.dim) }
            Text(e.why.0).font(KSInk.mono).foregroundColor(e.why.1 ? KSInk.red : KSInk.dim)
        }
    }
}

// THE TABLE: FILTER, VALUE, KEY, WHAT IT IS, ON, LED, LEARN, the tick; UNDO, REDO, DELETE above it
struct KSTableBand: View {
    @ObservedObject var e: KSEngine
    static let w: [CGFloat] = [150, 70, 230, 170, 34, 60, 130, 30]
    var body: some View {
        KSBand(title: "THE TABLE") {
            KSKeepBar(e: e)
            HStack(spacing: 8) {
                Color.clear.frame(width: 12, height: 1)
                ForEach(Array(["FILTER", "VALUE", "KEY", "WHAT IT IS", "ON", "LED", "LEARN"].enumerated()), id: \.offset) { i, h in
                    Text(h).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundColor(KSInk.dim).frame(width: KSTableBand.w[i], alignment: .leading)
                }
                KSTick(on: !e.rows.isEmpty && e.keep.ticked().count == e.rows.count, tint: KSInk.sand) { e.keep.all(); e.objectWillChange.send() }
                    .frame(width: KSTableBand.w[7]).help("tick every row, or none")
            }
            if e.rows.isEmpty {
                Text("No rows yet. Press + A ROW, then LEARN to catch the knob or the key, then the KEY cell and the key you want.").font(KSInk.mono).foregroundColor(KSInk.dim)
            }
            ForEach(e.rows, id: \.id) { r in KSRowView(e: e, r: r) }
            HStack {
                KSPill(title: "+ A ROW") { e.add() }
                Text("FILTER is CC (a knob) or NOTE (a key or pad): LEARN takes only that kind. For a note, VALUE is the velocity. Press the KEY cell, then the key.")
                    .font(KSInk.mono).foregroundColor(KSInk.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct KSKeepBar: View {
    @ObservedObject var e: KSEngine
    var body: some View {
        let k = e.keep, n = k.ticked().count
        HStack(spacing: 10) {
            KSPill(title: "UNDO") { e.undoRedo(true) }.opacity(k.canUndo ? 1 : 0.4).disabled(!k.canUndo)
                .help(k.canUndo ? "undo: " + k.undoWhat : "nothing to undo")
            KSPill(title: "REDO") { e.undoRedo(false) }.opacity(k.canRedo ? 1 : 0.4).disabled(!k.canRedo)
                .help(k.canRedo ? "redo: " + k.redoWhat : "nothing to redo")
            Text(k.canUndo ? "last change: " + k.undoWhat : "").font(.system(size: 11, design: .monospaced)).foregroundColor(KSInk.dim).lineLimit(1)
            Spacer()
            KSPill(title: n == 0 ? "DELETE" : "DELETE \(n) " + (n == 1 ? "ROW" : "ROWS"), look: n == 0 ? .ghost : .danger) { e.deleteTicked() }
                .opacity(n == 0 ? 0.4 : 1).disabled(n == 0).help(n == 0 ? "tick rows in the last column first" : "delete the ticked rows (UNDO brings them back)")
        }
    }
}

struct KSRowView: View {
    @ObservedObject var e: KSEngine
    let r: KSRow
    @State private var palette = false
    var body: some View {
        let w = KSTableBand.w
        let learning = e.learnId == r.id, capturing = e.capId == r.id
        let sweep = KSRules.SPECIALS[r.kind]?.sweep == true
        let typ = KSRules.type(r.type)
        let about = e.e16.about(typ, r.cc, r.kind == "volume")
        let how = e.lit[r.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let c: Color = how == "fire" ? KSInk.green : (how == "heard" ? KSInk.amber : KSInk.slate)
                Circle().fill(c).frame(width: 10, height: 10).shadow(color: how == nil ? .clear : c, radius: 4).frame(width: 12)
                    .help("lights while your hand moves this row on the controller: green = it fired, amber = heard, nothing sent")
                HStack(spacing: 4) {
                    Menu { Button("CC") { e.set(r.id, "type", "cc") }; Button("NOTE") { e.set(r.id, "type", "note") } } label: {
                        Text(typ == "note" ? "NOTE" : "CC").font(KSInk.mono).foregroundColor(KSInk.sand)
                    }.menuStyle(.borderlessButton).menuIndicator(.visible).padding(.horizontal, 6).padding(.vertical, 5)
                     .frame(width: 72, alignment: .leading).background(KSInk.slate).cornerRadius(7).help("LEARN takes only this kind of message")
                    KSField(value: "\(r.cc)", width: 70, lit: learning) { e.set(r.id, "number", $0) }
                }.frame(width: w[0], alignment: .leading)
                KSField(value: KSRules.valueText(r), width: w[1], disabled: sweep) { e.set(r.id, "value", $0) }
                HStack(spacing: 4) {
                    let t = KSRules.target(r)
                    KSPill(title: capturing ? "press a key\u{2026}" : (sweep ? "\u{2014}" : (t.isEmpty ? "press to set" : t)),
                           look: capturing ? .lit : .plain, width: r.key == nil || sweep ? w[2] : w[2] - 34) { if !sweep { e.capture(r.id) } }.disabled(sweep)
                    if r.key != nil && !sweep { KSPill(title: "\u{00D7}", look: .ghost, width: 30) { e.set(r.id, "key", "") }.help("forget this key") }
                }.frame(width: w[2], alignment: .leading)
                HStack(spacing: 4) {
                    KSPill(title: "KEY", look: r.kind == "key" ? .lit : .ghost) { e.set(r.id, "kind", "key") }
                    KSPill(title: "VOLUME", look: r.kind == "volume" ? .lit : .ghost) { e.set(r.id, "kind", "volume") }
                }.frame(width: w[3], alignment: .leading)
                KSTick(on: r.on) { e.set(r.id, "on", !r.on) }.frame(width: w[4])
                HStack(spacing: 6) {
                    KSTick(on: r.led && about.can, dead: !about.can, tint: about.colour.map(KSInk.c) ?? KSInk.amber) { e.set(r.id, "led", !r.led) }.help(about.says)
                    Button { if !about.knob.isEmpty { palette = true } } label: {
                        RoundedRectangle(cornerRadius: 4).fill(about.knob.isEmpty ? Color.clear : (about.colour.map(KSInk.c) ?? KSInk.slate))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .frame(width: 16, height: 16).opacity(about.knob.isEmpty ? 0.2 : 1).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(about.knob.isEmpty)
                     .help(about.knob.isEmpty ? about.says : "the colour of " + about.knob + ": click to change it in the scene")
                     .popover(isPresented: $palette) {
                  VStack(alignment: .trailing, spacing: 0) {
                    CloseX { palette = false }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 3), count: 10), spacing: 3) {
                            ForEach(0..<100, id: \.self) { i in
                                Button { palette = false; e.colour(r.id, i) } label: {
                                    RoundedRectangle(cornerRadius: 4).fill(KSInk.c(KSE16.PALETTE[i])).frame(width: 22, height: 22)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == about.index ? KSInk.sand : Color.clear, lineWidth: 2))
                                }.buttonStyle(.plain).help("colour \(i)")
                            }
                        }.padding(10).background(KSInk.surface)
                     }
                     }
                }.frame(width: w[5])
                KSPill(title: learning ? (typ == "note" ? "press a note\u{2026}" : "turn a knob\u{2026}") : "LEARN", look: learning ? .lit : .ghost, width: w[6]) { e.learn(r.id) }
                KSTick(on: e.keep.ticks.contains(r.id), tint: KSInk.sand) { e.keep.tick(r.id); e.objectWillChange.send() }
                    .frame(width: w[7]).help("tick, then DELETE above the table")
            }
            if e.clashes.contains(r.id) { Text("another row answers the same MIDI and value \u{2014} both keys are pressed").font(KSInk.mono).foregroundColor(KSInk.red) }
            if r.kind == "key" && r.key != nil && r.value == nil && typ == "cc" {
                Text("any value: the key is pressed for every message this knob sends").font(KSInk.mono).foregroundColor(KSInk.dim)
            }
            if r.led { Text("LED: " + about.says).font(KSInk.mono).foregroundColor(KSInk.dim).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

extension KSEngine { var clashes: Set<Int> { KSRules.clashes(rows) } }

// WHAT IT DID: the last sixty things, newest first
struct KSTraceBand: View {
    @ObservedObject var e: KSEngine
    var body: some View {
        KSBand(title: "WHAT IT DID") {
            VStack(alignment: .leading, spacing: 3) {
                if e.trace.isEmpty { Text("nothing yet").font(KSInk.mono).foregroundColor(KSInk.dim) }
                ForEach(Array(e.trace.reversed().prefix(40).enumerated()), id: \.offset) { _, l in
                    Text(l).font(KSInk.mono).foregroundColor(KSInk.sand).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(KSInk.ground).cornerRadius(8)
            KSPill(title: "CLEAR", look: .ghost) { e.trace = [] }
        }
    }
}
