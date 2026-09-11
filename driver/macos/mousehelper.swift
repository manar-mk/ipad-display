// mousehelper: injects mouse input on macOS from commands on stdin (one per line), the same set the
// Windows PowerShell helper in main.js understands. Coordinates are global screen points.
//
//   move x y | down x y | up x y | rclick x y | wheel d | hwheel d | zoom d | pos | quit
//   d is a multiple of 120 (one wheel notch), sign as on Windows: wheel > 0 scrolls up, hwheel > 0 right.
//
//   swiftc -O mousehelper.swift -o mousehelper -framework ApplicationServices
//
// Prints "ax 1" / "ax 0" on start (accessibility permission of the responsible process, i.e. the host app;
// without it macOS silently drops posted events) and "pos x y" for the `pos` command.

import Foundation
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
print("ax \(trusted ? 1 : 0)")

var leftDown = false
var lastDownAt = Date.distantPast, lastDownPt = CGPoint.zero, clicks: Int64 = 1
func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clickState: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: clickState)
    e.post(tap: .cghidEventTap)
}
func scroll(_ v: Int32, _ h: Int32, flags: CGEventFlags = []) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0) else { return }
    if !flags.isEmpty { e.flags = flags }
    e.post(tap: .cghidEventTap)
}
func notches(_ s: String) -> Int32 { Int32((Double(s) ?? 0) / 120.0) }

while let line = readLine() {
    let p = line.split(separator: " ").map(String.init)
    guard let cmd = p.first else { continue }
    let x = p.count > 2 ? Double(p[1]) ?? 0 : 0, y = p.count > 2 ? Double(p[2]) ?? 0 : 0
    let pt = CGPoint(x: x, y: y)
    switch cmd {
    case "move":
        post(leftDown ? .leftMouseDragged : .mouseMoved, pt)
    case "down":
        // double-click = second press within 0.4 s and a few points of the first one
        let now = Date()
        clicks = (now.timeIntervalSince(lastDownAt) < 0.4 && hypot(pt.x - lastDownPt.x, pt.y - lastDownPt.y) < 6) ? clicks + 1 : 1
        lastDownAt = now; lastDownPt = pt
        post(.mouseMoved, pt)
        post(.leftMouseDown, pt, clickState: clicks); leftDown = true
    case "up":
        post(.leftMouseUp, pt, clickState: clicks); leftDown = false
    case "rclick":
        post(.mouseMoved, pt)
        post(.rightMouseDown, pt, .right); post(.rightMouseUp, pt, .right)
    case "wheel":
        if p.count > 1 { scroll(notches(p[1]), 0) }
    case "hwheel":
        if p.count > 1 { scroll(0, -notches(p[1])) } // Windows: positive = right; macOS wheel2: positive = left
    case "zoom":
        if p.count > 1 { scroll(notches(p[1]), 0, flags: .maskCommand) } // Cmd+wheel zooms browsers and most apps
    case "pos":
        let l = CGEvent(source: nil)?.location ?? .zero
        print("pos \(Int(l.x)) \(Int(l.y))")
    case "quit":
        exit(0)
    default:
        continue
    }
}
