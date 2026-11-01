// MIDI TO KEY STROKE, the engine: midikeys.lua, volume.lua, e16led.lua, tablekeep.lua and midiwatch.lua (MIDI_TO_
// KEYSTROKE) ported to Swift. CoreMIDI directly: every source the Mac has is listened to (the OXI E16 is ONE device
// but THREE sources, Port 1-3 = USB1-3: oxi-e16.md), and DETECT locks one source by name. A matching row presses its
// key chord in the front app (CGEvent: Accessibility) or moves the Mac's volume; a note with its LED ticked lights
// its knob on the E16 through USB3. The table, the locked device and the switch live in ~/.config/midi-to-keystroke.json,
// the same file the Lua engine wrote, in the same form.
import Foundation
import AppKit
import CoreMIDI
import CoreAudio
import AudioToolbox

let KS_CONF = URL(fileURLWithPath: NSHomeDirectory() + "/.config/midi-to-keystroke.json")
let KS_PORT_NAME = ["Port 1": "USB1", "Port 2": "USB2", "Port 3": "USB3", "Bus 1": "IAC Bus 1"]

// hs.keycodes.map names <-> virtual key codes (the names the table has always kept)
let KS_KEYS: [String: CGKeyCode] = {
    var m: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53, "rightcmd": 54, "cmd": 55, "shift": 56,
        "capslock": 57, "alt": 58, "ctrl": 59, "rightshift": 60, "rightalt": 61, "rightctrl": 62, "fn": 63,
        "pad.": 65, "pad*": 67, "pad+": 69, "padclear": 71, "pad/": 75, "padenter": 76, "pad-": 78, "pad=": 81,
        "pad0": 82, "pad1": 83, "pad2": 84, "pad3": 85, "pad4": 86, "pad5": 87, "pad6": 88, "pad7": 89, "pad8": 91,
        "pad9": 92, "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126]
    let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    for (i, c) in f.enumerated() { m["f\(i + 1)"] = c }
    return m
}()
let KS_KEYNAMES: [CGKeyCode: String] = Dictionary(KS_KEYS.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

func ksFlags(_ mods: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in mods {
        switch m { case "cmd": f.insert(.maskCommand); case "alt": f.insert(.maskAlternate); case "shift": f.insert(.maskShift)
        case "ctrl": f.insert(.maskControl); case "fn": f.insert(.maskSecondaryFn); default: break }
    }
    return f
}

// MARK: the Mac's volume (volume.lua): its own keys, so its own blob; or the exact silent number

enum KSVolume {
    static let STEP = 1.5, DEAD = 1.1, BUDGET = 8          // a quarter step MEASURED at 1.44 of 0-100
    static func device() -> AudioObjectID? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }
    static func level() -> Double? {
        guard let d = device() else { return nil }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? Double(v) * 100 : nil
    }
    static func muted() -> Bool {
        guard let d = device() else { return false }
        var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr && v != 0
    }
    // the silent, exact way (behind the tick): the number, no blob
    static func set(_ pct: Int) {
        guard let d = device() else { return }
        var v = Float32(max(0, min(100, pct))) / 100, size = UInt32(MemoryLayout<Float32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(d, &a, 0, nil, size, &v)
        if pct > 0 && muted() {
            var m = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
            var am = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(d, &am, 0, nil, size, &m)
        }
    }
    // one press of a media key, as the keyboard sends it (NX_KEYTYPE_SOUND_UP 0, SOUND_DOWN 1, MUTE 7)
    static func key(_ code: Int, quarter: Bool) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 8,
                                              data1: (code << 16) | ((down ? 0xa : 0xb) << 8), data2: -1)?.cgEvent else { continue }
            if quarter { ev.flags = [.maskShift, .maskAlternate] }
            ev.post(tap: .cghidEventTap)
        }
    }
    static func steps(_ now: Double, _ target: Double, _ budget: Int = BUDGET) -> Int {
        let diff = target - now
        if abs(diff) < DEAD { return 0 }
        let n = min(max(1, Int((abs(diff) / STEP + 0.5).rounded(.down))), budget)
        return diff > 0 ? n : -n
    }
    // a step toward where the knob is; called again by the throttle until it arrives
    @discardableResult static func toward(_ target: Int) -> Int {
        guard let now = level() else { return 0 }
        let n = steps(now, Double(target))
        if n == 0 { return 0 }
        for _ in 0..<abs(n) { key(n > 0 ? 0 : 1, quarter: true) }
        if n > 0 && muted() { key(7, quarter: false) }
        return n
    }
}

// MARK: UNDO, REDO and the ticks (tablekeep.lua)

final class KSKeep {
    private var undo: [([KSRow], String)] = [], redo: [([KSRow], String)] = []
    private(set) var ticks = Set<Int>()
    let get: () -> [KSRow], put: ([KSRow]) -> Void
    init(get: @escaping () -> [KSRow], put: @escaping ([KSRow]) -> Void) { self.get = get; self.put = put }
    private func prune() { let live = Set(get().map(\.id)); ticks = ticks.intersection(live) }
    func change(_ what: String, _ fn: () -> Void) {
        let before = get(); fn()
        if get() != before { undo.append((before, what)); if undo.count > 100 { undo.removeFirst() }; redo = [] }
        prune()
    }
    func doUndo() -> String? { guard let s = undo.popLast() else { return nil }; redo.append((get(), s.1)); put(s.0); prune(); return s.1 }
    func doRedo() -> String? { guard let s = redo.popLast() else { return nil }; undo.append((get(), s.1)); put(s.0); prune(); return s.1 }
    func tick(_ id: Int) { if ticks.contains(id) { ticks.remove(id) } else { ticks.insert(id) }; prune() }
    func all() { let ids = Set(get().map(\.id)); ticks = (ticks == ids && !ids.isEmpty) ? [] : ids }
    func ticked() -> [Int] { get().map(\.id).filter { ticks.contains($0) } }
    var canUndo: Bool { !undo.isEmpty }; var canRedo: Bool { !redo.isEmpty }
    var undoWhat: String { undo.last?.1 ?? "" }; var redoWhat: String { redo.last?.1 ?? "" }
}

// MARK: the OXI E16's rings (e16led.lua): the scene file says which knob, USB3 lights it

final class KSE16 {
    static let PALETTE: [UInt32] = [
        0x9D61FF, 0x8F60FF, 0x8960FF, 0x7D60FF, 0x745FFF, 0x675FFF, 0x5B59FF, 0x4D51FF, 0x3F4BFF, 0x454FFF,
        0x4653FF, 0x4C57FF, 0x4B58FF, 0x4F5CFF, 0x5663FF, 0x5A67FF, 0x647BFF, 0x6D8FFF, 0x759EFF, 0x7FAFFF,
        0x87B0FF, 0x90B3FF, 0x97B5FF, 0x9EB6FF, 0xA4B1FF, 0xACB0FF, 0xB8B3FF, 0xC5B9FF, 0xD1BFFF, 0xDAC4FF,
        0xD2B6FF, 0xC8A7FF, 0xDAC4FF, 0xECE1FF, 0xFFFEFF, 0xFFEAF8, 0xFFDCD2, 0xF5FDBC, 0xE8FCB7, 0xD7FCB0,
        0xDEFC9F, 0xEBFB8E, 0xF3FC8C, 0xF9FC8C, 0xFEFA89, 0xF5FDDC, 0xB8F9FF, 0xFFEDFF, 0xFFC9FF, 0xFFBAF7,
        0xFFAAEE, 0xFF99E2, 0xFF89D1, 0xFF8DC1, 0xFF91B2, 0xFF78AF, 0xFF61AE, 0xFF3420, 0xFF3420, 0xFF3420,
        0xFF3420, 0xFF3420, 0xFF3420, 0xFF3420, 0xFF59B9, 0xFF59B9, 0xFF59B9, 0xFF5AD5, 0xFF5AEF, 0xFF5CFF,
        0xF55BFF, 0xE76CFF, 0xDE7CFF, 0xD78FFF, 0xB885FF, 0x937BFF, 0x92ACFF, 0x5695FF, 0x0D8DFF, 0x0A97FF,
        0x05A1FF, 0x00AFFF, 0x00BAFF, 0x00CAFF, 0x00DFFF, 0x00F1FF, 0x00FCEB, 0x00E9C1, 0x00D596, 0x00DE95,
        0x00E58E, 0x00E894, 0x00ED9E, 0x00F2A5, 0x00F3AB, 0x00F6B4, 0x00FABB, 0x00EDB9, 0x00DFB1, 0x00D4AE]
    struct Knob { var page: Int; var knob: Int; var cc: Int; var ch: Int; var turn: Int; var abs: Bool; var push: Bool
                  var colour: UInt32?; var index: Int; var name: String; var guessed = false }
    struct About { var can: Bool; var colour: UInt32?; var index: Int; var knob: String; var says: String }

    var path: String?; var scene: [String: Any]?; var mtime = Date.distantPast; var looked = Date.distantPast; var walked = Date.distantPast
    var turned: [String: Int] = [:]; var knobAt: [Int: (at: Date, value: Int, ch: Int)] = [:]; var sent: [String: Int] = [:]
    var send: (Int, Int, Int) -> Bool = { _, _, _ in false }     // cc, value, channel 0-15 -> sent on USB3

    private func walk() -> String? {
        var best: String?, bestAt = Date.distantPast
        func scan(_ dir: String, _ depth: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for f in items where !f.hasPrefix(".") {
                let full = dir + "/" + f
                let a = try? FileManager.default.attributesOfItem(atPath: full)
                if f.hasSuffix(".oxie16") { if let m = a?[.modificationDate] as? Date, m > bestAt { best = full; bestAt = m } }
                else if depth > 0, (a?[.type] as? FileAttributeType) == .typeDirectory { scan(full, depth - 1) }
            }
        }
        scan(NSHomeDirectory() + "/Documents", 2)
        return best
    }
    func readScene() -> [String: Any]? {
        let now = Date()
        if now.timeIntervalSince(walked) >= 30 || path == nil { path = walk(); walked = now }
        if let p = path, now.timeIntervalSince(looked) >= 2 {
            looked = now
            let at = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
            if at != mtime || scene == nil,
               let d = try? Data(contentsOf: URL(fileURLWithPath: p)), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                scene = j; mtime = at
            }
        }
        return scene
    }
    static func n(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? Int) }

    // the knob behind a row: a CC row is the knob that TURNS on it, a note row the knob whose PUSH sends it
    func knobFor(_ from: String, _ number: Int, _ channel: Int? = nil) -> Knob? {
        guard let pages = readScene()?["pages"] as? [[String: Any]] else { return nil }
        var first: Knob?
        for (p, page) in pages.enumerated() {
            let pch = (KSE16.n(page["channel"]) ?? 1) - 1
            for (k, enc) in ((page["encoders"] as? [[String: Any]]) ?? []).enumerated() {
                let t = ((enc["turn_actions"] as? [[String: Any]]) ?? []).first ?? [:]
                let push = (enc["push_action"] as? [String: Any]) ?? [:]
                let tType = KSE16.n(t["type"]) ?? 0, tNr = KSE16.n(t["nr1"])
                let tch = (KSE16.n(t["channel"]) ?? 0) == 0 ? pch : KSE16.n(t["channel"])! - 1
                let pchn = (KSE16.n(push["channel"]) ?? 0) == 0 ? pch : KSE16.n(push["channel"])! - 1
                let turnHit = tType >= 1 && tType <= 4 && tNr == number
                var hit = false, ch = tch
                if from == "note" { hit = KSE16.n(push["type"]) == 1 && KSE16.n(push["nr1"]) == number; ch = pchn }
                else if turnHit { hit = true; ch = tch }
                else if KSE16.n(push["type"]) == 2 && KSE16.n(push["nr1"]) == number { hit = true; ch = pchn }
                if hit {
                    let idx = KSE16.n(enc["color"]) ?? 0
                    let kn = Knob(page: p + 1, knob: k + 1, cc: tNr ?? (k + 1), ch: tch, turn: tType, abs: tType == 3,
                                  push: from == "note" || !turnHit, colour: (0..<100).contains(idx) ? KSE16.PALETTE[idx] : nil,
                                  index: idx, name: (enc["abbr"] as? String) ?? "")
                    if channel == nil || ch == channel { return kn }
                    if first == nil { first = kn }
                }
            }
        }
        return first
    }
    // NOTE n (1-16) falls back to knob n, the E16's default layout (Marko, 1.10.2026)
    func knobOrGuess(_ from: String, _ number: Int, _ channel: Int? = nil) -> Knob? {
        if let k = knobFor(from, number, channel) { return k }
        if from == "note" && (1...16).contains(number) {
            return Knob(page: 0, knob: number, cc: number, ch: channel ?? 0, turn: 3, abs: true, push: true, colour: nil, index: -1, name: "", guessed: true)
        }
        return nil
    }

    // a message from the locked device: a note row with its LED ticked lights its knob while down,
    // and the release puts the knob's own turned value back
    func feel(_ rows: [KSRow], _ from: String, _ number: Int, _ value: Int, _ channel: Int) -> String? {
        if from == "cc" {
            knobAt[number] = (Date(), value, channel)
            if let k = knobFor("cc", number, channel), !k.push { turned["\(k.cc):\(channel)"] = value }
        }
        for r in rows where r.led && r.on && KSRules.type(r.type) == from && r.cc == number {
            guard let k = knobOrGuess(from, number, channel), k.push else { continue }
            let back = turned["\(k.cc):\(channel)"] ?? 0
            let v = value > 0 ? 127 : back
            let ok = send(k.cc, v, channel)
            if value == 0 { sent = [:] }
            return "LED: knob \(k.knob) \(k.guessed ? "(by the default layout)" : "on page \(k.page)") " +
                (value > 0 ? "lit" : (back > 0 ? "back to its value" : "dark")) + "  (CC \(k.cc) = \(v) on USB3, ch \(channel + 1))" +
                (ok ? "" : "  \u{2014} NOT SENT: the E16's USB3 is not there")
        }
        return nil
    }
    // a volume row's ring shows the Mac's volume, also when it changes from the keyboard
    func follow(_ rows: [KSRow]) {
        guard let lvl = KSVolume.level() else { return }
        let val = Int((lvl * 127 / 100 + 0.5).rounded(.down))
        for r in rows where r.led && r.on && r.kind == "volume" && KSRules.type(r.type) == "cc" {
            guard let k = knobFor("cc", r.cc, knobAt[r.cc]?.ch), k.abs, !k.push else { continue }
            let key = "\(k.page):\(k.knob)"
            if let hand = knobAt[k.cc], Date().timeIntervalSince(hand.at) < 1 { sent[key] = val }
            else if sent[key] != val, send(k.cc, val, k.ch) { sent[key] = val }
        }
    }
    func about(_ from: String, _ number: Int, _ isVolume: Bool) -> About {
        let what = (from == "note" ? "NOTE " : "CC ") + "\(number)"
        guard let k = knobFor(from, number) else {
            if let g = knobOrGuess(from, number) {
                return About(can: true, colour: nil, index: -1, knob: "", says: "no saved scene sends \(what), so it lights knob \(g.knob) through CC \(g.cc), the E16's default layout, while it is held")
            }
            return About(can: false, colour: nil, index: -1, knob: "", says: "no knob in the E16's scene sends \(what): nothing to light")
        }
        let where_ = "knob \(k.knob)" + (k.name.isEmpty ? "" : " (\(k.name))") + " on page \(k.page)"
        func a(_ can: Bool, _ s: String) -> About { About(can: can, colour: k.colour, index: k.index, knob: where_, says: s) }
        if k.push {
            var s = where_ + " lights in its scene colour while \(what) is held"
            if k.turn == 0 { s += " \u{2014} but its TURN is Off in the scene: set it to CC Abs in the OXI App, or the ring stays dark" }
            else if k.turn != 3 { s += " \u{2014} its TURN is relative in the scene, and a relative ring may not light" }
            return a(true, s)
        }
        if !k.abs { return a(false, where_ + " is relative: its ring has no value to show") }
        if isVolume { return a(true, where_ + ": the ring follows the Mac's volume, also from the keyboard") }
        return a(false, where_ + " already shows its own value: nothing comes back to it from here")
    }
    // the colour is kept in the scene (e16colour.py; he sends the scene to the E16 from the OXI App)
    func setColour(_ from: String, _ number: Int, _ index: Int) -> String {
        guard (0...99).contains(index) else { return "a colour is a number from 0 to 99" }
        guard let k = knobFor(from, number), let p = path else { return "no knob in the E16's scene answers this row: nothing to colour" }
        let helper = Bundle.main.path(forResource: "midikeys_e16colour", ofType: "py", inDirectory: "helpers")
            ?? NSHomeDirectory() + "/Developer/MANTRA_MIDI_TOOLS/helpers/midikeys_e16colour.py"
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [helper, p, "\(k.page)", "\(k.knob)", "\(index)"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        do { try proc.run() } catch { return "the scene was not changed: \(error)" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        proc.waitUntilExit()
        mtime = .distantPast; looked = .distantPast
        if proc.terminationStatus != 0 { return "the scene was not changed: " + out }
        let name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        return "knob \(k.knob) on page \(k.page) of \(name) is now colour \(index) (it was \(out)): send the scene to the E16 from the OXI App"
    }
}

// MARK: the engine

final class KSEngine: ObservableObject {
    struct Heard { var line: String; var mine: Bool; var at: Date }
    struct Incoming { var port: String; var text: String; var count: Int; var at: Date }

    @Published var on = true
    @Published var device = ""
    @Published var rows: [KSRow] = []
    @Published var detect = false
    @Published var learnId: Int?
    @Published var capId: Int?
    @Published var heard: Heard?
    @Published var trace: [String] = []            // newest LAST, shown newest first
    @Published var incoming: [Incoming] = []
    @Published var listening: [String] = []
    @Published var lit: [Int: String] = [:]         // row id -> "fire" / "heard"
    @Published var trusted = AXIsProcessTrusted()
    @Published var tick = 0                          // bumped twice a second so "s ago" moves
    var blob = true                                  // the Mac's own volume blob (conf.blob)
    var running = false
    var dry = false                                  // a test run: listens and shows, presses nothing, sends nothing
    lazy var keep = KSKeep(get: { [unowned self] in self.rows }, put: { [unowned self] in self.rows = $0 })
    let e16 = KSE16()

    private var client = MIDIClientRef(0), inPort = MIDIPortRef(0), outPort = MIDIPortRef(0)
    private var sources: [(name: String, ep: MIDIEndpointRef)] = []
    private var labels: [String: String] = [:]
    private var actAt: [Int: Date] = [:], actHow: [Int: String] = [:], actHeld = Set<Int>()
    private var timers: [Timer] = []
    private var capTap: CFMachPort?, capSource: CFRunLoopSource?, capStop: DispatchWorkItem?
    private var volWant: Int?, volAt = Date.distantPast, volLast: Int?, volPending = false
    private var lastSourcesKey = ""

    init() {
        load()
        e16.send = { [weak self] cc, v, ch in self?.sendCC(cc, v, ch) ?? false }
    }

    // MARK: the settings file

    func load() {
        let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: KS_CONF))) as? [String: Any] ?? [:]
        on = (d["on"] as? Bool) ?? true
        device = (d["device"] as? String) ?? ""
        blob = (d["blob"] as? Bool) ?? true
        rows = ((d["rows"] as? [[String: Any]]) ?? []).compactMap { KSRules.clean($0).0 }   // a row the file cannot mean is dropped
    }
    func save() {
        guard !dry else { return }
        var d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: KS_CONF))) as? [String: Any] ?? [:]
        d["on"] = on; d["device"] = device; d["rows"] = rows.map(\.dict)
        try? FileManager.default.createDirectory(at: KS_CONF.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: KS_CONF, options: .atomic)
    }
    func row(_ id: Int?) -> KSRow? { rows.first { $0.id == id } }

    // MARK: start, stop

    func start() {
        guard !running else { return }
        running = true
        load()
        // v16: never a request at login (--login); the PERMISSIONS word waits in the window
        if !dry && !CommandLine.arguments.contains("--login") { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        midiStart()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.trusted = AXIsProcessTrusted() },
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.tick &+= 1
                if self.on && !self.dry { self.e16.follow(self.rows) }
            },
            Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.refreshLit() },
            // a look every three seconds: a source plugged in or gone (midiwatch.lua)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkSources() },
        ]
    }
    func stop() {
        guard running else { return }
        running = false
        captureStop()
        timers.forEach { $0.invalidate() }; timers = []
        midiStop()
        detect = false; learnId = nil
    }

    // MARK: MIDI in

    private func name(_ o: MIDIObjectRef) -> String {
        var u: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(o, kMIDIPropertyName, &u)
        return (u?.takeRetainedValue() as String?) ?? ""
    }
    private func sourcesKey() -> String { (0..<MIDIGetNumberOfSources()).map { name(MIDIGetSource($0)) }.sorted().joined(separator: "\n") }

    func label(_ n: String) -> String {
        if let l = labels[n] { return l }
        guard let his = KS_PORT_NAME[n] else { labels[n] = n; return n }
        if !n.hasPrefix("Port ") { labels[n] = his; return his }
        // USB1-3 are one controller's three streams: name the controller when there is only one
        var mine: [String] = []
        for i in 0..<MIDIGetNumberOfDevices() {
            let d = MIDIGetDevice(i); let dn = name(d)
            var off: Int32 = 0; MIDIObjectGetIntegerProperty(d, kMIDIPropertyOffline, &off)
            if off == 0 && !["Network", "IAC Driver", "Bluetooth"].contains(dn) && !dn.isEmpty { mine.append(dn) }
        }
        let l = mine.count == 1 ? his + " (\(mine[0]))" : his
        labels[n] = l; return l
    }

    func midiStart() {
        midiStop()
        if client == 0 {
            MIDIClientCreateWithBlock("MIDI Tools (Mantra): MIDI to Key Stroke" as CFString, &client) { [weak self] note in
                if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.checkSources() } }
            }
            MIDIOutputPortCreate(client, "MIDI to Key Stroke out" as CFString, &outPort)
            MIDIInputPortCreateWithProtocol(client, "MIDI to Key Stroke in" as CFString, ._1_0, &inPort) { [weak self] list, ref in
                guard let self = self else { return }
                let idx = Int(bitPattern: ref) - 1
                var msgs: [(UInt32)] = []
                for pkt in list.unsafeSequence() {
                    let n = Int(pkt.pointee.wordCount)
                    withUnsafeBytes(of: pkt.pointee.words) { raw in
                        let w = raw.bindMemory(to: UInt32.self)
                        var i = 0
                        while i < n {
                            let mt = w[i] >> 28
                            if mt == 1 || mt == 2 { msgs.append(w[i]) }
                            i += [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(mt)]
                        }
                    }
                }
                DispatchQueue.main.async { for m in msgs { self.arrived(idx, m) } }
            }
        }
        labels = [:]
        sources = []
        for i in 0..<MIDIGetNumberOfSources() {
            let ep = MIDIGetSource(i); let n = name(ep)
            guard !n.isEmpty, !sources.contains(where: { $0.name == n }) else { continue }
            sources.append((n, ep))
            MIDIPortConnectSource(inPort, ep, UnsafeMutableRawPointer(bitPattern: sources.count))
        }
        listening = sources.map { label($0.name) }
        lastSourcesKey = sourcesKey()
    }
    func midiStop() {
        for s in sources { MIDIPortDisconnectSource(inPort, s.ep) }
        sources = []; listening = []
    }
    // ONLY IF THE SOURCES REALLY CHANGED (LESSONS 3): CoreMIDI says "changed" for every client anywhere
    func checkSources() {
        guard running else { return }
        let k = sourcesKey()
        if k != lastSourcesKey { lastSourcesKey = k; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.running { self.midiStart() } } }
    }

    private static let SYS: [UInt32: String] = [0xFA: "START", 0xFB: "CONTINUE", 0xFC: "STOP", 0xF2: "SONG POSITION",
                                                 0xF0: "SYSEX", 0xF3: "SONG SELECT", 0xF6: "TUNE REQUEST", 0xFF: "RESET"]
    private static let QUIET: Set<UInt32> = [0xF8, 0xFE, 0xF1]      // the beat clock and its kind: never shown

    func arrived(_ idx: Int, _ w: UInt32) {
        guard idx >= 0, idx < sources.count else { return }
        let src = sources[idx].name, lab = label(src)
        let status = (w >> 16) & 0xFF, d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
        if (w >> 28) == 1 {                                       // system
            if KSEngine.QUIET.contains(status) { return }
            let t = KSEngine.SYS[status] ?? String(format: "SYSTEM %02x", status)
            monitor(lab, t)
            heard = Heard(line: lab + "   " + t, mine: device != "" && device == src, at: Date())
            return
        }
        let kind = status & 0xF0, ch = Int(status & 0x0F)
        var text = ""
        switch kind {
        case 0xB0: text = "CC \(d1) = \(d2)   ch \(ch + 1)"
        case 0x90: text = d2 == 0 ? "NOTE \(d1) off   ch \(ch + 1)" : "NOTE \(d1) = \(d2)   ch \(ch + 1)"
        case 0x80: text = "NOTE \(d1) off   ch \(ch + 1)"
        case 0xE0: text = "PITCH BEND \((d2 << 7) | d1)   ch \(ch + 1)"
        case 0xC0: text = "PROGRAM \(d1)   ch \(ch + 1)"
        case 0xD0: text = "PRESSURE \(d1)   ch \(ch + 1)"
        case 0xA0: text = "NOTE \(d1) PRESSURE \(d2)   ch \(ch + 1)"
        default: return
        }
        monitor(lab, text)
        if kind == 0xB0 { control(src, d1, d2, ch, "cc") }
        else if kind == 0x90 || kind == 0x80 { control(src, d1, kind == 0x80 ? 0 : d2, ch, "note") }
        else { heard = Heard(line: lab + "   " + text, mine: device != "" && device == src, at: Date()) }
    }

    // the incoming monitor: four lines, a repeat counts up instead of pushing the others out
    private func monitor(_ port: String, _ text: String) {
        if var top = incoming.first, top.port == port, top.text == text { top.count += 1; top.at = Date(); incoming[0] = top; return }
        incoming.insert(Incoming(port: port, text: text, count: 1, at: Date()), at: 0)
        if incoming.count > 4 { incoming.removeLast() }
    }

    func note(_ line: String, collapse: String? = nil) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let t = f.string(from: Date()) + "  " + line
        if let c = collapse, let last = trace.last, last.range(of: c, options: .regularExpression) != nil { trace[trace.count - 1] = t }
        else { trace.append(t) }
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }

    // MARK: a message arrives (onControl)

    func control(_ src: String, _ n: Int, _ v: Int, _ ch: Int, _ typ: String) {
        let what = (KSRules.TYPES[typ] ?? "CC") + " \(n)"
        let mine = device != "" && device == src
        heard = Heard(line: "\(label(src))   \(what) = \(v)   ch \(ch + 1)", mine: mine, at: Date())
        let release = typ == "note" && v == 0           // a release teaches nothing
        if detect && !release {
            detect = false; device = src; save()
            note("locked to \(label(src))  (\(what) spoke first)")
            return
        }
        if let lid = learnId, !release {
            guard let r = row(lid) else { learnId = nil; return }
            if KSRules.type(r.type) != typ {
                note("LEARN on row \(r.id) takes \(KSRules.type(r.type) == "note" ? "a NOTE" : "a CC") only: \(what) let pass", collapse: "let pass")
                return
            }
            learnId = nil
            var d = r.dict; d["cc"] = n
            if typ == "note" { d["value"] = "any" } else if KSRules.SPECIALS[r.kind]?.sweep != true { d["value"] = v }
            if let c = replace("row \(r.id) learned \(what)", r, d) { save(); note("row \(r.id) learned \(what) = \(KSRules.valueText(c))") }
            return
        }
        if learnId != nil || detect { return }
        if mine {                                        // the activity LED: green fires, amber heard
            for r in rows where KSRules.type(r.type) == typ && r.cc == n {
                if release { actHeld.remove(r.id) }
                else if r.value == nil || r.value == KSRules.value(v) {
                    actAt[r.id] = Date(); actHow[r.id] = (on && capId == nil && KSRules.matches(r, n, v, typ)) ? "fire" : "heard"
                    if typ == "note" { actHeld.insert(r.id) } else { actHeld.remove(r.id) }
                }
            }
        }
        guard on, device != "", mine else { return }
        if !dry, let l = e16.feel(rows, typ, n, v, ch) { note(l) }
        if capId != nil { return }                       // a key is being captured: press nothing
        for act in KSRules.fire(rows, n, v, typ) {
            switch act {
            case .key(let k, let mods, _):
                postKey(k, mods)
                note("\(label(src))   \(what) = \(v)   \u{2192}   \(KSRules.chord(mods, k))" + (dry ? "  (dry: not pressed)" : ""))
            case .volume(let pct, _):
                let ok = setVolume(pct)
                note("\(label(src))   \(what) = \(v)   \u{2192}   volume \(pct)%" + (ok ? "" : "  \u{2014} the Mac has no output device") + (dry ? "  (dry)" : ""),
                     collapse: NSRegularExpression.escapedPattern(for: what) + " = \\d+.*\u{2192}")
            }
        }
    }

    private func refreshLit() {
        let now = Date(); var out: [Int: String] = [:]
        for (id, t) in actAt {
            let age = now.timeIntervalSince(t)
            if age < 0.3 || (actHeld.contains(id) && age < 20) { out[id] = actHow[id] }
            else if age > 20 { actAt[id] = nil; actHow[id] = nil; actHeld.remove(id) }
        }
        if out != lit { lit = out }
    }

    // MARK: the two things a row does

    func postKey(_ name: String, _ mods: [String]) {
        guard !dry, let code = KS_KEYS[name] else { if KS_KEYS[name] == nil { note("no key code for \"\(name)\"") }; return }
        guard AXIsProcessTrusted() else { note("not pressed: Accessibility is not allowed for MIDI Tools (Mantra) yet"); return }
        let f = ksFlags(mods)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); e?.flags = f; e?.post(tap: .cghidEventTap)
        }
    }
    // THROTTLED to every 60 ms with a trailing apply, so the place he leaves the knob is where it lands (LESSONS 1)
    func setVolume(_ pct: Int) -> Bool {
        guard KSVolume.device() != nil else { return false }
        if dry { return true }
        volWant = pct
        let due = volAt.timeIntervalSinceNow + 0.06
        if due <= 0 { applyVolume() }
        else if !volPending { volPending = true; DispatchQueue.main.asyncAfter(deadline: .now() + due) { self.volPending = false; self.applyVolume() } }
        return true
    }
    private func applyVolume() {
        guard let pct = volWant else { return }
        volWant = nil; volAt = Date()
        if blob { KSVolume.toward(pct); volLast = nil; return }       // the Mac's own keys, the Mac's own blob
        if volLast == pct { return }
        KSVolume.set(pct); volLast = pct
    }
    // the LED's CC goes to the E16 on USB3 ("Port 3"): on USB1 it only flashes (oxi-e16.md section 10)
    func sendCC(_ cc: Int, _ v: Int, _ ch: Int) -> Bool {
        guard !dry else { return false }
        guard let dest = (0..<MIDIGetNumberOfDestinations()).map({ MIDIGetDestination($0) }).first(where: { name($0) == "Port 3" }) else { return false }
        var list = MIDIEventList()
        let pkt = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2000_0000) | (UInt32(0xB0 | (ch & 0x0F)) << 16) | (UInt32(cc & 0x7F) << 8) | UInt32(v & 0x7F)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &word)
        return MIDISendEventList(outPort, dest, &list) == noErr
    }

    // MARK: capturing a key: the NEXT key anywhere is taken and swallowed; Escape leaves it; 15 s gives up

    func captureStop() {
        if let t = capTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = capSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        capTap = nil; capSource = nil; capStop?.cancel(); capStop = nil; capId = nil
    }
    func captureStart(_ id: Int) {
        captureStop()
        guard row(id) != nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, ev, ref in
            let eng = Unmanaged<KSEngine>.fromOpaque(ref!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(ev) }
            let code = CGKeyCode(ev.getIntegerValueField(.keyboardEventKeycode)), flags = ev.flags
            DispatchQueue.main.async { eng.captured(code, flags) }
            return nil                                   // swallowed: the key he pressed does nothing else
        }, userInfo: me) else { note("the key cannot be captured: allow Accessibility for MIDI Tools (Mantra)"); return }
        capSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), capSource, .commonModes); CGEvent.tapEnable(tap: t, enable: true)
        capTap = t; capId = id
        let job = DispatchWorkItem { [weak self] in if self?.capId != nil { self?.captureStop(); self?.note("nothing was pressed: the key was left as it was") } }
        capStop = job; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: job)
    }
    private func captured(_ code: CGKeyCode, _ flags: CGEventFlags) {
        guard let id = capId else { return }
        captureStop()
        guard let key = KS_KEYNAMES[code] else { note("that key has no name I know"); return }
        if key == "escape" { note("the key was left as it was"); return }
        guard let r = row(id) else { return }
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("cmd") }; if flags.contains(.maskAlternate) { mods.append("alt") }
        if flags.contains(.maskShift) { mods.append("shift") }; if flags.contains(.maskControl) { mods.append("ctrl") }
        if flags.contains(.maskSecondaryFn) && !(122...126).contains(Int(code)) && !(96...122).contains(Int(code)) { mods.append("fn") }
        var d = r.dict; d["key"] = key; d["mods"] = mods; d["kind"] = "key"
        replace("row \(r.id): key \(KSRules.chord(mods, key))", r, d)
        save(); note("row \(r.id) took the key \(KSRules.chord(mods, key))")
    }

    // MARK: the verbs (midikeys.lua do_), one UNDO step each

    @discardableResult func replace(_ what: String, _ r: KSRow, _ d: [String: Any]) -> KSRow? {
        let (c, why) = KSRules.clean(d)
        guard let cleaned = c else { note("that row was refused: " + why); return nil }
        keep.change(what) { if let i = rows.firstIndex(where: { $0.id == r.id }) { rows[i] = cleaned } }
        return cleaned
    }
    func power() { on.toggle(); save() }
    func toggleDetect() { detect.toggle(); if detect { learnId = nil; captureStop() } }
    func unlock() { device = ""; save(); note("the device was unlocked") }
    func learn(_ id: Int) { if learnId == id { learnId = nil } else { learnId = id; detect = false; captureStop() } }
    func capture(_ id: Int) { if capId == id { captureStop() } else { detect = false; learnId = nil; captureStart(id) } }
    func add() {
        let (r, _) = KSRules.clean(["id": KSRules.nextId(rows), "cc": 1, "kind": "key"])
        guard let row = r else { return }
        keep.change("row \(row.id) added") { rows.append(row) }; save()
    }
    func deleteTicked() {
        let gone = Set(keep.ticked()); guard !gone.isEmpty else { return }
        let ids = rows.filter { gone.contains($0.id) }.map { "\($0.id)" }
        keep.change((ids.count == 1 ? "row " : "rows ") + ids.joined(separator: ", ") + " deleted") {
            for r in rows where gone.contains(r.id) { note("row \(r.id) removed  (\(KSRules.midiText(r)) = \(KSRules.valueText(r)) \u{2192} \(KSRules.target(r)))") }
            rows.removeAll { gone.contains($0.id) }
        }
        if let c = capId, gone.contains(c) { captureStop() }
        if let l = learnId, gone.contains(l) { learnId = nil }
        save()
    }
    func undoRedo(_ undo: Bool) {
        guard let what = undo ? keep.doUndo() : keep.doRedo() else { return }
        if let c = capId, row(c) == nil { captureStop() }
        if let l = learnId, row(l) == nil { learnId = nil }
        save(); note((undo ? "UNDO: " : "REDO: ") + what); objectWillChange.send()
    }
    // a cell of a row changed: "type", "number", "value", "kind", "key", "on", "led"
    func set(_ id: Int, _ field: String, _ v: Any) {
        guard let r = row(id) else { return }
        var d = r.dict
        switch field {
        case "number": d["cc"] = v
        case "value": d["value"] = KSRules.isAny(v) ? nil : v
        case "key": if "\(v)".isEmpty { d["key"] = nil; d["mods"] = [] } else { d["key"] = v }
        default: d[field] = v
        }
        let shown = field == "key" && "\(v)".isEmpty ? "forgotten" : "\(v)"
        if replace("row \(id): \(field == "type" ? "filter" : field) \(shown)", r, d) != nil { save() }
    }
    func colour(_ id: Int, _ index: Int) { guard let r = row(id) else { return }; note(e16.setColour(KSRules.type(r.type), r.cc, index)) }

    // WHY NOTHING HAPPENS, said out loud
    var why: (String, Bool) {
        if listening.isEmpty { return ("no MIDI source is open \u{2014} is the device plugged in?", true) }
        if !on { return ("the switch is OFF: nothing is sent", false) }
        if device.isEmpty { return ("no device is locked: press DETECT DEVICE and turn a knob", false) }
        if rows.isEmpty { return ("the table is empty: press + A ROW", false) }
        return ("listening on " + listening.joined(separator: ", "), false)
    }
    static func ago(_ d: Date) -> String {
        let n = Date().timeIntervalSince(d)
        if n < 2 { return "just now" }; if n < 60 { return "\(Int(n)) s ago" }
        if n < 3600 { return "\(Int(n / 60)) min ago" }; return "\(Int(n / 3600)) h ago"
    }
}
