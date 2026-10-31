// MIDI TO MK CONTROL: a knob on a MIDI controller becomes a Mackie Control command in Live, above all THE ARRANGEMENT
// TIMELINE UNDER A KNOB, which Live gives no other way. Marko, 20.9.2026: "we cannot control for example playback
// position with MIDI, so this is a workaround." Ported from Lua 13.10.2026 (MANTRA_MACKIE; "no more Lua, only Swift").
// The parts: MackieMCU (the protocol and the 121 commands), MackieRules (the table's mind), MackieIO (CoreMIDI, Live's
// playing state, the Mac's volume, the E16's rings), MackieBlob (the toast), MackieEngine (the host). This file is the
// module the umbrella switches, and its section of the window, which replaces the :8855 page and the separate window.
import SwiftUI
import AppKit

final class MackieModule: LiveModule {
    let id = "mackie"
    let title = "MIDI TO MK CONTROL"
    let about = "A knob on a MIDI controller becomes a Mackie Control command in Live: the timeline under a knob, PLAY / STOP from the insert point, 121 commands"
    let defaultOn = true
    let engine = MKEngine()
    let menuTarget = MKMenuTarget()
    init() { menuTarget.engine = engine }

    func setOn(_ on: Bool) { if on { engine.start() } else { engine.stop() } }
    func liveCame() { if engine.running { engine.live.askBoth() } }
    func liveLeft() {}
    func hotkeys() -> [(Chord, () -> Void)] { [] }
    func menuItems() -> [NSMenuItem] {
        guard engine.running else { return [] }
        func item(_ t: String, _ sel: Selector?, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: "  " + t, action: sel, keyEquivalent: ""); i.target = menuTarget
            i.state = on ? .on : .off; i.isEnabled = sel != nil; return i
        }
        return [
            item(engine.power ? "Stop sending Mackie" : "Send Mackie", #selector(MKMenuTarget.power)),
            item(engine.device.isEmpty ? "No device locked" : "Locked to " + engine.label(engine.device), nil),
            item(engine.outName.isEmpty ? "Nothing open to Live" : "Sending to " + engine.outName, nil),
            item("The command blob at the top of Live", #selector(MKMenuTarget.blob), on: engine.blobOn),
            item("\(engine.rows.count) row\(engine.rows.count == 1 ? "" : "s") in the table", nil),
        ]
    }
    func settingsView() -> AnyView { AnyView(MKSection(e: engine)) }
    func status() -> String { engine.status() }
}

final class MKMenuTarget: NSObject {
    weak var engine: MKEngine?
    @objc func power() { engine?.setPower() }
    @objc func blob() { engine?.toggleBlob() }
}

// MARK: - the section

private let MK_SAND = Color(red: 0xF2/255, green: 0xDD/255, blue: 0xB4/255)
private let MK_SLATE = Color(red: 0x23/255, green: 0x30/255, blue: 0x3D/255)
private let MK_RED = Color(red: 0xEF/255, green: 0x44/255, blue: 0x44/255)
private let MK_MONO = Font.system(size: 11, design: .monospaced)

private func mkHex(_ s: String) -> Color? {
    guard let v = UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
    return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}

// a box sent on Return or when it loses focus; the refresh does not overwrite it while he types
struct MKField: View {
    let value: String; var width: CGFloat = 60; var disabled = false; var lit = false
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text).textFieldStyle(.plain).font(MK_MONO).foregroundColor(MK_SAND)
            .padding(.horizontal, 6).padding(.vertical, 4).frame(width: width)
            .background(Color.black.opacity(0.4)).cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(lit || focused ? AMBER : MK_SLATE, lineWidth: 1))
            .focused($focused).disabled(disabled).opacity(disabled ? 0.4 : 1)
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: focused) { _, f in if !f && text != value { commit(text) } }
            .onSubmit { if text != value { commit(text) } }
    }
}

struct MKTick: View {
    let on: Bool; var dead = false; var tint: Color = AMBER; let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4).fill(on ? tint : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? tint : MK_SLATE, lineWidth: 1.5))
                .overlay(Text(on ? "\u{2713}" : "").font(.system(size: 10, weight: .bold)).foregroundColor(.black))
                .frame(width: 18, height: 18).opacity(dead ? 0.25 : 1).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(dead)
    }
}

struct MKChoice: View {
    let options: [(id: String, label: String)]; let chosen: String; var width: CGFloat = 120; let pick: (String) -> Void
    var body: some View {
        Menu { ForEach(options, id: \.id) { o in Button(o.label) { pick(o.id) } } } label: {
            Text(options.first { $0.id == chosen }?.label ?? (chosen.isEmpty ? "\u{2014}" : chosen)).font(MK_MONO).foregroundColor(MK_SAND).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .padding(.horizontal, 6).padding(.vertical, 3).frame(width: width, alignment: .leading).background(MK_SLATE).cornerRadius(6)
    }
}

struct MKSection: View {
    @ObservedObject var e: MKEngine
    var body: some View {
        let (why, bad) = e.why()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(why).font(MK_MONO).foregroundColor(bad ? MK_RED : GREY).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Word(text: e.power ? "SENDING" : "PAUSED", on: e.power) { e.setPower() }
            }
            MKMonitor(e: e)
            // THE DEVICE: DETECT locks the controller that speaks first
            VStack(alignment: .leading, spacing: 4) {
                Label10(text: "THE DEVICE \u{2014} WHAT COMES IN")
                HStack {
                    Word(text: e.detect ? "TURN OR PRESS SOMETHING\u{2026}" : "DETECT DEVICE", on: e.detect) { e.toggleDetect() }
                    Word(text: "UNLOCK", on: false) { e.unlock() }
                    Text(e.device.isEmpty ? "no device locked" : "locked to " + e.label(e.device)).font(MK_MONO).foregroundColor(e.device.isEmpty ? GREY : MK_SAND)
                }
                if let h = e.heard {
                    HStack(spacing: 6) {
                        Circle().fill(h.mine ? GREEN : GREY).frame(width: 7, height: 7)
                        Text(h.line).font(MK_MONO).foregroundColor(MK_SAND).lineLimit(1)
                        Text(mkAgo(h.at)).font(MK_MONO).foregroundColor(GREY)
                    }
                }
            }
            // TO LIVE: where Mackie goes, where Live's lights come back
            VStack(alignment: .leading, spacing: 4) {
                Label10(text: "TO LIVE \u{2014} WHAT GOES OUT")
                HStack {
                    Text("to").font(MK_MONO).foregroundColor(GREY)
                    MKChoice(options: [("", "the IAC Driver")] + Array(Set(mkDestinations().map { $0.device }.filter { !$0.isEmpty })).sorted().map { ($0, $0) },
                             chosen: e.outWant, width: 170) { e.setOut($0) }
                    Text("lights from").font(MK_MONO).foregroundColor(GREY)
                    MKChoice(options: [("", "not listening")] + mkSources().map { ($0.name, e.label($0.name)) }, chosen: e.back, width: 170) { e.setBack($0) }
                }
                Small(text: e.sentLine + "  \u{00B7}  " + e.backLine)
            }
            // THE COMMAND BLOB
            HStack {
                Label10(text: "THE COMMAND BLOB")
                Word(text: e.blobOn ? "ON" : "OFF", on: e.blobOn) { e.toggleBlob() }
                Word(text: "PUT IT BACK AT THE TOP", on: false) { e.blobHome() }
                Text("stays").font(MK_MONO).foregroundColor(GREY)
                MKField(value: String(format: "%.1f", e.blobHold), width: 44) { e.setBlobHold(Double($0.replacingOccurrences(of: ",", with: ".")) ?? 1.4) }
                Text("s").font(MK_MONO).foregroundColor(GREY)
            }
            MKTable(e: e)
            // WHAT IT DID
            VStack(alignment: .leading, spacing: 2) {
                HStack { Label10(text: "WHAT IT DID"); Spacer(); Word(text: "CLEAR", on: false) { e.clearTrace() } }
                ForEach(Array(e.trace.reversed().prefix(12).enumerated()), id: \.offset) { _, l in
                    Text(l).font(MK_MONO).foregroundColor(MK_SAND).lineLimit(1).textSelection(.enabled)
                }
                if e.trace.isEmpty { Small(text: "nothing yet") }
            }
        }
    }
}

// THE INCOMING MIDI MONITOR: every message on every port, newest first, four lines
struct MKMonitor: View {
    @ObservedObject var e: MKEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if e.incoming.isEmpty {
                Small(text: "no MIDI yet \u{2014} listening on " + (e.midi.names.isEmpty ? "no port at all" : e.midi.names.map(e.label).joined(separator: ", ")))
            }
            ForEach(Array(e.incoming.enumerated()), id: \.offset) { i, m in
                let fresh = i == 0 && Date().timeIntervalSince(m.at) < 2
                HStack(spacing: 0) {
                    Circle().fill(fresh ? AMBER : Color.clear).frame(width: 6, height: 6).padding(.trailing, 6)
                    Text(m.port).frame(width: 140, alignment: .leading)
                    Text(m.text).frame(width: 170, alignment: .leading)
                    if m.count > 1 { Text("\u{00D7}\(m.count)  ").foregroundColor(AMBER) }
                    Text(mkAgo(m.at))
                }
                .font(MK_MONO).foregroundColor(fresh ? MK_SAND : GREY).lineLimit(1)
            }
        }
        .frame(height: 4 * 15, alignment: .top)
    }
}

// THE TABLE: a row is two lines (what comes in and what Live gets; then how) and the line that says it
struct MKTable: View {
    @ObservedObject var e: MKEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label10(text: "THE TABLE")
                Word(text: "UNDO", on: false) { e.undo() }.opacity(e.undoStack.isEmpty ? 0.4 : 1)
                Word(text: "REDO", on: false) { e.redo() }.opacity(e.redoStack.isEmpty ? 0.4 : 1)
                Text(e.undoStack.last.map { "last change: " + $0.what } ?? "").font(MK_MONO).foregroundColor(GREY).lineLimit(1)
                Spacer()
                Word(text: e.ticks.isEmpty ? "DELETE" : "DELETE \(e.ticks.count)", on: false) { e.deleteTicked() }
                    .opacity(e.ticks.isEmpty ? 0.4 : 1)
                MKTick(on: !e.rows.isEmpty && e.rows.allSatisfy { e.ticks.contains($0.id) }, tint: MK_SAND) { e.tickAll() }
            }
            if e.rows.isEmpty { Small(text: "No rows yet. Press + A ROW, then LEARN and turn the knob, then pick the MK command.") }
            let clash = MKRules.clashes(e.rows)
            ForEach(e.rows, id: \.id) { r in MKRowView(e: e, r: r, clash: clash.contains(r.id)) }
            Word(text: "+ A ROW", on: false) { e.add() }
        }
    }
}

struct MKRowView: View {
    @ObservedObject var e: MKEngine
    let r: MKRow
    let clash: Bool
    @State private var palette = false
    var body: some View {
        let learning = e.learnId == r.id
        let lit = e.lit(r.id)
        let ledAbout = e.led.about(r.from, r.number, isVolume: r.command == "volume")
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(lit == "fire" ? GREEN : (lit == "heard" ? AMBER : MK_SLATE)).frame(width: 9, height: 9)
                    .help("lights while your hand moves this row: green = it fired, amber = heard, nothing sent")
                MKChoice(options: [("cc", "CC"), ("note", "NOTE")], chosen: r.from, width: 62) { e.set(r.id, "from", $0) }
                MKField(value: String(r.number), width: 44, lit: learning) { e.set(r.id, "number", $0) }
                MKField(value: MKRules.valueText(r), width: 50, disabled: MKRules.sweeps(r)) { e.set(r.id, "value", $0) }
                Menu {
                    ForEach(MKMCU.catalogue(), id: \.group) { g in
                        Section(g.group) { ForEach(g.items, id: \.id) { it in Button(it.label) { e.set(r.id, "command", it.id) } } }
                    }
                } label: { Text(MKRules.target(r)).font(MK_MONO).foregroundColor(MK_SAND).lineLimit(1) }
                    .menuStyle(.borderlessButton).menuIndicator(.visible)
                    .padding(.horizontal, 6).padding(.vertical, 3).frame(width: 300, alignment: .leading).background(MK_SLATE).cornerRadius(6)
                MKTick(on: e.ticks.contains(r.id), tint: MK_SAND) { e.tick(r.id) }.help("tick, then DELETE above the table")
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 9, height: 1)
                MKChoice(options: MKRules.hows(r.command).map { ($0.id, $0.label) }, chosen: r.how, width: 120) { e.set(r.id, "how", $0) }
                Text("INVERT").font(MK_MONO).foregroundColor(GREY)
                MKTick(on: r.invert == true, dead: !MKRules.relative(r)) { e.set(r.id, "invert", !(r.invert ?? false)) }
                Text("ON").font(MK_MONO).foregroundColor(GREY)
                MKTick(on: r.on) { e.set(r.id, "on", !r.on) }
                Text("LED").font(MK_MONO).foregroundColor(GREY)
                MKTick(on: r.led == true && ledAbout.can, dead: !ledAbout.can, tint: mkHex(ledAbout.colour) ?? AMBER) { e.set(r.id, "led", !(r.led ?? false)) }
                    .help(ledAbout.says)
                Button { if !ledAbout.knob.isEmpty { palette = true } } label: {
                    RoundedRectangle(cornerRadius: 3).fill(ledAbout.knob.isEmpty ? Color.clear : (mkHex(ledAbout.colour) ?? MK_SLATE))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.25), lineWidth: 1))
                        .frame(width: 14, height: 14).opacity(ledAbout.knob.isEmpty ? 0.2 : 1).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(ledAbout.knob.isEmpty)
                .help(ledAbout.knob.isEmpty ? ledAbout.says : "the colour of " + ledAbout.knob + ": click to change it in the scene")
                .popover(isPresented: $palette) {
                  VStack(alignment: .trailing, spacing: 0) {
                    CloseX { palette = false }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 3), count: 10), spacing: 3) {
                        ForEach(0..<100, id: \.self) { i in
                            Button { palette = false; e.colour(r.id, i) } label: {
                                RoundedRectangle(cornerRadius: 3).fill(mkHex(MKLed.hex(i)) ?? .gray).frame(width: 20, height: 20)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(i == ledAbout.index ? MK_SAND : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).help("colour \(i)")
                        }
                    }.padding(8)
                }
                }
                Spacer()
                Word(text: learning ? (r.from == "note" ? "PRESS A NOTE\u{2026}" : "TURN A KNOB\u{2026}") : "LEARN", on: learning) { e.learn(r.id) }
                Word(text: "TRY", on: false) { e.tryRow(r) }.help("send this command once, now")
            }
            if clash { Text("another row answers the same message \u{2014} both are sent").font(MK_MONO).foregroundColor(MK_RED) }
            Small(text: MKRules.says(r))
            if r.led == true { Small(text: "LED: " + ledAbout.says) }
        }
        .padding(8).background(Color.white.opacity(0.03)).cornerRadius(8)
    }
}
