// vdisplay: creates a virtual monitor with the private CGVirtualDisplay API and keeps it alive while the
// process runs (the display disappears when the object is released, i.e. when this process exits).
//
//   swiftc -O -import-objc-header CGVirtualDisplay.h vdisplay.swift -o vdisplay -framework CoreGraphics
//   ./vdisplay [width height [refresh]] [--hidpi] [--name "iPad Display"]
//
// Prints "display <CGDirectDisplayID> <w>x<h> @<hz> hidpi=<0|1>" on stdout once the display is up, then waits.
// Exits when stdin closes (the host went away) or on SIGTERM/SIGINT.

import Foundation
import CoreGraphics

var width = 1024, height = 768, hz = 60.0, hidpi = false, name = "iPad Display"
var positional: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--hidpi" { hidpi = true }
    else if a == "--name", !args.isEmpty { name = args.removeFirst() }
    else { positional.append(a) }
}
if positional.count >= 2, let w = Int(positional[0]), let h = Int(positional[1]) { width = w; height = h }
if positional.count >= 3, let r = Double(positional[2]) { hz = r }

let descriptor = CGVirtualDisplayDescriptor()
descriptor.setDispatchQueue(DispatchQueue.main)
descriptor.name = name
descriptor.maxPixelsWide = UInt32(width * 2)
descriptor.maxPixelsHigh = UInt32(height * 2)
descriptor.sizeInMillimeters = CGSize(width: 160, height: 120) // iPad mini: 7.9", 4:3 -> reasonable DPI
descriptor.productID = 0x1D15
descriptor.vendorID = 0x1D15
descriptor.serialNum = 1
descriptor.terminationHandler = { _, _ in
    FileHandle.standardError.write("vdisplay: display terminated by the system\n".data(using: .utf8)!)
    exit(2)
}

let display = CGVirtualDisplay(descriptor: descriptor)
let settings = CGVirtualDisplaySettings()
settings.hiDPI = hidpi ? 1 : 0
settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: hz)]
if !display.apply(settings) {
    FileHandle.standardError.write("vdisplay: applySettings failed\n".data(using: .utf8)!)
    exit(1)
}
print("display \(display.displayID) \(width)x\(height) @\(Int(hz)) hidpi=\(hidpi ? 1 : 0)")
fflush(stdout)

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
signal(SIGHUP) { _ in exit(0) }
// Parent gone -> stdin EOF -> exit, so a crashed host never leaves a phantom monitor behind.
DispatchQueue.global().async {
    while let line = readLine() { if line == "quit" { exit(0) } }
    exit(0)
}
RunLoop.main.run()
