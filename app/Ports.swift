// Ports.swift: WHICH PORT IS IT ON, for the Swift apps. The Swift half of ports.py: the same registry,
// ~/.config/mantra-ports.json, the same questions. Copy this one file into an app's sources (no package, no
// dependency; Foundation and Darwin only).
//
//     let port = Ports.claim("myapp", 8962)                // a server: its usual port, or the next free one
//     let base = Ports.url("voice", fallback: 8837)        // a client: the live server, or the usual number
//     let (ok, who) = Ports.own("abletonosc-answers", 11001, udp: true)   // a FIXED port: one owner only
//
// Marko, 27.10.2026: "There must be some kind of automatic assignment of the port as central service for all my star
// applications so there is no clashing of the ports never." A new app takes its number from `mantra-ports next`,
// claims it at start, and every client asks for the name. A fixed port (decided by another program, like
// AbletonOSC's 11001) is never "the next free one": its owner says `own`, and an app that is refused uses the owner's
// router instead (`mantra-ports check` names it).
import Foundation
import Darwin

enum Ports {
    static let file = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mantra-ports.json")

    static func read() -> [String: [String: Any]] {
        guard let d = try? Data(contentsOf: file),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { $0 as? [String: Any] }
    }
    // written whole, under a temporary name and renamed over: a reader never sees half a file
    static func write(_ d: [String: [String: Any]]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = file.appendingPathExtension("tmp")
        if (try? data.write(to: tmp)) != nil { _ = rename(tmp.path, file.path) }
    }

    // is the port there for the taking? asked by binding it, the only honest test. TCP: with SO_REUSEADDR (a port in
    // TIME_WAIT after its own server stopped is free: MANTRA_MANIFEST ports.md §1) and nothing may answer on it. UDP: on
    // every address without SO_REUSEADDR (with it, 127.0.0.1:11001 binds beside *:11001: found 27.10.2026).
    static func free(_ port: UInt16, udp: Bool = false) -> Bool {
        let s = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        if !udp { var on: Int32 = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        close(s)
        return ok && (udp || !answers(port))
    }

    // is something listening there now? a plain TCP connect, no HTTP
    static func answers(_ port: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// The port this server listens on, written down under `name`: `want` when free, else the next free one after it.
    static func claim(_ name: String, _ want: UInt16, health: String = "/health", udp: Bool = false, span: UInt16 = 40) -> UInt16 {
        var port: UInt16 = free(want, udp: udp) ? want : 0
        if port == 0 { for p in (want + 1)..<(want + span) where free(p, udp: udp) { port = p; break } }
        if port == 0 { port = want }                      // nothing free near it: the caller's bind will say why
        var d = read()
        d[name] = ["port": Int(port), "url": "http://127.0.0.1:\(port)", "health": health, "proto": udp ? "udp" : "tcp",
                   "pid": Int(getpid()), "at": Int(Date().timeIntervalSince1970), "wanted": Int(want)]
        write(d)
        return port
    }

    /// The one owner of a FIXED port: true when this app may bind it; else false and who holds it.
    static func own(_ name: String, _ port: UInt16, udp: Bool = true) -> (Bool, String) {
        guard free(port, udp: udp) else { return (false, holder(port, udp: udp)) }
        var d = read()
        d[name] = ["port": Int(port), "proto": udp ? "udp" : "tcp", "fixed": true, "pid": Int(getpid()),
                   "at": Int(Date().timeIntervalSince1970), "wanted": Int(port)]
        write(d)
        return (true, "")
    }

    /// Written down as the owner of a port this app has just bound (a FIXED number others dial: the phone, a proxy
    /// setting, AbletonOSC), so `mantra-ports check` can name a stranger on it. Called after the bind succeeded.
    static func record(_ name: String, _ port: UInt16, udp: Bool = false, health: String? = nil) {
        var d = read()
        var e: [String: Any] = ["port": Int(port), "proto": udp ? "udp" : "tcp", "fixed": true, "pid": Int(getpid()),
                                "at": Int(Date().timeIntervalSince1970), "wanted": Int(port)]
        if let h = health { e["health"] = h; e["url"] = "http://127.0.0.1:\(port)" }
        d[name] = e
        write(d)
    }

    /// The base URL of a live server of that name, or nil (a stale address is worse than none).
    static func find(_ name: String) -> String? {
        guard let p = read()[name]?["port"] as? Int, p > 0, p < 65536, answers(UInt16(p)) else { return nil }
        return "http://127.0.0.1:\(p)"
    }
    /// What a client talks to: the live registered server, else the usual number. Never nil.
    static func url(_ name: String, fallback: UInt16) -> String { find(name) ?? "http://127.0.0.1:\(fallback)" }

    // who holds a port now, for the words of a refusal ("Python 82394")
    static func holder(_ port: UInt16, udp: Bool) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", (udp ? "-iUDP:" : "-iTCP:") + "\(port)", "-Fpc"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "someone" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        var pid = "", names: [String] = []
        for l in out.split(separator: "\n") {
            if l.hasPrefix("p") { pid = String(l.dropFirst()) } else if l.hasPrefix("c") { names.append("\(l.dropFirst()) \(pid)") }
        }
        return names.isEmpty ? "someone" : names.joined(separator: ", ")
    }
}
