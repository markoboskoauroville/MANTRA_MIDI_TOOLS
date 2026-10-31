// MIDI TO MK CONTROL, part 1 of the Mackie module: MACKIE CONTROL AS ABLETON LIVE 12 ITSELF DEFINES IT.
// Ported 13.10.2026 from MANTRA_MACKIE/mcu.lua (Marko: "We are quitting the Lua, no more Lua, only Swift"). Pure:
// no MIDI, no screen; checked against the vectors of MANTRA_MACKIE/tests/test_mcu.lua and test_rules.lua.
//
// THE FIRST THING TO KNOW: Mackie Control does not use CC for its buttons. A button is a NOTE ON on channel 1,
// velocity 127 for the press and 0 for the release, and it is momentary. A fader is a 14-bit PITCH BEND. Only the
// V-Pots (CC 16-23) and the jog wheel (CC 60) are CC, and both are relative.
//
// THE SECOND THING: THE GENERIC MACKIE MAP IS NOT LIVE'S MAP. Every number below was read out of Live 12 Suite's own
// MIDI Remote Scripts/MackieControl on 20.9.2026 (mcu.lua has the table of face plate against Live's meaning).
import Foundation

struct MKCommand {
    let id: String
    let label: String
    let group: String
    let kind: String            // button, transport, jog, vpot, fader, mac, macvolume
    var note: Int? = nil
    var stopNote: Int? = nil
    var cc: Int? = nil
    var shift: Int? = nil
    var with: [Int]? = nil      // modifier notes a combo is wrapped in
    var channel: Int? = nil
    var strip: Int? = nil
    var act: String? = nil      // mac: up, down, mute
    var sid: String = ""
    var says: String = ""
}

enum MKMCU {
    static let CHANNEL = 0          // Live reads NOTE_ON_STATUS 144 and CC_STATUS 176: channel 1, zero-based 0
    static let PRESS = 127
    static let RELEASE = 0
    static let JOG_CC = 60
    static let VPOT_CC = 16
    static let STRIPS = 8
    static let MASTER = 9

    // ------------------------------------------------------------ relative encodings
    // twos (the E16's CC Rel 1): 1..63 right, 127..65 left · offset (CC Rel 2): 65.. right, ..63 left ·
    // signmag (Mackie's own): 1..63 right, 65..127 left. Getting this wrong moves Live 31 beats the wrong way.
    static let MODES: [(id: String, label: String, says: String)] = [
        ("twos", "CC Rel 1  (two's complement)", "the E16's CC Rel 1: 1 right, 127 left"),
        ("offset", "CC Rel 2  (binary offset)", "the E16's CC Rel 2: 65 right, 63 left"),
        ("signmag", "Sign-magnitude  (Mackie's own)", "1 right, 65 left - already Mackie"),
    ]

    // a relative CC value as a signed number of clicks; nil when it says nothing happened
    static func delta(_ mode: String, _ value: Int?) -> Int? {
        guard let v = value, v >= 0, v <= 127 else { return nil }
        switch mode {
        case "offset": return v == 64 ? nil : v - 64
        case "signmag": if v == 0 || v == 64 { return nil }; return v < 64 ? v : -(v - 64)
        default: if v == 0 { return nil }; return v < 64 ? v : v - 128
        }
    }

    // a signed number of clicks as Mackie's sign-magnitude byte, clamped to 63 either way
    static func signmag(_ delta: Int) -> Int? {
        if delta == 0 { return nil }
        return delta > 0 ? min(delta, 63) : 64 + min(-delta, 63)
    }

    // ------------------------------------------------------------ what Live does with the jog wheel
    // Disassembled from Live 12's Transport.handle_jog_wheel_rotation: one beat a click, four while playing, a
    // quarter with ALT held; CONTROL held makes it the tempo; the Session view makes it scroll scenes.
    static let JOG_MIN_BEATS = 1.0
    static func jogBeats(_ value: Int, playing: Bool, alt: Bool) -> Double {
        guard let d = delta("signmag", value) else { return 0 }
        var step = max(JOG_MIN_BEATS, Double(abs(d)) / 2.0)
        if playing { step *= 4 }
        if alt { step /= 4 }
        return d < 0 ? -step : step
    }
    static func jogSays(playing: Bool, alt: Bool) -> String {
        let b = jogBeats(1, playing: playing, alt: alt)
        let s = b >= 1 ? "\(fmtG(b)) beat\(b == 1 ? "" : "s")" : "\(fmtG(b)) of a beat"
        return "one click moves " + s + (playing ? " (Live is playing, so Live multiplies by four)" : "")
            + (alt ? " (ALT is held, so Live divides by four)" : "")
    }
    static func fmtG(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    // A SPIN IS ONE MESSAGE: Live's step is max(1, value/2) beats, so 2N moves exactly N beats. Ten messages sent with
    // no gap moved Live ONE beat (measured 20.9.2026), so a spin is collapsed. 31 clicks is the cap (62/2).
    static let JOG_MAX_CLICKS = 31
    static func jogByteForClicks(_ clicks: Int) -> (byte: Int?, used: Int) {
        if clicks == 0 { return (nil, 0) }
        let used = min(JOG_MAX_CLICKS, abs(clicks)), mag = used * 2
        return (clicks > 0 ? mag : 64 + mag, used)
    }
    // THE TEMPO DOES NOT HALVE (CONTROL held): one BPM per unit, so the clicks themselves; 63 is the cap.
    static let TEMPO_MAX_CLICKS = 63
    static func tempoByteForClicks(_ clicks: Int) -> (byte: Int?, used: Int) {
        if clicks == 0 { return (nil, 0) }
        let used = min(TEMPO_MAX_CLICKS, abs(clicks))
        return (clicks > 0 ? used : 64 + used, used)
    }

    // ------------------------------------------------------------ the faders: pitch bend, 7 or 14 bits
    static func fader(_ value: Int, bits: Int) -> (lsb: Int, msb: Int) {
        let full = bits == 14 ? 16383 : 127
        let v0 = max(0, min(full, value))
        let v = bits == 14 ? v0 : Int((Double(v0) * 16383 / 127 + 0.5).rounded(.down))
        return (v % 128, v / 128)
    }

    // ------------------------------------------------------------ THE CATALOGUE, the drop-down (121 commands)
    static let GROUPS = [
        "THE TIMELINE", "TRANSPORT", "MARKERS AND THE LOOP", "THE ARROWS",
        "MODIFIERS  (hold them)", "UNDO AND REDO", "THE VIEWS AND THE EDITOR",
        "THE MIXER STRIP", "THE BANK", "WHAT THE V-POTS DO", "THE DISPLAY", "KNOBS AND FADERS",
        "THE MAC  (not Live)",
    ]

    static let COMMANDS: [MKCommand] = {
        var c: [MKCommand] = []
        func button(_ id: String, _ label: String, _ group: String, _ note: Int, _ sid: String, _ says: String = "") {
            c.append(MKCommand(id: id, label: label, group: group, kind: "button", note: note, sid: sid, says: says))
        }
        func combo(_ id: String, _ label: String, _ group: String, _ note: Int, _ with: [Int], _ sid: String, _ says: String) {
            c.append(MKCommand(id: id, label: label, group: group, kind: "button", note: note, with: with, sid: sid, says: says))
        }
        // THE TIMELINE
        c.append(MKCommand(id: "jog", label: "JOG WHEEL \u{2014} the playback position", group: "THE TIMELINE", kind: "jog",
                           cc: JOG_CC, sid: "JOG_WHEEL_CC_NO",
                           says: "the arrangement moves under the knob: one beat a click, four while Live plays, a quarter with ALT held. "
                               + "Showing the Session view makes the same knob scroll scenes; holding CONTROL makes it the tempo."))
        // TRANSPORT. PLAY / STOP: one button, THE INSERT POINT IS THE MASTER (Marko, 21.9.2026): playing → STOP and the
        // jog one beat each way plants the insert point on the playhead; stopped → plain PLAY, which seeks the insert point.
        c.append(MKCommand(id: "playstop", label: "PLAY / STOP  \u{2014} one button, from the insert point", group: "TRANSPORT",
                           kind: "transport", note: 94, stopNote: 93, cc: JOG_CC, shift: 70,
                           sid: "SID_TRANSPORT_PLAY, SID_TRANSPORT_STOP and JOG_WHEEL_CC_NO",
                           says: "one button for both, and the insert point is the master: pressed while Live plays it stops "
                               + "where it is AND the insert point jumps to that spot; pressed while Live is stopped it plays "
                               + "FROM THE INSERT POINT, wherever you have just put it"))
        combo("continuestop", "CONTINUE / STOP  \u{2014} Live's own SHIFT + PLAY", "TRANSPORT", 94, [70],
              "SID_MOD_SHIFT held + SID_TRANSPORT_PLAY",
              "Live's own one button: stopped, it CONTINUES from its own playhead and does not look at the insert "
                  + "point; playing, it stops where it is. This is what PLAY / STOP was until 21.9.2026")
        button("play", "PLAY", "TRANSPORT", 94, "SID_TRANSPORT_PLAY", "Live starts playing FROM THE INSERT MARKER - it jumps back every time; PLAY / STOP above is the one that continues")
        button("stop", "STOP", "TRANSPORT", 93, "SID_TRANSPORT_STOP", "Live stops")
        button("record", "RECORD", "TRANSPORT", 95, "SID_TRANSPORT_RECORD", "the arrangement record button")
        button("rewind", "REWIND", "TRANSPORT", 91, "SID_TRANSPORT_REWIND", "held down, it rewinds")
        button("forward", "FAST FORWARD", "TRANSPORT", 92, "SID_TRANSPORT_FAST_FORWARD", "held down, it winds forward")
        // MARKERS AND THE LOOP
        button("loop", "LOOP on and off", "MARKERS AND THE LOOP", 86, "SID_MARKER_LOOP")
        button("markerprev", "PREVIOUS MARKER", "MARKERS AND THE LOOP", 84, "SID_MARKER_FROM_PREV")
        button("markernext", "NEXT MARKER", "MARKERS AND THE LOOP", 85, "SID_MARKER_FROM_NEXT")
        button("punchin", "PUNCH IN", "MARKERS AND THE LOOP", 87, "SID_MARKER_PI",
               "punch in on and off; with CONTROL held it sets the LOOP START to where the playhead is instead")
        button("punchout", "PUNCH OUT", "MARKERS AND THE LOOP", 88, "SID_MARKER_PO",
               "punch out on and off; with CONTROL held it sets the LOOP END to where the playhead is instead")
        button("home", "GO TO START", "MARKERS AND THE LOOP", 89, "SID_MARKER_HOME",
               "not the metronome: a real Mackie's key here says CLICK, but Live means the start of the song")
        button("songend", "GO TO END", "MARKERS AND THE LOOP", 90, "SID_MARKER_END",
               "a real Mackie's key here says SOLO; Live means the end of the song")
        button("marker", "SET OR DELETE A LOCATOR", "MARKERS AND THE LOOP", 82, "SID_FUNC_MARKER",
               "song.set_or_delete_cue(): a locator at the playhead, or away again if one is already there. A real Mackie's key here says MARKER")
        // THE ARROWS
        button("up", "UP", "THE ARROWS", 96, "SID_JOG_CURSOR_UP")
        button("down", "DOWN", "THE ARROWS", 97, "SID_JOG_CURSOR_DOWN")
        button("left", "LEFT", "THE ARROWS", 98, "SID_JOG_CURSOR_LEFT")
        button("right", "RIGHT", "THE ARROWS", 99, "SID_JOG_CURSOR_RIGHT")
        button("zoom", "ZOOM", "THE ARROWS", 100, "SID_JOG_ZOOM",
               "held, the arrows ZOOM instead of walking. But with the SESSION view showing it is not a zoom at all: it FIRES the selected clip, or stops it with OPTION held")
        button("scrub", "SCRUB", "THE ARROWS", 101, "SID_JOG_SCRUB",
               "nothing at all in the Arrangement (Live has no scrub here). With the SESSION view showing it FIRES THE SELECTED SCENE, or stops every clip with OPTION held")
        // MODIFIERS
        button("shift", "SHIFT", "MODIFIERS  (hold them)", 70, "SID_MOD_SHIFT")
        button("option", "OPTION", "MODIFIERS  (hold them)", 71, "SID_MOD_OPTION")
        button("control", "CONTROL", "MODIFIERS  (hold them)", 72, "SID_MOD_CTRL",
               "held, the jog wheel becomes the TEMPO: one BPM a click, a tenth with ALT held too")
        button("alt", "ALT", "MODIFIERS  (hold them)", 73, "SID_MOD_ALT",
               "held, the jog wheel moves a QUARTER of a beat instead of a whole one - the finest Live will go")
        // UNDO AND REDO
        button("undo", "UNDO", "UNDO AND REDO", 76, "SID_FUNC_UNDO", "song.undo(); note 76, not the 81 a face plate says")
        button("redo", "REDO", "UNDO AND REDO", 79, "SID_FUNC_REDO", "song.redo()")
        // THE VIEWS AND THE EDITOR: not one of these does what its face plate says (Live's SoftwareController)
        button("autoon", "SESSION / ARRANGEMENT", "THE VIEWS AND THE EDITOR", 74, "SID_AUTOMATION_ON",
               "the other view. A real Mackie's key here says AUTOMATION ON")
        button("autorecord", "CLIP / DEVICE", "THE VIEWS AND THE EDITOR", 75, "SID_AUTOMATION_RECORD",
               "the detail pane shows the clip or the device chain. A real Mackie's key here says AUTOMATION REC")
        button("snapshot", "THE BROWSER, SHOW / HIDE", "THE VIEWS AND THE EDITOR", 77, "SID_AUTOMATION_SNAPSHOT",
               "a real Mackie's key here says SNAPSHOT")
        button("touch", "THE DETAIL PANE, SHOW / HIDE", "THE VIEWS AND THE EDITOR", 78, "SID_AUTOMATION_TOUCH",
               "a real Mackie's key here says TOUCH")
        button("cancel", "BACK TO ARRANGEMENT", "THE VIEWS AND THE EDITOR", 80, "SID_FUNC_CANCEL",
               "Live's Back to Arrangement button. A real Mackie's key here says CANCEL")
        button("enter", "DRAW MODE  (the pencil)", "THE VIEWS AND THE EDITOR", 81, "SID_FUNC_ENTER",
               "a real Mackie's key here says ENTER")
        button("mixer", "FOLLOW  (the view follows the playhead)", "THE VIEWS AND THE EDITOR", 83, "SID_FUNC_MIXER",
               "song.follow_song. A real Mackie's key here says MIXER")
        // THE MIXER STRIP, eight of each
        let strip: [(String, String, Int, String)] = [
            ("arm", "ARM", 0, "SID_RECORD_ARM_CH%d"), ("solo", "SOLO", 8, "SID_SOLO_CH%d"), ("mute", "MUTE", 16, "SID_MUTE_CH%d"),
            ("select", "SELECT", 24, "SID_SELECT_CH%d"), ("vpotpress", "V-POT PRESS", 32, "SID_VPOD_PUSH_CH%d"),
            ("fadertouch", "FADER TOUCH", 104, "SID_FADER_TOUCH_SENSE_CH%d"),
        ]
        for s in strip {
            for n in 1...STRIPS { button(s.0 + "\(n)", s.1 + " \(n)", "THE MIXER STRIP", s.2 + n - 1, String(format: s.3, n)) }
        }
        button("fadertouch9", "FADER TOUCH 9  (the master)", "THE MIXER STRIP", 112, "SID_FADER_TOUCH_SENSE_MASTER")
        // THE BANK
        button("bankleft", "BANK LEFT  (eight tracks)", "THE BANK", 46, "SID_FADERBANK_PREV_BANK")
        button("bankright", "BANK RIGHT  (eight tracks)", "THE BANK", 47, "SID_FADERBANK_NEXT_BANK")
        button("trackleft", "TRACK LEFT  (one track)", "THE BANK", 48, "SID_FADERBANK_PREV_CH")
        button("trackright", "TRACK RIGHT  (one track)", "THE BANK", 49, "SID_FADERBANK_NEXT_CH")
        button("flip", "FLIP", "THE BANK", 50, "SID_FADERBANK_FLIP")
        button("edit", "THE RETURN TRACKS, IN AND OUT OF THE BANK", "THE BANK", 51, "SID_FADERBANK_EDIT",
               "toggle_view_returns(): the eight strips show the returns as well, or not. A real Mackie's key here says GLOBAL VIEW")
        combo("bankfirst", "BANK: THE FIRST TRACKS", "THE BANK", 46, [70], "SID_MOD_SHIFT held + SID_FADERBANK_PREV_BANK",
              "all the way left: strip 1 becomes the first track in the set")
        combo("banklast", "BANK: THE LAST TRACKS", "THE BANK", 47, [70], "SID_MOD_SHIFT held + SID_FADERBANK_NEXT_BANK",
              "all the way right: the last whole bank of eight")
        // WHAT THE V-POTS DO
        button("modeio", "V-POTS: INPUT / OUTPUT", "WHAT THE V-POTS DO", 40, "SID_ASSIGNMENT_IO")
        button("modesends", "V-POTS: SENDS", "WHAT THE V-POTS DO", 41, "SID_ASSIGNMENT_SENDS")
        button("modepan", "V-POTS: PAN", "WHAT THE V-POTS DO", 42, "SID_ASSIGNMENT_PAN")
        button("modeplugins", "V-POTS: PLUG-INS", "WHAT THE V-POTS DO", 43, "SID_ASSIGNMENT_PLUG_INS")
        button("modeeq", "V-POTS: THE PAGE BEFORE", "WHAT THE V-POTS DO", 44, "SID_ASSIGNMENT_EQ",
               "switch_to_prev_page(): not EQ at all - eight more of the same mode's parameters. A real Mackie's key here says EQ")
        button("modedynamic", "V-POTS: THE NEXT PAGE", "WHAT THE V-POTS DO", 45, "SID_ASSIGNMENT_DYNAMIC",
               "switch_to_next_page(). A real Mackie's key here says DYNAMICS")
        // THE DISPLAY
        button("namevalue", "NAME / VALUE", "THE DISPLAY", 52, "SID_DISPLAY_NAME_VALUE",
               "the meters on a real Mackie's own display. NOTHING HAPPENS IN LIVE'S WINDOW: there is no display here to change")
        button("smptebeats", "SMPTE / BEATS", "THE DISPLAY", 53, "SID_DISPLAY_SMPTE_BEATS",
               "the clock on a real Mackie's own display. NOTHING HAPPENS IN LIVE'S WINDOW")
        // KNOBS AND FADERS
        for n in 1...STRIPS {
            c.append(MKCommand(id: "vpot\(n)", label: "V-POT \(n)  (relative)", group: "KNOBS AND FADERS", kind: "vpot",
                               cc: VPOT_CC + n - 1, strip: n, sid: "FID_PANNING_BASE + \(n - 1)",
                               says: "what a V-Pot does depends on the V-POT mode above: pan, a send, a device's parameter"))
        }
        // THE FADERS ARE THE ONE THING LIVE DID NOT ANSWER (21.9.2026): mapped with a feedback rule, they need
        // MackieControl to have an OUTPUT port in Live's settings.
        for n in 1...MASTER {
            c.append(MKCommand(id: "fader\(n)", label: (n == MASTER ? "FADER 9  (the master)" : "FADER \(n)") + "  (absolute)",
                               group: "KNOBS AND FADERS", kind: "fader", channel: n - 1, strip: n, sid: "pitch bend, channel \(n)",
                               says: "the knob's whole sweep is the fader; a knob set to CC14 on the E16 gives 14 bits instead of 7. "
                                   + "MEASURED 21.9.2026: LIVE DID NOT MOVE FOR IT \u{2014} give MackieControl an OUTPUT port "
                                   + "in Live's settings (a second IAC bus) and try again; a fader is mapped with a feedback rule "
                                   + "and every note worked on the same wire"))
        }
        // THE MAC (not Live): the Mac's own volume keys, so the Mac's own blob
        c.append(MKCommand(id: "volumeup", label: "VOLUME UP", group: "THE MAC  (not Live)", kind: "mac", act: "up",
                           sid: "the Mac's own SOUND_UP key", says: "a quarter of a step, and the Mac's own volume blob comes up with it"))
        c.append(MKCommand(id: "volumedown", label: "VOLUME DOWN", group: "THE MAC  (not Live)", kind: "mac", act: "down",
                           sid: "the Mac's own SOUND_DOWN key", says: "a quarter of a step, and the Mac's own volume blob comes up with it"))
        c.append(MKCommand(id: "volumemute", label: "MUTE THE MAC", group: "THE MAC  (not Live)", kind: "mac", act: "mute",
                           sid: "the Mac's own MUTE key", says: "the Mac's mute, on and off, with its own blob"))
        c.append(MKCommand(id: "volume", label: "SYSTEM VOLUME  (a whole knob)", group: "THE MAC  (not Live)", kind: "macvolume",
                           sid: "the Mac's own volume", says: "the Mac's output volume follows the knob, silence at 0 and full at 127"))
        return c
    }()

    static let BY_ID: [String: MKCommand] = Dictionary(uniqueKeysWithValues: COMMANDS.map { ($0.id, $0) })
    static func command(_ id: String?) -> MKCommand? { BY_ID[id ?? ""] }

    static func catalogue() -> [(group: String, items: [MKCommand])] {
        GROUPS.map { g in (g, COMMANDS.filter { $0.group == g }) }
    }

    static let MODS = [70: "SHIFT", 71: "OPTION", 72: "CONTROL", 73: "ALT"]
    static func modName(_ note: Int) -> String { MODS[note] ?? "note \(note)" }

    // what a command puts on the wire, in one line
    static func wire(_ id: String) -> String {
        guard let e = command(id) else { return "" }
        switch e.kind {
        case "button":
            if let w = e.with { return "note \(e.note!) with \(w.map(modName).joined(separator: " and ")) held" }
            return "note \(e.note!)"
        case "transport":
            return "note \(e.note!) to play from the insert point, note \(e.stopNote!) to stop, then CC \(e.cc!) one beat each way to plant it"
        case "fader": return "pitch bend, channel \((e.channel ?? 0) + 1)"
        case "mac", "macvolume": return "nothing on the bus: the Mac's own volume"
        default: return "CC \(e.cc ?? 0)"
        }
    }

    // THE SHORT NAME, for the command blob: the label without its dash-tail or brackets
    static func short(_ id: String) -> String {
        guard let e = command(id) else { return "" }
        var s = e.label
        if let r = s.range(of: "\u{2014}") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: "(") { s = String(s[..<r.lowerBound]) }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? e.label : s
    }
}
