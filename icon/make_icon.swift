// The icon, drawn: a MIDI socket (five pins) and a key cap, amber, on the dark tile; the version under it.
import AppKit
let S: CGFloat = 1024
let version = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1"
let img = NSImage(size: NSSize(width: S, height: S)); img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 180, cornerHeight: 180, transform: nil))
ctx.setFillColor(NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.06, alpha: 1).cgColor); ctx.fillPath()
let amber = NSColor(calibratedRed: 0.91, green: 0.64, blue: 0.24, alpha: 1), light = NSColor(calibratedWhite: 0.85, alpha: 1)
// the MIDI socket
ctx.setStrokeColor(light.cgColor); ctx.setLineWidth(26)
ctx.strokeEllipse(in: CGRect(x: 190, y: 380, width: 340, height: 340))
ctx.setFillColor(light.cgColor); ctx.fill(CGRect(x: 335, y: 690, width: 50, height: 36))
let c = CGPoint(x: 360, y: 550)
for a in [180.0, 135.0, 90.0, 45.0, 0.0] {
    let r = 105.0, x = c.x + CGFloat(cos(a * .pi / 180) * r), y = c.y - CGFloat(sin(a * .pi / 180) * r) + 40
    ctx.fillEllipse(in: CGRect(x: x - 24, y: y - 24, width: 48, height: 48))
}
// the arrow
ctx.setStrokeColor(amber.cgColor); ctx.setLineWidth(22)
ctx.move(to: CGPoint(x: 570, y: 550)); ctx.addLine(to: CGPoint(x: 650, y: 550)); ctx.strokePath()
ctx.move(to: CGPoint(x: 625, y: 585)); ctx.addLine(to: CGPoint(x: 660, y: 550)); ctx.addLine(to: CGPoint(x: 625, y: 515)); ctx.strokePath()
// the key cap
ctx.addPath(CGPath(roundedRect: CGRect(x: 690, y: 450, width: 200, height: 200), cornerWidth: 34, cornerHeight: 34, transform: nil))
ctx.setFillColor(amber.cgColor); ctx.fillPath()
("K" as NSString).draw(at: NSPoint(x: 752, y: 490), withAttributes: [.font: NSFont.systemFont(ofSize: 110, weight: .bold), .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1)])
("v" + version as NSString).draw(at: NSPoint(x: 170, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 92, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1)])
img.unlockFocus()
try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
