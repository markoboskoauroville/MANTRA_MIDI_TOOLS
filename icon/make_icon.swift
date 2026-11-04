// make_icon.swift: the icon is six letters over one picture (Marko 4.11.2026: "I want 6 letters in this icon and one
// symbolic background, and that's all"). It is made once, for every star app, by STAR_SWIFT/icons6/six_icon.swift and
// kept beside this file as six_1024.png; this script only hands it to the build, in the form the build asks for:
//   swift make_icon.swift [version]                -> icon_1024.png (and icon.png when one is there) in this folder
//   swift make_icon.swift <version> <file.png>      -> that png
//   swift make_icon.swift <dir.iconset> [version]   -> the ten sizes of an iconset
// No version is drawn any more: the six letters are the whole icon.
import AppKit
let me = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let src = me.appendingPathComponent("six_1024.png").path
let fm = FileManager.default
func put(_ to: String) { try? fm.removeItem(atPath: to); try! fm.copyItem(atPath: src, toPath: to) }
func sized(_ px: Int, _ to: String) {
    let p = Process(); p.launchPath = "/usr/bin/sips"; p.arguments = ["-z", "\(px)", "\(px)", src, "--out", to]
    p.standardOutput = FileHandle.nullDevice; p.launch(); p.waitUntilExit()
}
let args = Array(CommandLine.arguments.dropFirst())
if let set = args.first(where: { $0.hasSuffix(".iconset") }) {
    try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)
    for (n, p) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] { sized(p, "\(set)/icon_\(n).png") }
} else if let png = args.first(where: { $0.hasSuffix(".png") }) {
    put(png)
} else {
    let cwd = fm.currentDirectoryPath
    if src != "\(cwd)/icon_1024.png" { put("\(cwd)/icon_1024.png") }
    if fm.fileExists(atPath: "\(cwd)/icon.png") { put("\(cwd)/icon.png") }
}
