// audiosetup: creates the macOS Multi-Output Device "iPad Display + динамики" = virtual cable (BlackHole 2ch)
// + built-in speakers, so that system sound plays on the Mac and is captured for the iPad at the same time
// (the same thing as Audio MIDI Setup -> "+" -> Create Multi-Output Device). Select it as the output in
// System Settings -> Sound.
//
//   swiftc -O audiosetup.swift -o audiosetup -framework CoreAudio
//   ./audiosetup [cable-name-prefix]   (default "BlackHole")   |   ./audiosetup --remove

import Foundation
import CoreAudio

let MULTI_UID = "iPad Display Multi-Output"
func prop<T>(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size); var v = zero
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
}
func str(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size); var s: CFString? = nil
    let st = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
    return st == noErr ? s as String? : nil
}
func hasOutput(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0; AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size); return size > 0
}
func fail(_ m: String) -> Never { print(m); exit(1) }

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var devs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devs)

let args = Array(CommandLine.arguments.dropFirst())
let cablePrefix = args.first(where: { !$0.hasPrefix("--") }) ?? "BlackHole"
var cable: String? = nil, speakers: String? = nil, existing: AudioDeviceID = 0
for d in devs {
    guard let n = str(d, kAudioObjectPropertyName), let u = str(d, kAudioDevicePropertyDeviceUID) else { continue }
    if u == MULTI_UID { existing = d; continue }
    if n.hasPrefix(cablePrefix) && hasOutput(d) && cable == nil { cable = u }
    if prop(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn && hasOutput(d) && speakers == nil { speakers = u }
}
if args.contains("--remove") {
    if existing == 0 { print("нет устройства «iPad Display + динамики»"); exit(0) }
    let st = AudioHardwareDestroyAggregateDevice(existing)
    if st != noErr { fail("AudioHardwareDestroyAggregateDevice: \(st)") }
    print("удалено")
    exit(0)
}
if existing != 0 { print("устройство «iPad Display + динамики» уже есть — выберите его в Системные настройки → Звук → Вывод"); exit(0) }
guard let c = cable else { fail("не найдено устройство «\(cablePrefix)…» — установите его: brew install blackhole-2ch") }
guard let s = speakers else { fail("не найден встроенный вывод (динамики)") }
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "iPad Display + динамики",
    kAudioAggregateDeviceUIDKey as String: MULTI_UID,
    kAudioAggregateDeviceIsStackedKey as String: 1, // multi-output, not an aggregate input
    kAudioAggregateDeviceMainSubDeviceKey as String: s,
    kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: s], [kAudioSubDeviceUIDKey as String: c, kAudioSubDeviceDriftCompensationKey as String: 1]],
]
var agg: AudioDeviceID = 0
let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
if st != noErr { fail("AudioHardwareCreateAggregateDevice: \(st)") }
print("создано устройство «iPad Display + динамики» (\(c) + динамики) — выберите его в Системные настройки → Звук → Вывод")
