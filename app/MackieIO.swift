// MIDI TO MK CONTROL, part 3: the wires. CoreMIDI in and out (was hs.midi), whether Live is playing (was live.lua),
// the Mac's own volume and its blob (was ~/.local/lib/mantra/volume.lua), and the E16's rings (was e16led.lua).
// Ported 13.10.2026. Every name here starts with MK so nothing collides with the other modules' own copies.
import Foundation
import CoreMIDI
import AppKit
import AudioToolbox

// MARK: - CoreMIDI

func mkName(_ obj: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(obj, kMIDIPropertyName, &s) == noErr, let v = s?.takeRetainedValue() else { return "" }
    return v as String
}
func mkOffline(_ obj: MIDIObjectRef) -> Bool {
    var v: Int32 = 0
    return MIDIObjectGetIntegerProperty(obj, kMIDIPropertyOffline, &v) == noErr && v != 0
}
// the device an endpoint belongs to, by name ("IAC Driver", "OXI E16"); a virtual endpoint has none
func mkDeviceName(_ ep: MIDIEndpointRef) -> String {
    var ent: MIDIEntityRef = 0, dev: MIDIDeviceRef = 0
    guard MIDIEndpointGetEntity(ep, &ent) == noErr, MIDIEntityGetDevice(ent, &dev) == noErr else { return "" }
    return mkName(dev)
}
func mkSources() -> [(name: String, ref: MIDIEndpointRef)] {
    (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter { !mkOffline($0) }.map { (mkName($0), $0) }
}
func mkDestinations() -> [(name: String, device: String, ref: MIDIEndpointRef)] {
    (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter { !mkOffline($0) }.map { (mkName($0), mkDeviceName($0), $0) }
}
// what hs.midi.devices() listed: the online devices, by name
func mkDevices() -> [String] {
    (0..<MIDIGetNumberOfDevices()).map { MIDIGetDevice($0) }.filter { !mkOffline($0) }.map(mkName).filter { !$0.isEmpty }
}

// one decoded MIDI 1.0 message out of a Universal MIDI Packet word
struct MKRaw { var status: Int; var d1: Int; var d2: Int; var system: Bool }

final class MKMidi {
    var client = MIDIClientRef()
    var inPort = MIDIPortRef()
    var outPort = MIDIPortRef()
    var names: [String] = []                 // the connected sources, indexed by refCon - 1
    var refs: [MIDIEndpointRef] = []
    var onMessage: ((String, MKRaw) -> Void)?
    var onSetup: (() -> Void)?

    func start() {
        guard client == 0 else { return }
        MIDIClientCreateWithBlock("MIDI Tools (Mantra) · MK Control" as CFString, &client) { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.onSetup?() } }
        }
        MIDIInputPortCreateWithProtocol(client, "MK in" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
            guard let self = self else { return }
            let i = Int(bitPattern: refCon) - 1
            let name = (i >= 0 && i < self.names.count) ? self.names[i] : ""
            var got: [MKRaw] = []
            for p in list.unsafeSequence() {
                let n = Int(p.pointee.wordCount)
                withUnsafePointer(to: p.pointee.words) { tp in
                    tp.withMemoryRebound(to: UInt32.self, capacity: 64) { w in
                        var k = 0
                        while k < n {
                            let word = w[k], type = Int(word >> 28)
                            let st = Int((word >> 16) & 0xFF), d1 = Int((word >> 8) & 0x7F), d2 = Int(word & 0x7F)
                            if type == 2 { got.append(MKRaw(status: st, d1: d1, d2: d2, system: false)) }
                            else if type == 1 { got.append(MKRaw(status: st, d1: d1, d2: d2, system: true)) }
                            else if type == 3 { got.append(MKRaw(status: 0xF0, d1: 0, d2: 0, system: true)) }
                            let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
                            k += size
                        }
                    }
                }
            }
            if got.isEmpty { return }
            DispatchQueue.main.async { for m in got { self.onMessage?(name, m) } }
        }
        MIDIOutputPortCreate(client, "MK out" as CFString, &outPort)
    }
    // SOURCES ONLY, every one of them (the E16 is one device and THREE sources, USB1-3; MANTRA_MANIFEST oxi-e16.md)
    func openAll() -> Int {
        closeAll()
        for (name, ref) in mkSources() {
            names.append(name); refs.append(ref)
            MIDIPortConnectSource(inPort, ref, UnsafeMutableRawPointer(bitPattern: names.count))
        }
        return names.count
    }
    func closeAll() {
        for r in refs { MIDIPortDisconnectSource(inPort, r) }
        names = []; refs = []
    }
    func stop() {
        closeAll()
        if client != 0 { MIDIClientDispose(client); client = 0; inPort = 0; outPort = 0 }
    }
    @discardableResult func send(_ dest: MIDIEndpointRef, _ status: Int, _ d1: Int, _ d2: Int) -> Bool {
        guard outPort != 0, dest != 0 else { return false }
        var list = MIDIEventList()
        let pkt = MIDIEventListInit(&list, ._1_0)
        let word = UInt32(0x2000_0000) | UInt32(status & 0xFF) << 16 | UInt32(d1 & 0x7F) << 8 | UInt32(d2 & 0x7F)
        var w = word
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &w)
        return MIDISendEventList(outPort, dest, &list) == noErr
    }
}

// the incoming MIDI monitor's wording (was midiwatch.lua): Live's clock and active sensing are never shown
enum MKWatch {
    static let QUIET: Set<Int> = [0xF8, 0xFE, 0xF1]
    static let SYS = [0xFA: "START", 0xFB: "CONTINUE", 0xFC: "STOP", 0xF2: "SONG POSITION", 0xF0: "SYSEX",
                      0xF3: "SONG SELECT", 0xF6: "TUNE REQUEST", 0xFF: "RESET"]
    static func quiet(_ m: MKRaw) -> Bool { m.system && QUIET.contains(m.status) }
    static func describe(_ m: MKRaw) -> String {
        if m.system { return SYS[m.status] ?? String(format: "SYSTEM %02X", m.status) }
        let ch = "   ch \((m.status & 0x0F) + 1)"
        switch m.status & 0xF0 {
        case 0xB0: return "CC \(m.d1) = \(m.d2)\(ch)"
        case 0x90: return m.d2 == 0 ? "NOTE \(m.d1) off\(ch)" : "NOTE \(m.d1) = \(m.d2)\(ch)"
        case 0x80: return "NOTE \(m.d1) off\(ch)"
        case 0xE0: return "PITCH BEND \(m.d2 * 128 + m.d1)\(ch)"
        case 0xC0: return "PROGRAM \(m.d1)\(ch)"
        case 0xD0: return "PRESSURE \(m.d1)\(ch)"
        case 0xA0: return "NOTE \(m.d1) PRESSURE \(m.d2)\(ch)"
        default: return String(format: "%02X", m.status)
        }
    }
}

func mkAgo(_ t: Date?) -> String {
    guard let t = t else { return "" }
    let n = Date().timeIntervalSince(t)
    if n < 2 { return "just now" }
    if n < 60 { return "\(Int(n)) s ago" }
    if n < 3600 { return "\(Int(n / 60)) min ago" }
    return "\(Int(n / 3600)) h ago"
}

// MARK: - Is Live playing (was live.lua)
// AbletonOSC answers only to UDP 11001 and A1's ears hold that port, so the answer is read out of Live's own Log.txt:
// AbletonOSC logs every is_playing it is asked about. The questions go to 127.0.0.1:11000.
final class MKLive {
    var log: String?
    var pos: UInt64 = 0
    var playing: Bool?
    var at = Date.distantPast
    var timer: Timer?
    let STALE = 15.0, BEAT = 5.0, SEED: UInt64 = 400_000

    func ask(_ address: String) {
        func pad(_ s: String) -> Data { var d = Data(s.utf8); d.append(contentsOf: [UInt8](repeating: 0, count: 4 - d.count % 4)); return d }
        let msg = pad(address) + pad(",")
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return }
        defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(11000).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = msg.withUnsafeBytes { b in withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    }
    func askBoth() { ask("/live/song/start_listen/is_playing"); ask("/live/song/get/is_playing") }
    func logPath() -> String? {
        if let l = log, FileManager.default.fileExists(atPath: l) { return l }
        let dir = NSHomeDirectory() + "/Library/Preferences/Ableton"
        var best: String?, bestAt = Date.distantPast
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("Live ") {
            let p = dir + "/" + f + "/Log.txt"
            if let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m > bestAt { best = p; bestAt = m }
        }
        log = best; pos = 0
        return best
    }
    func scan() {
        guard let p = logPath(), let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? UInt64 else { return }
        if size < pos { pos = 0 }                                   // Live started again: a new file
        if pos == 0 { pos = size > SEED ? size - SEED : 0 }
        if size == pos { return }
        guard let h = FileHandle(forReadingAtPath: p) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: pos)
        let chunk = String(decoding: h.readData(ofLength: Int(size - pos)), as: UTF8.self)
        pos = size
        for line in chunk.split(separator: "\n") {
            for pat in ["Property is_playing changed of song []: (", "Getting property for song: is_playing = "] {
                if let r = line.range(of: pat) {
                    let rest = line[r.upperBound...]
                    if rest.hasPrefix("True") { playing = true; at = Date() } else if rest.hasPrefix("False") { playing = false; at = Date() }
                }
            }
        }
    }
    func start() {
        askBoth()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: BEAT, repeats: true) { [weak self] _ in self?.ask("/live/song/get/is_playing"); self?.scan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan() }
    }
    func stop() { timer?.invalidate(); timer = nil; playing = nil; at = .distantPast; pos = 0; log = nil }
    // nil when Live cannot be asked: no answer, or one older than STALE
    func isPlaying() -> Bool? {
        scan()
        if playing == nil || Date().timeIntervalSince(at) > STALE { askBoth(); return nil }
        return playing
    }
    func expect(_ on: Bool) { playing = on; at = Date() }
    func saysNow() -> Bool? { scan(); return playing }
}

// MARK: - The Mac's own volume, and its blob (was volume.lua)
enum MKMac {
    static let STEP = 1.5, DEAD = 1.1, BUDGET = 8
    // the Mac's own media keys, so macOS moves its volume and puts up its own blob; with ⇧⌥ a quarter step
    static func key(_ code: Int, quarter: Bool) {
        let extra: UInt = quarter ? (NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.option.rawValue) : 0
        for down in [true, false] {
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: (down ? 0xa00 : 0xb00) | extra),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: (code << 16) | ((down ? 0xa : 0xb) << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    static func up(_ quarter: Bool = true) { key(0, quarter: quarter) }        // NX_KEYTYPE_SOUND_UP
    static func down(_ quarter: Bool = true) { key(1, quarter: quarter) }      // NX_KEYTYPE_SOUND_DOWN
    static func mute() { key(7, quarter: false) }                             // NX_KEYTYPE_MUTE

    static func device() -> AudioObjectID? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr ? id : nil
    }
    static var volAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    static var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    static func level() -> Double? {
        guard let d = device() else { return nil }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(d, &volAddr, 0, nil, &size, &v) == noErr ? Double(v) * 100 : nil
    }
    static func muted() -> Bool {
        guard let d = device() else { return false }
        var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &muteAddr, 0, nil, &size, &v) == noErr && v != 0
    }
    static func steps(_ now: Double, _ target: Double, _ budget: Int) -> Int {
        let diff = target - now
        if abs(diff) < DEAD { return 0 }
        let n = min(max(1, Int(abs(diff) / STEP + 0.5)), budget)
        return diff > 0 ? n : -n
    }
    // toward a level with the Mac's own keys, so its blob comes up
    static func toward(_ target: Double) {
        guard let now = level() else { return }
        let n = steps(now, target, BUDGET)
        if n == 0 { return }
        for _ in 0..<abs(n) { key(n > 0 ? 0 : 1, quarter: true) }
        if n > 0 && muted() { mute() }
    }
    // the exact number, behind the Mac's back: no blob
    static func set(_ percent: Double) {
        guard let d = device() else { return }
        var v = Float32(max(0, min(100, percent)) / 100)
        AudioObjectSetPropertyData(d, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if percent > 0 && muted() { var m = UInt32(0); AudioObjectSetPropertyData(d, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) }
    }
}

// MARK: - The E16's rings (was e16led.lua)
// A row's LED tick lights the E16 knob behind it: a pressed note lights its knob's ring while held, a volume row's ring
// follows the Mac's volume. The scene is the newest .oxie16 under ~/Documents; colours are its 100-colour palette, and a
// colour picked here is written into the scene by e16colour.py (then sent to the E16 from the OXI App).
struct MKKnob { var page: Int; var knob: Int; var cc: Int; var ch: Int; var turn: Int; var abs: Bool; var push: Bool; var colour: String; var index: Int; var name: String; var guessed = false }

final class MKLed {
    static let PORT = "Port 3"         // CoreMIDI's name for the E16's USB3
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
        0x00E58E, 0x00E894, 0x00ED9E, 0x00F2A5, 0x00F3AB, 0x00F6B4, 0x00FABB, 0x00EDB9, 0x00DFB1, 0x00D4AE,
    ]
    static func hex(_ i: Int) -> String { (0..<PALETTE.count).contains(i) ? String(format: "#%06X", PALETTE[i]) : "#999999" }

    let midi: MKMidi
    var scene: [String: Any]?
    var path: String?
    var mtime = Date.distantPast
    var looked = Date.distantPast, walked = Date.distantPast
    var knobAt: [Int: (at: Date, value: Int, ch: Int?)] = [:]
    var turned: [String: Int] = [:]
    var sent: [String: Int] = [:]
    var follow: (() -> [Int])?          // the CC numbers of the volume rows whose ring follows the Mac's volume
    var timer: Timer?
    init(midi: MKMidi) { self.midi = midi }

    func walk() -> String? {
        var best: String?, bestAt = Date.distantPast
        func scan(_ dir: String, _ depth: Int) {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !f.hasPrefix(".") {
                let full = dir + "/" + f
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                if f.hasSuffix(".oxie16") {
                    if let m = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date, m > bestAt { best = full; bestAt = m }
                } else if depth > 0 && isDir.boolValue { scan(full, depth - 1) }
            }
        }
        scan(NSHomeDirectory() + "/Documents", 2)
        return best
    }
    func currentScene() -> [String: Any]? {
        let now = Date()
        if now.timeIntervalSince(walked) >= 30 || path == nil { path = walk(); walked = now }
        if let p = path, now.timeIntervalSince(looked) >= 2 {
            looked = now
            let at = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
            if at != mtime || scene == nil, let d = FileManager.default.contents(atPath: p),
               let t = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { scene = t; mtime = at }
        }
        return scene
    }
    func knobFor(_ from: String, _ number: Int, _ channel: Int?) -> MKKnob? {
        guard let pages = currentScene()?["pages"] as? [[String: Any]] else { return nil }
        func n(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map { Int($0) } }
        var first: MKKnob?
        for (pi, page) in pages.enumerated() {
            let pch = (n(page["channel"]) ?? 1) - 1
            for (ki, enc) in ((page["encoders"] as? [[String: Any]]) ?? []).enumerated() {
                let t = ((enc["turn_actions"] as? [[String: Any]])?.first) ?? [:]
                let push = (enc["push_action"] as? [String: Any]) ?? [:]
                let ttype = n(t["type"]) ?? 0, tnr = n(t["nr1"])
                let tch = (n(t["channel"]) ?? 0) == 0 ? pch : n(t["channel"])! - 1
                let pushch = (n(push["channel"]) ?? 0) == 0 ? pch : n(push["channel"])! - 1
                let turnHit = ttype >= 1 && ttype <= 4 && tnr == number
                var hit = false, ch = tch
                if from == "note" { hit = n(push["type"]) == 1 && n(push["nr1"]) == number; ch = pushch }
                else if turnHit { hit = true; ch = tch }
                else if n(push["type"]) == 2 && n(push["nr1"]) == number { hit = true; ch = pushch }
                if hit {
                    let idx = n(enc["color"]) ?? 0
                    let k = MKKnob(page: pi + 1, knob: ki + 1, cc: tnr ?? (ki + 1), ch: tch, turn: ttype, abs: ttype == 3,
                                   push: from == "note" || !turnHit, colour: MKLed.hex(idx), index: idx, name: (enc["abbr"] as? String) ?? "")
                    if channel == nil || ch == channel { return k }
                    if first == nil { first = k }
                }
            }
        }
        return first
    }
    func knobOrGuess(_ from: String, _ number: Int, _ channel: Int?) -> MKKnob? {
        if let k = knobFor(from, number, channel) { return k }
        if from == "note" && (1...16).contains(number) {     // the E16's default layout
            return MKKnob(page: 0, knob: number, cc: number, ch: channel ?? 0, turn: 3, abs: true, push: true, colour: "", index: -1, name: "", guessed: true)
        }
        return nil
    }
    @discardableResult func send(_ cc: Int, _ value: Int, _ ch: Int) -> Bool {
        guard let d = mkDestinations().first(where: { $0.name == MKLed.PORT }) else { return false }
        return midi.send(d.ref, 0xB0 | (ch & 0x0F), cc, value)
    }
    // a message arrives: a TURN is remembered; a pressed note on a LED row lights its knob while held
    func feel(_ rows: [MKRow], _ from: String, _ number: Int, _ value: Int, _ channel: Int?) -> String? {
        if from == "cc" {
            knobAt[number] = (Date(), value, channel)
            if let k = knobFor("cc", number, channel), !k.push { turned["\(k.cc):\(channel ?? k.ch)"] = value }
        }
        for r in rows where r.led == true && r.on && r.from == from && r.number == number {
            guard let k = knobOrGuess(from, number, channel), k.push else { continue }
            let ch = channel ?? k.ch
            let back = turned["\(k.cc):\(ch)"] ?? 0
            let v = value > 0 ? 127 : back
            let ok = send(k.cc, v, ch)
            if value == 0 { sent = [:] }
            return "LED: knob \(k.knob) " + (k.guessed ? "(by the default layout)" : "on page \(k.page)") + " "
                + (value > 0 ? "lit" : (back > 0 ? "back to its value" : "dark")) + "  (CC \(k.cc) = \(v) on USB3, ch \(ch + 1))"
                + (ok ? "" : "  \u{2014} NOT SENT: the E16's USB3 is not there")
        }
        return nil
    }
    func startFollowing() {
        sent = [:]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.followTick() }
    }
    func stopFollowing() { timer?.invalidate(); timer = nil }
    func followTick() {
        guard let lvl = MKMac.level(), let numbers = follow?(), !numbers.isEmpty else { return }
        let val = Int(lvl * 127 / 100 + 0.5)
        for num in numbers {
            guard let k = knobFor("cc", num, knobAt[num]?.ch), k.abs, !k.push else { continue }
            let key = "\(k.page):\(k.knob)"
            if let hand = knobAt[k.cc], Date().timeIntervalSince(hand.at) < 1.0 { sent[key] = val }
            else if sent[key] != val, send(k.cc, val, k.ch) { sent[key] = val }
        }
    }
    func setColour(_ from: String, _ number: Int, _ index: Int) -> String {
        guard (0...99).contains(index) else { return "a colour is a number from 0 to 99" }
        guard let k = knobFor(from, number, nil), let p = path else { return "no knob in the E16's scene answers this row: nothing to colour" }
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [NSHomeDirectory() + "/.local/lib/mantra/e16colour.py", p, "\(k.page)", "\(k.knob)", "\(index)"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        guard (try? proc.run()) != nil else { return "the scene was not changed: python3 did not start" }
        proc.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        mtime = .distantPast; looked = .distantPast
        if proc.terminationStatus != 0 { return "the scene was not changed: " + out }
        let scene = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        return "knob \(k.knob) on page \(k.page) of \(scene) is now colour \(index) (it was \(out)): send the scene to the E16 from the OXI App"
    }
    // what the LED tick of a row can do, said in words
    func about(_ from: String, _ number: Int, isVolume: Bool) -> (can: Bool, colour: String, index: Int, knob: String, says: String) {
        let what = (from == "note" ? "NOTE " : "CC ") + "\(number)"
        guard let k = knobFor(from, number, nil) else {
            if let g = knobOrGuess(from, number, nil) {
                return (true, "", -1, "", "no saved scene sends \(what), so it lights knob \(g.knob) through CC \(g.cc), the E16's default layout, while it is held")
            }
            return (false, "", -1, "", "no knob in the E16's scene sends \(what): nothing to light")
        }
        let where_ = "knob \(k.knob)" + (k.name.isEmpty ? "" : " (\(k.name))") + " on page \(k.page)"
        if k.push {
            var s = where_ + " lights in its scene colour while \(what) is held"
            if k.turn == 0 { s += " \u{2014} but its TURN is Off in the scene: set it to CC Abs in the OXI App, or the ring stays dark" }
            else if k.turn != 3 { s += " \u{2014} its TURN is relative in the scene, and a relative ring may not light" }
            return (true, k.colour, k.index, where_, s)
        }
        if !k.abs { return (false, k.colour, k.index, where_, where_ + " is relative: its ring has no value to show") }
        if isVolume { return (true, k.colour, k.index, where_, where_ + ": the ring follows the Mac's volume, also from the keyboard") }
        return (false, k.colour, k.index, where_, where_ + " already shows its own value: nothing comes back to it from here")
    }
}
