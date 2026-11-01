// What every part of MIDI Tools (Mantra) shares: the colours and words of the CAMERA language, the state files,
// Live itself, Python, keys and hot keys.
import SwiftUI
import AppKit
import Carbon.HIToolbox

let VERSION = 2
let RELEASES = "https://mantramiditools.pages.dev"
let BUNDLE = "com.ableton.live"
let PYTHON = NSHomeDirectory() + "/.pyenv/versions/3.10.14/bin/python3"
// the helpers (Python: audio analysis, AbletonOSC ears) ship inside the app (Resources/helpers)
let SCRIPTS: String = {
    let inApp = (Bundle.main.resourcePath ?? "") + "/helpers"
    return FileManager.default.fileExists(atPath: inApp) ? inApp : NSHomeDirectory() + "/Developer/MANTRA_MIDI_TOOLS/helpers"
}()


let GREEN = Color(red: 0x33/255, green: 0xD1/255, blue: 0x7A/255)
let GREY = Color(red: 0x7A/255, green: 0x80/255, blue: 0x87/255)
let AMBER = Color(red: 0xE8/255, green: 0xA3/255, blue: 0x3D/255)
let INK = Color(red: 0x0B/255, green: 0x0D/255, blue: 0x10/255)

struct Word: View {
    let text: String; let on: Bool; let action: () -> Void
    // v18: every word an Accessibility button (MANTRA_MANIFEST swift-apps.md, 31.10.2026); the first row's words carry
    // the fixed identifiers ("off", "top"), a module's words none, so a build's `off` is always the app's OFF
    var id: String? = nil
    var value: String? = nil
    var body: some View {
        Text(text).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(on ? GREEN : GREY)
            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle()).onTapGesture(perform: action)
            .axButton(text.capitalized, id: id ?? "", value: value ?? (on ? "on" : "off")) { DispatchQueue.main.async(execute: action) }
    }
}
extension View {
    func axButton(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}
// TOP (Marko, 31.10.2026: "Each needs to have the same user interface elements. On, off and top."): green = the
// window stays above every other window; remembered in UserDefaults "onTop" and applied at launch
func floatWindows(_ on: Bool) {
    for w in NSApp.windows where w.title.hasPrefix("MIDI Tools (Mantra)") { w.level = on ? .floating : .normal }
}
// ✕, the window's close at its far upper-right corner (Marko, 19.10.2026: "please unify the position of the close
// button on every application. It's far upper right corner. There is X to close the dialog in every dialog, same").
// It closes its own window (or, given an action, its dialog); the app stays on.
struct CloseX: View {
    var action: (() -> Void)? = nil
    @State private var window: NSWindow?
    var body: some View {
        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(GREY)
            .frame(width: 28, height: 28).contentShape(Rectangle())
            .background(WindowReader { window = $0 })
            .onTapGesture { if let a = action { a() } else { (window ?? NSApp.keyWindow)?.performClose(nil) } }
            .axButton("Close window", id: "close") { if let a = action { a() } else { (window ?? NSApp.keyWindow)?.performClose(nil) } }
            .help("close this window; the app stays on")
    }
}
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { found(v.window) }; return v }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct Label10: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(GREY) }
}
struct Small: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11, design: .monospaced)).foregroundColor(GREY).fixedSize(horizontal: false, vertical: true) }
}

// MARK: state files, read and changed as JSON dictionaries (the files the Lua apps wrote stay the same)

struct JSONFile {
    let url: URL
    init(_ name: String) { url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/" + name) }
    func read() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:] }
    func change(_ f: (inout [String: Any]) -> Void) {
        var s = read(); f(&s)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
let SETTINGS = JSONFile("midi-tools.json")     // which modules are on, the actions' shortcuts

// MARK: Live and Python

func liveApp() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE).first }
func liveFront() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BUNDLE }

// a helper script in Resources/helpers run with the Mantra Python; the answer is its last line
func runScript(_ name: String, _ args: [String] = [], then: @escaping (Int32, String) -> Void) {
    DispatchQueue.global().async {
        let p = Process(); p.executableURL = URL(fileURLWithPath: PYTHON); p.arguments = [SCRIPTS + "/" + name] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { DispatchQueue.main.async { then(-1, "\(error)") }; return }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        let last = out.split(separator: "\n").last.map(String.init) ?? ""
        DispatchQueue.main.async { then(p.terminationStatus, last) }
    }
}

// MARK: keys

let KEYS: [String: Int] = ["`": kVK_ANSI_Grave, "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S,
    "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
    "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "tab": kVK_Tab, "space": kVK_Space, "return": kVK_Return,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
    "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
    "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20]

// "ctrl+alt+cmd+U": Carbon modifiers, CGEvent flags and the key code
struct Chord {
    var carbon: UInt32 = 0; var flags: CGEventFlags = []; var key: UInt32 = 0
    init?(_ text: String) {
        var k: UInt32?
        for p in text.split(whereSeparator: { $0 == "+" || $0 == " " }).map({ $0.lowercased() }) {
            switch p {
            case "ctrl", "control": carbon |= UInt32(controlKey); flags.insert(.maskControl)
            case "alt", "option", "opt": carbon |= UInt32(optionKey); flags.insert(.maskAlternate)
            case "cmd", "command": carbon |= UInt32(cmdKey); flags.insert(.maskCommand)
            case "shift": carbon |= UInt32(shiftKey); flags.insert(.maskShift)
            default: if let c = KEYS[p] { k = UInt32(c) }
            }
        }
        guard let kk = k else { return nil }
        key = kk
    }
    var cocoa: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { f.insert(.control) }; if flags.contains(.maskAlternate) { f.insert(.option) }
        if flags.contains(.maskCommand) { f.insert(.command) }; if flags.contains(.maskShift) { f.insert(.shift) }
        return f
    }
    // the chord sent to one app (Live)
    func send(to app: NSRunningApplication) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down); e?.flags = flags
            e?.postToPid(app.processIdentifier)
        }
    }
}

// MARK: hot keys: one Carbon handler, each key a closure; all of them live only while Live is in front

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var next: UInt32 = 1
    private var wanted: [(Chord, () -> Void)] = []
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var id = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
    // the whole set, said again whenever a module or a shortcut changes
    func set(_ list: [(Chord, () -> Void)]) { wanted = list; if liveFront() { arm() } }
    func arm() {
        disarm()
        for (c, f) in wanted {
            var ref: EventHotKeyRef?
            let id = next; next += 1
            if RegisterEventHotKey(c.key, c.carbon, EventHotKeyID(signature: 0x414C4141, id: id), GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref {
                refs[id] = r; actions[id] = f
            }
        }
    }
    func disarm() { refs.values.forEach { UnregisterEventHotKey($0) }; refs = [:]; actions = [:] }
}
