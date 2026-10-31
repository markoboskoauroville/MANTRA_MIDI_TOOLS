// Mantra MIDI Tools: one app for everything that fits Ableton Live to Marko's hands. Marko, 13.10.2026:
// "Same principle as Davinci Resolve: we need to create Ableton Live actions. Right now everything what's related to
// Ableton Live can be under the same roof." The modules (Module.swift) are switched on and off here; each has its
// section in the window, its rows in the menu-bar menu, and its hot keys, live only while Live is in front.
// v16 (30.10.2026, Marko: "If permissions are not set, it needs to have text in the top right"): PERMISSIONS on the ON / OFF row.
import SwiftUI
import AppKit

final class Umbrella: NSObject, ObservableObject, NSMenuDelegate {
    @Published var on: [String: Bool] = [:]
    // the window is in tabs, one per module (Marko, 27.10.2026: "organize the whole user interface in tabs"); the
    // tab last chosen comes back
    @Published var tab: String = SETTINGS.read()["tab"] as? String ?? "mackie" {
        didSet { SETTINGS.change { $0["tab"] = self.tab } }
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        MODULES = [MackieModule(), MidiKeysModule()]
        let saved = SETTINGS.read()["modules"] as? [String: Bool] ?? [:]
        for m in MODULES { on[m.id] = saved[m.id] ?? m.defaultOn }
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        item.button?.title = "MIDI"; item.button?.toolTip = "Mantra MIDI Tools: MIDI to MK Control and MIDI to Key Stroke"
        for m in MODULES where on[m.id]! { m.setOn(true) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == BUNDLE else { return }
            self?.paint()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { for m in MODULES where self?.on[m.id] == true { m.liveCame() } }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == BUNDLE else { return }
            for m in MODULES where self?.on[m.id] == true { m.liveLeft() }
            self?.paint()
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            if liveFront() { HotKeys.shared.arm() } else { HotKeys.shared.disarm() }
        }
        rebindKeys(); paint()
    }
    func setModule(_ id: String, _ v: Bool) {
        on[id] = v; SETTINGS.change { $0["modules"] = self.on }
        MODULES.first { $0.id == id }?.setOn(v)
        rebindKeys(); paint()
    }
    func rebindKeys() { HotKeys.shared.set(MODULES.filter { on[$0.id]! }.flatMap { $0.hotkeys() }) }
    func paint() { objectWillChange.send() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for m in MODULES where on[m.id]! {
            let head = NSMenuItem(title: m.title + "  ·  " + m.status(), action: nil, keyEquivalent: ""); head.isEnabled = false
            menu.addItem(head)
            m.menuItems().forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }
        let s = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ""); s.target = self; menu.addItem(s)
    }
    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title.contains("Mantra MIDI Tools") && ($0.isVisible || $0.isMiniaturized) }) {
            w.deminiaturize(nil); w.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)   // the window was closed: a reopen makes it again
        }
    }
}

struct ModuleSection: View {
    @ObservedObject var u: Umbrella
    let m: LiveModule
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(m.title).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.white)
                Word(text: "ON", on: u.on[m.id]!) { u.setModule(m.id, true) }
                Word(text: "OFF", on: !u.on[m.id]!) { u.setModule(m.id, false) }
                Spacer()
                Text(m.status()).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(AMBER)
            }
            Small(text: m.about)
            if u.on[m.id]! { m.settingsView() }
        }
    }
}

// THE TABS: one per module, its title; lit is the tab shown, a dot says whether the module is on. In a narrow window
// they go on two lines instead of being cut.
struct TabRow: View {
    @ObservedObject var u: Umbrella
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(MODULES.indices, id: \.self) { tab(MODULES[$0]) } }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { ForEach(0..<2, id: \.self) { tab(MODULES[$0]) } }
                HStack(spacing: 4) { ForEach(2..<MODULES.count, id: \.self) { tab(MODULES[$0]) } }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
    func tab(_ m: LiveModule) -> some View {
        let lit = u.tab == m.id
        return HStack(spacing: 5) {
            Circle().fill(u.on[m.id] == true ? GREEN : GREY).frame(width: 6, height: 6)
            Text(m.title).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(lit ? .white : GREY).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.white.opacity(0.10) : .clear))
        .contentShape(Rectangle()).onTapGesture { u.tab = m.id }
    }
}

struct SettingsView: View {
    @ObservedObject var u: Umbrella
    @AppStorage("onTop") private var onTop = false
    var body: some View {
        VStack(spacing: 0) {
        // the first row: the app ON / OFF, ✕ at the far right (MANTRA_MANIFEST swift-apps.md, 19.10.2026). Marko: "In
        // the top of every user interface, there will now be an on/off switch". Running is ON; OFF stops every module
        // (applicationWillTerminate) and quits. ✕ closes the window only.
        HStack(spacing: 0) {
            Text("MANTRA MIDI TOOLS").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.white).padding(.trailing, 6)
            Word(text: "ON", on: true) {}
            Word(text: "OFF", on: false, action: { NSApp.terminate(nil) }, id: "off")
            Spacer()
            Text("v\(VERSION)").font(.system(size: 11, design: .monospaced)).foregroundColor(GREY).padding(.trailing, 8)
            // v18, TOP (Marko, 31.10.2026: "On, off and top. Please build it in every application.")
            Word(text: "TOP", on: onTop, action: { onTop.toggle(); floatWindows(onTop) }, id: "top")
                .help("Always on top: green, the window stays above every other window")
            PermissionsWord()                           // v16: only while a permission is missing (Permissions.swift)
            CloseX()
        }
        .padding(.leading, 24).padding(.trailing, 10).padding(.vertical, 8)
        Divider()
        TabRow(u: u)
        Divider()
        // the window is resizable and the page takes its width, so a long line wraps instead of being cut (Marko,
        // 25.10.2026: "It's cutting the text. There is no margin between text and the window ... windows can be
        // resizable"; the fixed 640 let one wide row push the whole page past both edges)
        // the page is given exactly the window's width less its 24-point margins: a too-wide row inside a module can no
        // longer widen the page and push it past both edges; the texts wrap inside
        GeometryReader { g in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label10(text: "ABLETON LIVE")
                    Spacer()
                    Text(liveApp() == nil ? "NOT RUNNING" : "RUNNING").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(liveApp() == nil ? GREY : GREEN)
                }
                if let m = MODULES.first(where: { $0.id == u.tab }) ?? MODULES.first { ModuleSection(u: u, m: m) }
                HStack { Spacer(); Text("v\(VERSION)").font(.system(size: 11, design: .monospaced)).foregroundColor(GREY).onTapGesture { NSWorkspace.shared.open(URL(string: RELEASES)!) } }
            }
            .frame(width: max(200, g.size.width - 48), alignment: .leading)
            .clipped()
            .padding(24)
        }
        }
        }
        .frame(minWidth: 640, idealWidth: 820, maxWidth: .infinity, minHeight: 480, idealHeight: 820, maxHeight: .infinity)
        .background(INK).preferredColorScheme(.dark)
        .onAppear { DispatchQueue.main.async { floatWindows(onTop) } }
    }
}

// made after launch: a status item needs a running NSApplication
let UMBRELLA = Umbrella()

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { _ = UMBRELLA }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    // the star's open of a running app is a reopen: the window comes back (made again by the WindowGroup if closed)
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let w = s.windows.first(where: { $0.isMiniaturized }) { w.deminiaturize(nil); return false }
        return true
    }
    func applicationWillTerminate(_ n: Notification) { for m in MODULES { m.setOn(false) } }
}

@main struct AbletonLiveActions: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        WindowGroup("Mantra MIDI Tools") { SettingsView(u: UMBRELLA) }
            .windowResizability(.contentMinSize).defaultSize(width: 820, height: 820)
    }
}
