// PERMISSIONS at the top right while one is missing (v16, Marko, 30.10.2026: "If permissions are not set, it needs to
// have text in the top right: "Permissions." Then I click on it, and it opens me directly to my settings page"; the rule
// is MANTRA_MANIFEST modules/swift-apps.md). The app posts keys and clicks and holds an event tap: Accessibility only.
import SwiftUI
import AppKit
import ApplicationServices

final class Permissions: ObservableObject {
    static let shared = Permissions()
    static let needed = ["Accessibility"]
    @Published private(set) var missing: [String]

    // read again every 2 s; published only when it changed, so the window is redrawn only then
    private init() {
        missing = Permissions.check()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let m = Permissions.check()
            if m != self?.missing { self?.missing = m }
        }
    }
    static func allowed(_ p: String) -> Bool {
        switch p {
        case "Accessibility": return AXIsProcessTrusted()
        default: return true
        }
    }
    static func check() -> [String] { needed.filter { !allowed($0) } }
    // the page of the first one missing; the system's own request first, so the app is in the list and only needs switching on
    static func openMissing() {
        guard let p = check().first else { return }
        switch p {
        case "Accessibility": _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        default: break
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + p)!)
    }
}

// the word on the ON / OFF row, right of the spacer, left of the ✕; not there when everything is allowed
struct PermissionsWord: View {
    @ObservedObject var p = Permissions.shared
    var body: some View {
        if !p.missing.isEmpty {
            Text("PERMISSIONS").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(AMBER)
                .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                .onTapGesture { Permissions.openMissing() }
                .axButton("Permissions", id: "permissions") { Permissions.openMissing() }
                .help("A permission is missing: this opens its page in System Settings; switch MIDI Tools (Mantra) on there")
        }
    }
}
