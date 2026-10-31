// MIDI TO MK CONTROL, part 5: THE ENGINE (was MANTRA_MACKIE/mackie.lua, the Hammerspoon half; ported 13.10.2026).
//
//     the E16 (USB, three sources)  ->  here  ->  IAC Bus 1  ->  Live's MackieControl input
//     Live's MackieControl output   ->  a source chosen as BACK  ->  here, the lamps: what Live thinks is lit
//
// The settings file is the Lua's own, ~/.config/midi-to-mk.json, read at the switch and written at every change.
// No page server any more: the module's section of the window is the face (the :8855 page and the MANTRA_CONTROLS
// window asked that server; nothing else did).
import Foundation
import CoreMIDI
import AppKit

final class MKEngine: ObservableObject {
    static let CONF = URL(fileURLWithPath: NSHomeDirectory() + "/.config/midi-to-mk.json")
    static let RELEASE = 0.03           // seconds between a button's press and its release
    // LIVE DROPS MESSAGES THAT ARRIVE TOO CLOSE TOGETHER (measured 20.9.2026: no gap moved 1 beat of 10, 20 ms all 10),
    // so everything goes through ONE PACED QUEUE at 20 ms
    static let PACE = 0.02
    static let SPIN_EVERY = 0.025
    static let VOL_EVERY = 0.06
    static let PLANT_AFTER = 0.15, PLANT_GAP = 0.08, GUARD = 0.15
    static let LAMP = [94: "PLAY", 93: "STOP", 95: "RECORD", 86: "LOOP", 89: "HOME"]
    static let PORT_NAME = ["Port 1": "USB1", "Port 2": "USB2", "Port 3": "USB3"]

    // the settings, the Lua's keys
    var conf: [String: Any] = [:]
    @Published var rows: [MKRow] = []
    var power: Bool { (conf["on"] as? Bool) ?? true }
    var device: String { (conf["device"] as? String) ?? "" }
    var outWant: String { (conf["out"] as? String) ?? "" }
    var back: String { (conf["back"] as? String) ?? "" }
    var blobOn: Bool { (conf["blob"] as? Bool) ?? true }
    var blobSize: Double { (conf["blobSize"] as? Double) ?? Double((conf["blobSize"] as? Int) ?? 22) }
    var blobHold: Double { (conf["blobHold"] as? Double) ?? Double((conf["blobHold"] as? Int) ?? 1) }

    let midi = MKMidi()
    let live = MKLive()
    lazy var led = MKLed(midi: midi)
    var blob: MKBlob?
    var outRef: MIDIEndpointRef = 0
    @Published var outName = ""
    var sent = 0
    @Published var running = false
    @Published var trace: [String] = []                 // newest LAST
    var heard: (line: String, mine: Bool, at: Date)?
    var incoming: [(port: String, text: String, count: Int, at: Date)] = []
    @Published var detect = false
    @Published var learnId: Int?
    var held: [Int: Int] = [:]
    var down: Set<Int> = []
    var lamps: (at: Date?, lit: [String: Bool]) = (nil, [:])
    var labels: [String: String] = [:]
    var queue: [(Int, Int, Int)] = []                    // status, d1, d2
    var pump: Timer?
    var spins: [Int: (clicks: Int, cc: Int, rel: String, what: String, line: String)] = [:]
    var spinTimer: Timer?
    var vol: (want: Double?, blob: Bool, at: Date, timer: Timer?) = (nil, true, .distantPast, nil)
    var ticks: Set<Int> = []
    var undoStack: [(rows: [MKRow], what: String)] = []
    var redoStack: [(rows: [MKRow], what: String)] = []
    var act: [Int: (at: Date, how: String, held: Bool)] = [:]
    var dirty = false
    var refresh: Timer?
    var lastSources: Set<String> = []

    // ------------------------------------------------------------ the settings file
    func load() {
        conf = (try? JSONSerialization.jsonObject(with: Data(contentsOf: MKEngine.CONF))) as? [String: Any] ?? [:]
        if conf["on"] == nil { conf["on"] = true }
        for k in ["device", "out", "back"] where !(conf[k] is String) { conf[k] = "" }
        if conf["blob"] == nil { conf["blob"] = true }
        if blobSize <= 0 { conf["blobSize"] = 22 }
        if blobHold <= 0 { conf["blobHold"] = 1.4 }
        rows = ((conf["rows"] as? [[String: Any]]) ?? []).compactMap { MKRules.clean($0).0 }   // a row it cannot mean is dropped
    }
    func save() {
        conf["rows"] = rows.map { $0.dict }
        try? FileManager.default.createDirectory(at: MKEngine.CONF.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: conf, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: MKEngine.CONF, options: .atomic) }
        dirty = true
    }
    func row(_ id: Int) -> MKRow? { rows.first { $0.id == id } }

    // every change to the table goes through here, so UNDO and REDO cover all of them (was tablekeep.lua)
    func change(_ what: String, _ fn: () -> Void) {
        let before = rows
        fn()
        if rows != before {
            undoStack.append((before, what)); if undoStack.count > 100 { undoStack.removeFirst() }
            redoStack = []
        }
        ticks = ticks.filter { id in rows.contains { $0.id == id } }
        save()
    }
    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append((rows, s.what)); rows = s.rows; held = [:]; afterHistory("UNDO: " + s.what)
    }
    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append((rows, s.what)); rows = s.rows; held = [:]; afterHistory("REDO: " + s.what)
    }
    func afterHistory(_ line: String) {
        ticks = ticks.filter { id in rows.contains { $0.id == id } }
        if let l = learnId, row(l) == nil { learnId = nil }
        save(); note(line)
    }

    // ------------------------------------------------------------ the ports by their own names ("USB1 (OXI E16)")
    func label(_ name: String) -> String {
        if name.isEmpty { return "" }
        if let l = labels[name] { return l }
        if name.hasPrefix("Bus "), name.dropFirst(4).first?.isNumber == true { labels[name] = "IAC " + name; return labels[name]! }
        guard let his = MKEngine.PORT_NAME[name] else { labels[name] = name; return name }
        let mine = mkDevices().filter { $0 != "Network" && $0 != "IAC Driver" && $0 != "Bluetooth" }
        labels[name] = mine.count == 1 ? "\(his) (\(mine[0]))" : his
        return labels[name]!
    }

    // ------------------------------------------------------------ what it did
    func note(_ line: String, collapse: String? = nil) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let t = f.string(from: Date()) + "  " + line
        if let c = collapse, let last = trace.last, last.contains(c) { trace[trace.count - 1] = t } else { trace.append(t) }
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
        dirty = true
    }

    // ------------------------------------------------------------ the blob
    func liveScreen() -> NSRect {
        if let app = liveApp(),
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let wins = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
            if let b = wins.compactMap({ $0[kCGWindowBounds as String] as? [String: CGFloat] }).max(by: { ($0["Width"] ?? 0) * ($0["Height"] ?? 0) < ($1["Width"] ?? 0) * ($1["Height"] ?? 0) }) {
                let h = NSScreen.screens.first?.frame.height ?? 0
                let mid = NSPoint(x: (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, y: h - ((b["Y"] ?? 0) + (b["Height"] ?? 0) / 2))
                if let s = NSScreen.screens.first(where: { $0.frame.contains(mid) }) { return s.visibleFrame }
            }
        }
        return (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }
    func blobMake() {
        if blob != nil { return }
        var pos: (x: CGFloat, y: CGFloat)?
        if let p = conf["blobPos"] as? [String: Any], let x = p["x"] as? Double ?? (p["x"] as? Int).map(Double.init), let y = p["y"] as? Double ?? (p["y"] as? Int).map(Double.init) { pos = (CGFloat(x), CGFloat(y)) }
        let b = MKBlob(size: CGFloat(blobSize), pos: pos, screen: { [weak self] in self?.liveScreen() ?? .zero })
        b.moved = { [weak self] x, y in if let x = x, let y = y { self?.conf["blobPos"] = ["x": Int(x), "y": Int(y)] } else { self?.conf["blobPos"] = nil }; self?.save() }
        b.closed = { [weak self] in self?.conf["blob"] = false; self?.save(); self?.blob?.hideNow() }
        b.resized = { [weak self] s in self?.conf["blobSize"] = Int(s); self?.save() }
        blob = b
    }
    func blobSay(_ from: String, _ command: String) {
        guard blobOn else { return }
        blobMake(); blob?.say(MKBlob.line(from, MKMCU.short(command)), seconds: blobHold)
    }

    // ------------------------------------------------------------ sending to Live: one paced queue
    func openOut() {
        outRef = 0; outName = ""
        let dests = mkDestinations()
        var want = outWant
        if want.isEmpty { want = dests.first { $0.device.lowercased().contains("iac") }?.device ?? "" }
        if want.isEmpty { return }
        if let d = dests.first(where: { $0.device == want }) ?? dests.first(where: { $0.name == want }) { outRef = d.ref; outName = want }
    }
    func wireNow(_ m: (Int, Int, Int)) {
        guard outRef != 0, midi.send(outRef, m.0, m.1, m.2) else { return }
        if m.0 & 0xF0 == 0x90 { if m.2 > 0 { down.insert(m.1) } else { down.remove(m.1) } }
        sent += 1
    }
    // the first message goes at once; anything behind it waits its 20 ms; a runaway queue is dropped
    func wire(_ status: Int, _ d1: Int, _ d2: Int) {
        guard outRef != 0 else { return }
        if pump != nil { if queue.count < 200 { queue.append((status, d1, d2)) }; return }
        wireNow((status, d1, d2))
        pump = Timer.scheduledTimer(withTimeInterval: MKEngine.PACE, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.queue.isEmpty { t.invalidate(); self.pump = nil } else { self.wireNow(self.queue.removeFirst()) }
        }
    }
    func noteOn(_ n: Int, _ v: Int) { wire(0x90 | MKMCU.CHANNEL, n, v) }
    func ccOut(_ n: Int, _ v: Int) { wire(0xB0 | MKMCU.CHANNEL, n, v) }
    func after(_ s: Double, _ fn: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: fn) }
    // A BUTTON IS PRESSED AND THEN RELEASED, ALWAYS: a note left on is a key Live believes is still held
    func pressAndRelease(_ n: Int) { noteOn(n, MKMCU.PRESS); after(MKEngine.RELEASE) { self.noteOn(n, MKMCU.RELEASE) } }
    func letGoOfEverything() {
        for n in down where outRef != 0 { _ = midi.send(outRef, 0x90 | MKMCU.CHANNEL, n, MKMCU.RELEASE) }
        down = []; held = [:]
    }

    // A SPIN IS ONE MESSAGE: a jog carries the whole turn (2N moves N beats; with CONTROL down, note 72, the tempo
    // does not halve); a V-Pot is stepped one message at a time, at most four a flush
    func spin(_ a: MKAct, _ line: String) {
        var s = spins[a.row.id] ?? (0, a.number, a.rel ?? "jog", a.what, line)
        s.clicks += a.clicks; s.cc = a.number; s.rel = a.rel ?? "jog"; s.what = a.what; s.line = line
        spins[a.row.id] = s
        if spinTimer == nil {
            spinTimer = Timer.scheduledTimer(withTimeInterval: MKEngine.SPIN_EVERY, repeats: true) { [weak self] _ in self?.flushSpin() }
            flushSpin()
        }
    }
    func flushSpin() {
        var busy = false
        for (id, var s) in spins where s.clicks != 0 {
            busy = true
            if s.rel == "jog" {
                let tempo = down.contains(72)
                let (byte, used) = tempo ? MKMCU.tempoByteForClicks(s.clicks) : MKMCU.jogByteForClicks(s.clicks)
                if let b = byte {
                    ccOut(s.cc, b)
                    s.clicks -= s.clicks > 0 ? used : -used
                    note(String(format: "%@   \u{2192}   %@  %+d click%@%@  (CC %d = %d)", s.line, s.what, b < 64 ? used : -used,
                                used == 1 ? "" : "s", tempo ? "  (CONTROL is down: the TEMPO)" : "", s.cc, b), collapse: s.line)
                }
            } else {
                let n = min(4, abs(s.clicks))
                for _ in 0..<n { ccOut(s.cc, s.clicks > 0 ? 1 : 65) }
                s.clicks -= s.clicks > 0 ? n : -n
                note(String(format: "%@   \u{2192}   %@  %+d step%@  (CC %d)", s.line, s.what, s.clicks >= 0 ? n : -n, n == 1 ? "" : "s", s.cc), collapse: s.line)
            }
            spins[id] = s
        }
        if !busy { spinTimer?.invalidate(); spinTimer = nil }
    }

    // THE VOLUME KNOB IS THROTTLED: at most every 60 ms, with a trailing call so where he LEAVES the knob is where it lands
    func setVolume(_ pct: Double, blob: Bool) {
        vol.want = pct; vol.blob = blob
        let due = vol.at.timeIntervalSinceNow + MKEngine.VOL_EVERY
        if due <= 0 { applyVolume() }
        else if vol.timer == nil { vol.timer = Timer.scheduledTimer(withTimeInterval: due, repeats: false) { [weak self] _ in self?.applyVolume() } }
    }
    func applyVolume() {
        vol.timer = nil
        guard let p = vol.want else { return }
        vol.want = nil; vol.at = Date()
        if vol.blob { MKMac.toward(p) } else { MKMac.set(p) }
    }

    // PLAY / STOP, his rule (21.9.2026): playing → STOP, then the jog one beat forward and back to plant the insert
    // point on the playhead; stopped → plain PLAY, which seeks the insert point. Decided twice: now, and again GUARD
    // seconds later from Live's own log, so a STOP never lands on a stopped Live (that sends it to the start, 1.10.2026)
    func plant(_ cc: Int) {
        guard let fwd = MKMCU.jogByteForClicks(1).byte, let back = MKMCU.jogByteForClicks(-1).byte else { return }
        after(MKEngine.PLANT_AFTER) { self.ccOut(cc, fwd); self.after(MKEngine.PLANT_GAP) { self.ccOut(cc, back) } }
    }
    func playStop(_ a: MKAct) -> String {
        guard let playing = live.isPlaying() else {
            for p in a.parts { noteOn(p.note, p.velocity) }
            return "SHIFT + PLAY (Live could not be asked: its own playhead, not the insert point)"
        }
        after(MKEngine.GUARD) {
            let now = self.live.saysNow()
            if playing {
                if now != false { self.pressAndRelease(a.stop) }
                self.plant(a.number); self.live.expect(false)
            } else {
                if now != true { self.pressAndRelease(a.play) }
                self.live.expect(true)
            }
        }
        return playing ? "STOP (note \(a.stop), only if Live is still playing) and the insert point planted on the playhead (CC \(a.number))"
                       : "PLAY (note \(a.play), only if Live is still stopped) from the insert point"
    }
    func doAct(_ a: MKAct) -> String? {
        switch a.kind {
        case "mac": if a.act == "up" { MKMac.up() } else if a.act == "down" { MKMac.down() } else if a.act == "mute" { MKMac.mute() }
        case "macvolume": setVolume(a.percent, blob: a.blob)
        case "combo": for p in a.parts { noteOn(p.note, p.velocity) }       // in order, nothing between them
        case "transport": return playStop(a)
        case "note": if a.release { pressAndRelease(a.note) } else { noteOn(a.note, a.velocity) }
        case "pitch": wire(0xE0 | (a.channel & 0x0F), a.lsb, a.msb)
        default: ccOut(a.number, a.value)
        }
        return nil
    }

    // ------------------------------------------------------------ a message arrives
    func received(_ source: String, _ m: MKRaw) {
        if !MKWatch.quiet(m) {                                           // the monitor sees everything first
            let text = MKWatch.describe(m), port = label(source)
            if let top = incoming.first, top.port == port, top.text == text { incoming[0].count += 1; incoming[0].at = Date() }
            else { incoming.insert((port, text, 1, Date()), at: 0); if incoming.count > 4 { incoming.removeLast() } }
            dirty = true
        }
        var msg: MKMsg?
        switch m.system ? 0 : m.status & 0xF0 {
        case 0xB0: msg = MKMsg(from: "cc", number: m.d1, value: m.d2, channel: m.status & 0x0F)
        case 0x90: msg = MKMsg(from: "note", number: m.d1, value: m.d2, channel: m.status & 0x0F)
        case 0x80: msg = MKMsg(from: "note", number: m.d1, value: 0, channel: m.status & 0x0F)   // a pad let go
        default:
            if MKWatch.quiet(m) { return }
            heard = (label(source) + "   " + MKWatch.describe(m), source == device && !device.isEmpty, Date())
            return
        }
        // Live talking back: the lamps on the BACK source
        if source == back && !back.isEmpty, m.status & 0xF0 == 0x90, let name = MKEngine.LAMP[m.d1] { lamps.lit[name] = m.d2 > 0; lamps.at = Date() }
        if let msg = msg { onMessage(source, msg) }
    }

    func onMessage(_ source: String, _ msg: MKMsg) {
        let mine = !device.isEmpty && device == source
        let kind = msg.from == "note" ? "NOTE" : "CC"
        heard = ("\(label(source))   \(kind) \(msg.number) = \(msg.value)   ch \(msg.channel ?? 0)", mine, Date())
        dirty = true
        // DETECT: the knob names the device; an IAC bus is never locked (it is where this app SENDS)
        if detect {
            if source.hasPrefix("Bus ") { note("that is an IAC bus, where this app SENDS - turn a knob on the controller instead"); return }
            detect = false; conf["device"] = source; save()
            note("locked to \(label(source))  (\(kind) \(msg.number) spoke first)"); return
        }
        // LEARN: only a message of the row's own FILTER; a note's release teaches nothing
        if let lid = learnId {
            guard let r = row(lid) else { learnId = nil; return }
            if msg.from != r.from {
                note("LEARN on row \(r.id) takes \(r.from == "note" ? "a NOTE" : "a CC") only: \(kind) \(msg.number) let pass", collapse: "let pass"); return
            }
            if msg.from == "note" && msg.value == 0 { return }
            learnId = nil
            var want = r.dict; want["number"] = msg.number
            if !MKRules.sweeps(r) { want["value"] = msg.value }
            if let c = MKRules.clean(want).0 {
                change("row \(c.id) learned \(MKRules.fromText(c))") { if let i = rows.firstIndex(where: { $0.id == r.id }) { rows[i] = c } }
                note("row \(c.id) learned \(MKRules.fromText(c)) = \(MKRules.valueText(c))")
            }
            return
        }
        // THE ACTIVITY LED: green when it fires, amber when nothing is sent; only the locked controller
        if mine {
            let release = msg.from == "note" && msg.value == 0
            for r in rows where r.from == msg.from && r.number == msg.number {
                if release { act[r.id]?.held = false }
                else if r.value == nil || r.value == msg.value {
                    act[r.id] = (Date(), power && MKRules.matches(r, msg) ? "fire" : "heard", msg.from == "note")
                }
            }
        }
        guard power, mine else { return }                       // only the locked controller is obeyed
        if let lit = led.feel(rows, msg.from, msg.number, msg.value, msg.channel) { note(lit) }
        let came = "\(kind) \(msg.number) = \(msg.value)"
        for a in MKRules.fire(rows, msg, held: &held) {
            blobSay(MKRules.fromText(a.row), a.row.command)
            if a.rel != nil { spin(a, came); continue }          // a knob: added up, sent in a moment
            let said = doAct(a)
            var line: String
            switch a.kind {
            case "pitch": line = "\(came)   \u{2192}   \(a.what)  (pitch bend \(a.msb * 128 + a.lsb))"
            case "mac": line = "\(came)   \u{2192}   \(a.what)  (the Mac, not Live)"
            case "macvolume": line = "\(came)   \u{2192}   the Mac's volume \(Int(a.percent + 0.5))%" + (a.blob ? "  (its own blob)" : "  (silent)")
            case "transport": line = "\(came)   \u{2192}   \(a.what)  (\(said ?? ""))"
            case "combo": line = "\(came)   \u{2192}   \(a.what)  (\(MKMCU.wire(a.row.command)))"
            default: line = "\(came)   \u{2192}   \(a.what)  (note \(a.note))"
            }
            if outRef == 0 && a.kind != "mac" && a.kind != "macvolume" { line += "   \u{2014} BUT NOTHING IS OPEN TO LIVE" }
            note(line, collapse: came)
        }
    }

    // ------------------------------------------------------------ TRY: the command, with no knob
    func tryRow(_ r: MKRow) {
        guard let e = MKMCU.command(r.command) else { return }
        blobSay(MKRules.fromText(r), r.command)
        switch e.kind {
        case "button" where e.with != nil:
            var h: [Int: Int] = [:]
            for a in MKRules.fire([r], MKMsg(from: r.from, number: r.number, value: r.value ?? 127), held: &h) { _ = doAct(a) }
            note("TRY row \(r.id)   \u{2192}   \(e.label)  (\(MKMCU.wire(r.command)))")
        case "button" where r.how == "hold":
            noteOn(e.note!, MKMCU.PRESS); after(0.25) { self.noteOn(e.note!, MKMCU.RELEASE) }
            note("TRY row \(r.id)   \u{2192}   \(e.label) held for a quarter second  (note \(e.note!))")
        case "button":
            pressAndRelease(e.note!); note("TRY row \(r.id)   \u{2192}   \(e.label)  (note \(e.note!))")
        case "transport":
            var h: [Int: Int] = [:]
            for a in MKRules.fire([r], MKMsg(from: r.from, number: r.number, value: r.value ?? 127), held: &h) {
                note("TRY row \(r.id)   \u{2192}   \(e.label)  (\(doAct(a) ?? ""))")
            }
        case "jog", "vpot":
            // TRY is a click of his own knob to the right, through the row's INVERT tick as a real click would be
            let byte = MKMCU.signmag(r.invert == true ? -1 : 1)!
            ccOut(e.cc!, byte)
            note("TRY row \(r.id)   \u{2192}   \(e.label), one click right\(r.invert == true ? " (inverted: Live goes back)" : "")  (CC \(e.cc!) = \(byte))")
        case "fader":
            let f = MKMCU.fader(64, bits: 7); wire(0xE0 | (e.channel! & 0x0F), f.lsb, f.msb)
            note("TRY row \(r.id)   \u{2192}   \(e.label) to the middle")
        case "mac":
            _ = doAct(MKAct(row: r, kind: "mac", what: e.label, act: e.act ?? "")); note("TRY row \(r.id)   \u{2192}   \(e.label)  (the Mac, not Live)")
        case "macvolume":
            // shows the Mac's blob where the volume stands: a quarter step down and back up
            MKMac.down(); after(0.12) { MKMac.up() }
            note("TRY row \(r.id)   \u{2192}   the Mac's volume blob, where it stands")
        default: break
        }
    }

    // ------------------------------------------------------------ the verbs the section's buttons use
    func setPower() { conf["on"] = !power; save(); if !power { letGoOfEverything() } }
    func toggleDetect() { detect.toggle(); if detect { learnId = nil }; dirty = true }
    func unlock() { conf["device"] = ""; save(); note("the device was unlocked") }
    func learn(_ id: Int) { if learnId == id { learnId = nil } else { learnId = id; detect = false }; dirty = true }
    func setOut(_ name: String) { conf["out"] = name; save(); openOut(); note(outRef != 0 ? "Mackie goes to " + outName : "nothing is open to Live") }
    func setBack(_ name: String) {
        conf["back"] = name; save(); lamps = (nil, [:])
        note(name.isEmpty ? "not listening for Live's lights" : "listening for Live on " + label(name))
    }
    func add() { let r = MKRules.blank(rows); change("row \(r.id) added") { rows.append(r) } }
    func tick(_ id: Int) { if ticks.contains(id) { ticks.remove(id) } else { ticks.insert(id) }; dirty = true }
    func tickAll() { if !rows.isEmpty && rows.allSatisfy({ ticks.contains($0.id) }) { ticks = [] } else { ticks = Set(rows.map { $0.id }) }; dirty = true }
    func deleteTicked() {
        let gone = ticks
        let ids = rows.filter { gone.contains($0.id) }.map { String($0.id) }
        guard !ids.isEmpty else { return }
        change((ids.count == 1 ? "row " : "rows ") + ids.joined(separator: ", ") + " deleted") {
            for r in rows where gone.contains(r.id) {
                note("row \(r.id) removed  (\(MKRules.fromText(r)) = \(MKRules.valueText(r)) \u{2192} \(MKRules.target(r)))"); held[r.id] = nil
            }
            rows.removeAll { gone.contains($0.id) }
        }
        if let l = learnId, gone.contains(l) { learnId = nil }
    }
    // one column of one row; a new command brings its own HOW (and its own INVERT)
    func set(_ id: Int, _ key: String, _ v: Any?) {
        guard let r = row(id) else { return }
        var want = r.dict
        if r.value == nil { want["value"] = nil }
        want[key] = v
        if key == "command", let c = v as? String, c != r.command { want["how"] = MKRules.defaultHow(c); want["invert"] = nil }
        let (c, why) = MKRules.clean(want)
        guard let cleaned = c else { note("that row was refused: " + why); return }
        change("row \(id): \(key == "from" ? "filter" : key) \(v.map { "\($0)" } ?? "any")") { if let i = rows.firstIndex(where: { $0.id == id }) { rows[i] = cleaned } }
        held[id] = nil
    }
    func colour(_ id: Int, _ index: Int) { if let r = row(id) { note(led.setColour(r.from, r.number, index)) } }
    func toggleBlob() {
        conf["blob"] = !blobOn; save()
        if blobOn { blobSay("the toast", "playstop") } else { blob?.hideNow() }
        note(blobOn ? "the command blob is on" : "the command blob is off")
    }
    func blobHome() { blobMake(); blob?.home(); conf["blobPos"] = nil; conf["blob"] = true; save(); blobSay("the toast", "playstop"); note("the command blob went back to the top of Live's screen") }
    func setBlobHold(_ s: Double) { conf["blobHold"] = max(0.3, min(10, s)); save(); note(String(format: "the command blob stays for %.1f s", blobHold)) }
    func clearTrace() { trace = [] }

    // ------------------------------------------------------------ what the section shows
    func lit(_ id: Int) -> String? {
        guard let a = act[id] else { return nil }
        let age = Date().timeIntervalSince(a.at)
        if age < 0.3 || (a.held && age < 20) { return a.how }
        return nil
    }
    func why() -> (String, Bool) {
        if midi.names.isEmpty { return ("no MIDI source is open \u{2014} is the controller plugged in?", true) }
        if outRef == 0 { return ("nothing is open to Live: pick a bus under TO LIVE, and turn the IAC Driver on in Audio MIDI Setup", true) }
        if !power { return ("the switch is OFF: nothing is sent", false) }
        if device.isEmpty { return ("no device is locked: press DETECT DEVICE and turn a knob", false) }
        if rows.isEmpty { return ("the table is empty: press + A ROW", false) }
        return ("listening on " + midi.names.map(label).joined(separator: ", ") + "  \u{2192}  " + outName, false)
    }
    var backLine: String {
        if back.isEmpty { return "not listening for Live's lights \u{2014} optional, and it needs a second IAC bus" }
        if let at = lamps.at {
            return "Live's own lights, " + mkAgo(at) + ":  " + ["PLAY", "RECORD", "LOOP"].map { ($0) + (lamps.lit[$0] == true ? " on" : " off") }.joined(separator: " · ")
        }
        return "listening on " + label(back) + ", nothing from Live yet"
    }
    var sentLine: String { outRef != 0 ? "\(sent) message\(sent == 1 ? "" : "s") sent to \(outName)" : "nothing is open to Live" }
    func status() -> String {
        if !running { return "OFF" }
        if !power { return "PAUSED" }
        if outRef == 0 { return "NOTHING TO LIVE" }
        if device.isEmpty { return "NO DEVICE" }
        return "LISTENING · " + label(device)
    }

    // ------------------------------------------------------------ the switch
    func start() {
        guard !running else { return }
        load()
        midi.onMessage = { [weak self] s, m in self?.received(s, m) }
        // A DEVICE PLUGGED IN AFTER THE SWITCH still works, but the ports are reopened only if they really changed
        midi.onSetup = { [weak self] in
            guard let self = self, self.running else { return }
            let now = Set(mkSources().map { $0.name })
            if now == self.lastSources { return }
            self.after(0.5) { if self.running { self.labels = [:]; _ = self.midi.openAll(); self.lastSources = Set(self.midi.names); self.openOut() } }
        }
        midi.start()
        labels = [:]
        let n = midi.openAll()
        lastSources = Set(midi.names)
        openOut()
        live.start()
        led.follow = { [weak self] in (self?.rows ?? []).filter { $0.led == true && $0.on && $0.command == "volume" && $0.from == "cc" }.map { $0.number } }
        led.startFollowing()
        running = true
        refresh = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.dirty || !self.act.isEmpty { self.dirty = false; self.objectWillChange.send() }
        }
        note("MIDI to MK Control is up, listening on \(n) source\(n == 1 ? "" : "s"), sending to \(outRef != 0 ? outName : "nothing yet")")
    }
    func stop() {
        guard running else { return }
        live.stop(); led.stopFollowing()
        pump?.invalidate(); pump = nil; queue = []
        spinTimer?.invalidate(); spinTimer = nil; spins = [:]
        vol.timer?.invalidate(); vol.timer = nil; vol.want = nil
        letGoOfEverything()                                  // never leave Live holding a button down
        blob?.delete(); blob = nil
        midi.stop(); outRef = 0; outName = ""
        refresh?.invalidate(); refresh = nil
        detect = false; learnId = nil
        running = false
    }
}
