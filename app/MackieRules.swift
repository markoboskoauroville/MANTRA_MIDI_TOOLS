// MIDI TO MK CONTROL, part 2: THE TABLE'S MIND (ported 13.10.2026 from MANTRA_MACKIE/rules.lua). Pure: what a row
// means, when a message matches it, what goes on the wire, how a row reads. A row:
//   { id 1, from "cc", number 20, value 127, command "play", how "press", on true }
// HOW is decided by the command's kind, never guessed: a button PRESSes or HOLDs (64 and above is down), a jog or a
// V-Pot reads the knob's relative encoding, a fader is 7 or 14 bits, the Mac's volume knob is WITH THE BLOB or SILENT.
import Foundation

struct MKRow: Equatable {
    var id: Int
    var from: String          // "cc" or "note"
    var number: Int
    var value: Int?           // nil = any value
    var command: String
    var how: String
    var on: Bool = true
    var note: String = ""
    var invert: Bool? = nil   // only relative rows have a direction
    var led: Bool? = nil      // the E16's ring is lit from here

    // as the settings file keeps it (the same keys the Lua wrote)
    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "from": from, "number": number, "command": command, "how": how, "on": on, "note": note]
        if let v = value { d["value"] = v }
        if let i = invert { d["invert"] = i }
        if led == true { d["led"] = true }
        return d
    }
}

// a message from the controller
struct MKMsg { var from: String; var number: Int; var value: Int; var channel: Int? = nil }

// what one fired row asks the host to do
struct MKAct {
    var row: MKRow
    var kind: String            // note, combo, transport, cc, pitch, mac, macvolume
    var what: String
    var note: Int = 0
    var velocity: Int = 0
    var release = false
    var parts: [(note: Int, velocity: Int)] = []
    var play = 0, stop = 0
    var number = 0, value = 0, clicks = 0
    var rel: String? = nil      // "jog" or "vpot": a knob, added up and sent in a moment
    var channel = 0, lsb = 0, msb = 0
    var act = ""
    var percent = 0.0
    var blob = true
}

enum MKRules {
    typealias How = (id: String, label: String, says: String)
    static let HOWS: [String: [How]] = {
        var h: [String: [How]] = [:]
        h["button"] = [("press", "PRESS", "the button is pressed and released"), ("hold", "HOLD", "64 and above holds it down, below lets it go")]
        h["jog"] = [("twos", "CC Rel 1", MKMCU.MODES[0].says), ("offset", "CC Rel 2", MKMCU.MODES[1].says), ("signmag", "Sign-mag", MKMCU.MODES[2].says)]
        h["vpot"] = h["jog"]
        h["fader"] = [("7", "7-BIT", "the knob's 0-127 becomes the fader's whole range"), ("14", "14-BIT", "for a knob set to CC14 on the E16: 16384 steps, not 128")]
        h["macvolume"] = [("blob", "WITH THE BLOB", "the Mac's own volume keys, so the Mac's own blob comes up"), ("silent", "SILENT", "the exact number is set and no blob appears")]
        h["mac"] = [("press", "PRESS", "the Mac's own key, once")]
        h["combo"] = [("press", "PRESS", "the modifier goes down, the button is pressed and released, the modifier comes up")]
        h["transport"] = [("press", "PRESS", "playing, Live stops and the insert point jumps to the playhead; stopped, Live plays from the insert point")]
        return h
    }()
    // a tapped modifier does nothing in Live: a row that picks one starts on HOLD
    static let HOLD_FIRST: Set<String> = ["shift", "option", "control", "alt"]

    static func number(_ v: Any?) -> Int? {
        let d: Double?
        if let i = v as? Int { d = Double(i) } else if let x = v as? Double { d = x }
        else if let s = v as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) } else { d = nil }
        guard let dd = d else { return nil }
        let r = Int((dd + 0.5).rounded(.down))
        return (0...127).contains(r) ? r : nil
    }
    // the VALUE box: a number 0-127, or nil for ANY ("", "any", "*", "-")
    static func value(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        let s = "\(v)".trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "any" || s == "*" || s == "-" { return nil }
        return number(s)
    }
    static func percent(_ value: Int) -> Double { Double(max(0, min(127, value))) * 100.0 / 127.0 }
    static func from(_ v: Any?) -> String { "\(v ?? "cc")".lowercased() == "note" ? "note" : "cc" }

    static func hows(_ command: String) -> [How] {
        guard let e = MKMCU.command(command) else { return HOWS["button"]! }
        if e.with != nil { return HOWS["combo"]! }
        return HOWS[e.kind] ?? HOWS["button"]!
    }
    // INVERT: a jog row is born inverted (Marko, 21.9.2026); a V-Pot has the tick off; a button has no direction
    static let INVERT_FIRST = ["jog": true, "vpot": false]
    static func relative(_ row: MKRow) -> Bool { let k = MKMCU.command(row.command)?.kind; return k == "jog" || k == "vpot" }
    static func invert(_ command: String, _ v: Bool?) -> Bool? {
        guard let e = MKMCU.command(command), e.kind == "jog" || e.kind == "vpot" else { return nil }
        return v ?? INVERT_FIRST[e.kind] ?? false
    }
    static func defaultHow(_ command: String) -> String { HOLD_FIRST.contains(command) ? "hold" : hows(command)[0].id }
    static func how(_ command: String, _ how: String?) -> String {
        hows(command).contains { $0.id == (how ?? "") } ? how! : defaultHow(command)
    }
    // A ROW THAT READS THE WHOLE KNOB takes every value (a jog, a V-Pot, a fader, the volume knob, a HOLD row)
    static func sweeps(_ row: MKRow) -> Bool {
        guard let e = MKMCU.command(row.command) else { return false }
        if e.kind == "mac" || e.kind == "transport" { return false }
        if e.kind != "button" { return true }
        return row.how == "hold"
    }

    // a row as it should be kept, or nil and why; everything that reaches the file goes through here
    static func clean(_ d: [String: Any]) -> (MKRow?, String) {
        let command = "\(d["command"] ?? "")"
        guard MKMCU.command(command) != nil else { return (nil, "no Mackie command is called \"\(command)\"") }
        guard let n = number(d["number"]) else { return (nil, "the MIDI number must be from 0 to 127") }
        let id = (d["id"] as? Int) ?? Int("\(d["id"] ?? 0)") ?? 0
        var r = MKRow(id: id, from: from(d["from"]), number: n, value: nil, command: command,
                      how: how(command, d["how"] as? String), on: (d["on"] as? Bool) != false, note: "\(d["note"] ?? "")")
        if r.note == "<null>" { r.note = "" }
        r.invert = invert(command, d["invert"] as? Bool)
        if (d["led"] as? Bool) == true { r.led = true }
        if !sweeps(r) { r.value = value(d["value"]) }
        return (r, "")
    }
    static func clean(_ r: MKRow) -> MKRow? { clean(r.dict).0 }

    static func matches(_ row: MKRow, _ msg: MKMsg) -> Bool {
        if !row.on { return false }
        if from(msg.from) != row.from { return false }
        if number(msg.number) != row.number { return false }
        if let v = row.value, value(msg.value) != v { return false }
        return true
    }

    // every row a message fires, in the table's order, each turned into what it wants sent. `held` is the host's
    // memory of what each HOLD row last said, so a knob sitting still does not repeat itself.
    static func fire(_ rows: [MKRow], _ msg: MKMsg, held: inout [Int: Int]) -> [MKAct] {
        var out: [MKAct] = []
        for row in rows where matches(row, msg) {
            guard let e = MKMCU.command(row.command) else { continue }
            let value = number(msg.value) ?? 0
            switch e.kind {
            case "transport":
                var a = MKAct(row: row, kind: "transport", what: e.label)
                a.note = e.note!; a.play = e.note!; a.stop = e.stopNote!; a.number = e.cc!
                a.parts = [(e.shift!, MKMCU.PRESS), (e.note!, MKMCU.PRESS), (e.note!, MKMCU.RELEASE), (e.shift!, MKMCU.RELEASE)]
                out.append(a)
            case "button" where e.with != nil:
                // THE ORDER IS THE COMMAND: Live reads the modifier at the moment the button goes down
                var a = MKAct(row: row, kind: "combo", what: e.label); a.note = e.note!
                for n in e.with! { a.parts.append((n, MKMCU.PRESS)) }
                a.parts.append((e.note!, MKMCU.PRESS)); a.parts.append((e.note!, MKMCU.RELEASE))
                for n in e.with!.reversed() { a.parts.append((n, MKMCU.RELEASE)) }
                out.append(a)
            case "button" where row.how == "press":
                var a = MKAct(row: row, kind: "note", what: e.label); a.note = e.note!; a.velocity = MKMCU.PRESS; a.release = true
                out.append(a)
            case "button":                                           // hold
                let want = value >= 64 ? MKMCU.PRESS : MKMCU.RELEASE
                if held[row.id] != want {
                    held[row.id] = want
                    var a = MKAct(row: row, kind: "note", what: e.label + (want > 0 ? " down" : " up")); a.note = e.note!; a.velocity = want
                    out.append(a)
                }
            case "jog", "vpot":
                guard var d = MKMCU.delta(row.how, value) else { continue }   // the KNOB's encoding
                if row.invert == true { d = -d }                               // and the hand's direction
                guard let byte = MKMCU.signmag(d) else { continue }
                var a = MKAct(row: row, kind: "cc", what: e.label); a.number = e.cc!; a.value = byte; a.clicks = d; a.rel = e.kind
                out.append(a)
            case "fader":
                let f = MKMCU.fader(value, bits: Int(row.how) == 14 ? 14 : 7)
                var a = MKAct(row: row, kind: "pitch", what: e.label); a.channel = e.channel!; a.lsb = f.lsb; a.msb = f.msb
                out.append(a)
            case "mac":
                var a = MKAct(row: row, kind: "mac", what: e.label); a.act = e.act ?? ""
                out.append(a)
            case "macvolume":
                var a = MKAct(row: row, kind: "macvolume", what: e.label); a.percent = percent(value); a.blob = row.how != "silent"
                out.append(a)
            default: break
            }
        }
        return out
    }

    // ------------------------------------------------------------ how a row reads
    static func target(_ row: MKRow) -> String { MKMCU.command(row.command)?.label ?? "" }
    static func fromText(_ row: MKRow) -> String { "\(row.from == "note" ? "NOTE" : "CC") \(row.number)" }
    static func valueText(_ row: MKRow) -> String { sweeps(row) ? "0-127" : (row.value.map(String.init) ?? "any") }
    static func howLabel(_ row: MKRow) -> String { hows(row.command).first { $0.id == row.how }?.label ?? row.how }

    // the one line under a row: what Live will get, and anything worth warning about
    static func says(_ row: MKRow) -> String {
        guard let e = MKMCU.command(row.command) else { return "" }
        let wire = MKMCU.wire(row.command) + ", channel 1"
        let tail = e.says.isEmpty ? "" : " \u{2014} " + e.says
        let both = (row.from == "cc" && row.value == nil)
            ? "  \u{2014}  THIS ROW FIRES ON EVERY VALUE THE KNOB SENDS: put 127 in VALUE so only the press half fires" : ""
        switch e.kind {
        case "transport": return wire + tail + both
        case "button" where e.with != nil: return wire + ", pressed and released inside it" + tail + both
        case "button" where row.how == "press": return wire + " pressed and released" + tail
        case "button": return wire + " held while the knob is at 64 or above" + tail
        case "mac", "macvolume":
            return "THE MAC, NOT LIVE: " + (e.says.isEmpty ? e.label : e.says)
                + (e.kind == "macvolume" && row.how == "silent" ? "  \u{2014}  no blob, the number is set behind the Mac's back" : "")
        case "jog", "vpot":
            return wire + ", sign-magnitude, from a knob sending " + howLabel(row)
                + (row.invert == true ? ", TURNED ROUND (right goes back)" : ", as the hand turns") + tail
        default: return wire + ", " + howLabel(row) + tail
        }
    }

    // two live rows on the same message and value: both fire, and the page says so
    static func clashes(_ rows: [MKRow]) -> Set<Int> {
        var out = Set<Int>(), seen: [String: Int] = [:]
        for r in rows where r.on {
            let key = "\(r.from)|\(r.number)|\(r.value.map(String.init) ?? "any")"
            if let first = seen[key] { out.insert(r.id); out.insert(first) } else { seen[key] = r.id }
        }
        return out
    }
    static func nextId(_ rows: [MKRow]) -> Int { (rows.map { $0.id }.max() ?? 0) + 1 }
    // + A ROW: the jog wheel on the E16's CC Rel 1, the row most likely to be wanted
    static func blank(_ rows: [MKRow]) -> MKRow {
        clean(["id": nextId(rows), "from": "cc", "number": 1, "command": "jog", "how": "twos", "on": true]).0!
    }
}
