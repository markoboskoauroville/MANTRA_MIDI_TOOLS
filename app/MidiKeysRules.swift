// MIDI TO KEY STROKE, the table's mind: rules.lua ported line for line (MIDI_TO_KEYSTROKE, 20.9 - 1.10.2026).
// A row: a MIDI number of a type (CC for a knob, NOTE for a key or pad), a value (nil = any), and what it does:
// press a key chord, or be the Mac's volume. Every row that reaches the settings file goes through mkClean.
// Pure Swift, no AppKit, so tests/midikeys_rules.swift runs it with plain `swift`.
import Foundation

struct KSRow: Equatable {
    var id: Int
    var cc: Int                    // the number; called cc in the file for every type, as the Lua wrote it
    var type: String = "cc"        // "cc" or "note"
    var kind: String = "key"       // "key" or "volume"
    var value: Int? = nil          // nil: any value
    var key: String? = nil         // hs.keycodes names: "o", "space", "f5"
    var mods: [String] = []
    var on: Bool = true
    var note: String = ""
    var led: Bool = false

    // the file's form: the same keys midikeys.lua wrote
    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "cc": cc, "type": type, "kind": kind, "on": on, "note": note]
        if let v = value { d["value"] = v }
        if kind == "key" { d["mods"] = mods; if let k = key { d["key"] = k } }
        if led { d["led"] = true }
        return d
    }
}

enum KSRules {
    static let MODS = ["cmd", "alt", "shift", "ctrl", "fn"]
    static let GLYPH = ["cmd": "\u{2318}", "alt": "\u{2325}", "shift": "\u{21E7}", "ctrl": "\u{2303}", "fn": "fn"]
    static let TYPES = ["cc": "CC", "note": "N"]
    // a special: the knob's whole sweep, so its value column is every value
    static let SPECIALS: [String: (label: String, sweep: Bool)] = ["volume": ("System volume", true)]

    static func int(_ v: Any?, _ lo: Int, _ hi: Int) -> Int? {
        var d: Double?
        if let n = v as? NSNumber { d = n.doubleValue }
        else if let s = v as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) }
        else if let i = v as? Int { d = Double(i) }
        guard let x = d, x.isFinite else { return nil }
        let r = Int((x + 0.5).rounded(.down))
        return (r < lo || r > hi) ? nil : r
    }
    static func cc(_ v: Any?) -> Int? { int(v, 0, 127) }

    // "", "any", "*", "-" are ANY; otherwise 0-127
    static func value(_ v: Any?) -> Int? {
        guard let v = v, !(v is NSNull) else { return nil }
        let s = "\(v)".trimmingCharacters(in: .whitespaces).lowercased()
        if s == "" || s == "any" || s == "*" || s == "-" { return nil }
        return int(s, 0, 127)
    }
    static func isAny(_ v: Any?) -> Bool {
        guard let v = v, !(v is NSNull) else { return true }
        let s = "\(v)".trimmingCharacters(in: .whitespaces).lowercased()
        return s == "" || s == "any" || s == "*" || s == "-"
    }

    static func type(_ t: Any?) -> String {
        let s = "\(t ?? "cc")".lowercased()
        return (s == "note" || s == "n") ? "note" : "cc"
    }

    // "CC 13", "cc13", "13" -> cc 13; "N 60", "note 60" -> note 60
    static func parseMidi(_ text: String) -> (String, Int)? {
        var s = text.lowercased().replacingOccurrences(of: " ", with: "")
        var typ = "cc"
        if s.hasPrefix("note") { typ = "note"; s = String(s.dropFirst(4)) }
        else if s.hasPrefix("n") { typ = "note"; s = String(s.dropFirst(1)) }
        else if s.hasPrefix("cc") { s = String(s.dropFirst(2)) }
        guard let n = int(s, 0, 127) else { return nil }
        return (typ, n)
    }

    static func midiText(_ r: KSRow) -> String { (TYPES[type(r.type)] ?? "CC") + " \(r.cc)" }

    static func mods(_ list: [Any]?) -> [String] {
        let have = Set((list ?? []).map { "\($0)".lowercased() })
        return MODS.filter { have.contains($0) }      // always in MODS order
    }

    // a row as it is kept, or the reason it is refused
    static func clean(_ d: [String: Any]) -> (KSRow?, String) {
        let kind = "\(d["kind"] ?? "key")"
        if kind != "key" && SPECIALS[kind] == nil { return (nil, "unknown kind: \(kind)") }
        guard let n = cc(d["cc"]) else { return (nil, "the MIDI number must be from 0 to 127") }
        var r = KSRow(id: int(d["id"], Int.min, Int.max) ?? 0, cc: n)
        r.type = type(d["type"]); r.kind = kind
        r.on = (d["on"] as? Bool) ?? true               // on unless it says false
        r.note = "\(d["note"] ?? "")"
        if let l = d["led"] as? Bool, l { r.led = true }
        r.value = (SPECIALS[kind]?.sweep ?? false) ? nil : value(d["value"])
        if kind == "key" {
            let k = "\(d["key"] ?? "")".lowercased()
            r.key = (k.isEmpty || d["key"] == nil || d["key"] is NSNull) ? nil : k
            r.mods = mods(d["mods"] as? [Any])
        }
        return (r, "")
    }

    // does this message belong to this row? A note's release fires only a row that asked for 0.
    static func matches(_ r: KSRow, _ n: Int, _ v: Int, _ typ: String) -> Bool {
        if !r.on { return false }
        if r.kind == "key" && r.key == nil { return false }
        let t = type(typ)
        if type(r.type) != t { return false }
        if cc(n) != r.cc { return false }
        if t == "note" && value(v) == 0 && r.value != 0 { return false }
        if let want = r.value, value(v) != want { return false }
        return true
    }

    enum Act { case key(String, [String], KSRow); case volume(Int, KSRow) }
    static func fire(_ rows: [KSRow], _ n: Int, _ v: Int, _ typ: String) -> [Act] {
        rows.compactMap { r in
            guard matches(r, n, v, typ) else { return nil }
            if r.kind == "key" { return .key(r.key ?? "", r.mods, r) }
            if r.kind == "volume" { return .volume(percent(v), r) }
            return nil
        }
    }

    // 0-127 to 0-100, both ends exact
    static func percent(_ v: Int) -> Int { Int((Double(cc(v) ?? 0) * 100 / 127 + 0.5).rounded(.down)) }

    static func chord(_ mods: [String], _ key: String) -> String {
        var s = mods.map { GLYPH[$0] ?? $0 }.joined()
        s += key.count == 1 ? key.uppercased() : key
        return s
    }
    static func target(_ r: KSRow) -> String {
        if let sp = SPECIALS[r.kind] { return sp.label }
        guard let k = r.key else { return "" }
        return chord(r.mods, k)
    }
    static func valueText(_ r: KSRow) -> String {
        if SPECIALS[r.kind]?.sweep == true { return "0-127" }
        return r.value.map(String.init) ?? "any"
    }
    // two live rows on the same MIDI and value both fire: both are marked
    static func clashes(_ rows: [KSRow]) -> Set<Int> {
        var out = Set<Int>(), seen: [String: Int] = [:]
        for r in rows where r.on {
            let k = midiText(r) + "|" + (r.value.map(String.init) ?? "any")
            if let first = seen[k] { out.insert(r.id); out.insert(first) } else { seen[k] = r.id }
        }
        return out
    }
    static func nextId(_ rows: [KSRow]) -> Int { (rows.map(\.id).max() ?? 0) + 1 }
}
