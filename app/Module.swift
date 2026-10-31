// A MODULE of Mantra MIDI Tools: one thing that fits Live to Marko's hands (A1, MIDI to MK Control, MIDI to Key
// Stroke, and whatever comes next). The umbrella switches it on and off, gives it a section of the window, a few rows
// in the menu-bar menu, and arms its hot keys only while Live is in front. A module owns its own files, state and
// engines; it never reaches into another module.
import SwiftUI
import AppKit

protocol LiveModule: AnyObject {
    var id: String { get }                       // "a1", "mackie", "midikeys": the key in live-actions.json → modules
    var title: String { get }                    // its section's heading, in capitals
    var about: String { get }                    // one sentence
    var defaultOn: Bool { get }
    func setOn(_ on: Bool)                       // start or stop everything it runs
    func liveCame()                              // Live started (called ~5 s after its launch)
    func liveLeft()                              // Live quit
    func hotkeys() -> [(Chord, () -> Void)]      // armed only while Live is in front
    func menuItems() -> [NSMenuItem]             // rows for the menu-bar menu (targets kept alive by the module)
    func settingsView() -> AnyView               // its section of the window
    func status() -> String                      // a few words for the section's head, e.g. "LISTENING · E16"
}

// the modules, in the window's order; each file adds its own (A1.swift, Mackie.swift, MidiKeys.swift)
var MODULES: [LiveModule] = []
