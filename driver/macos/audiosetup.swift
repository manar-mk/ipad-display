// audiosetup: makes the iPad look like a sound card in System Settings -> Sound -> Output.
//
// Two devices are created around the virtual cable (BlackHole), because "send the sound to the iPad" means
// two different things:
//   «iPad Display»            -> the cable alone. Sound plays on the iPad and the Mac stays silent, the way an
//                                external monitor with speakers behaves. This is the one to pick normally.
//   «iPad Display + динамики» -> cable + built-in speakers: the same sound on both at once.
// Both are stacked aggregate devices, i.e. what Audio MIDI Setup calls a Multi-Output Device.
//
//   swiftc -O audiosetup.swift -o audiosetup -framework CoreAudio
//   ./audiosetup [cable-name-prefix] [--default] [--remove]     (cable prefix defaults to "BlackHole")
//     --default  also select «iPad Display» as the system output
//     --remove   delete both devices (and fall back to the built-in output if one of them was selected)

import Foundation
import CoreAudio

let IPAD_UID = "iPad Display Output"          // cable only
let BOTH_UID = "iPad Display Multi-Output"    // cable + speakers
let IPAD_NAME = "iPad Display"
let BOTH_NAME = "iPad Display + динамики"

func num(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size); var v: UInt32 = 0
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
func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var devs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devs)
    return devs
}
func defaultOutput() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size); var d = AudioDeviceID(0)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &d) == noErr ? d : 0
}
func setDefaultOutput(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}
func fail(_ m: String) -> Never { print(m); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
let selIdx = args.firstIndex(of: "--select")
let cablePrefix = args.enumerated().first(where: { !$0.element.hasPrefix("--") && $0.offset != (selIdx.map { $0 + 1 } ?? -1) })?.element ?? "BlackHole"

// Enumerate fresh every time: destroying one aggregate invalidates the AudioDeviceIDs handed out before it,
// so a list captured once goes stale after the first removal and the second device would survive.
struct Scan {
    var ours: [String: AudioDeviceID] = [:]
    var cable: String? = nil
    var speakers: String? = nil
    var speakerId: AudioDeviceID = 0
}
func scan(_ cablePrefix: String) -> Scan {
    var r = Scan()
    for d in allDevices() {
        guard let u = str(d, kAudioDevicePropertyDeviceUID) else { continue } // our aggregates are matched by UID, name may be absent
        if u == IPAD_UID || u == BOTH_UID { r.ours[u] = d; continue }
        guard let n = str(d, kAudioObjectPropertyName) else { continue }
        if n.hasPrefix(cablePrefix) && hasOutput(d) && r.cable == nil { r.cable = u }
        if num(d, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && hasOutput(d) && r.speakers == nil { r.speakers = u; r.speakerId = d }
    }
    return r
}

var s0 = scan(cablePrefix)
var cable = s0.cable, speakers = s0.speakers
let speakerId = s0.speakerId
var found = s0.ours

if args.contains("--remove") {
    let before = scan(cablePrefix).ours.count // distinct devices as the user sees them in System Settings
    // Tell the caller which of our devices the system was pointing at, so the next session can restore it.
    let sel = scan(cablePrefix).ours.first(where: { $0.value == defaultOutput() })?.key
    if let sel = sel { print("was-selected: \(sel)") }
    var removed = 0
    for _ in 0..<8 {
        let s = scan(cablePrefix)
        guard let victim = s.ours.first else { break }
        // hand the system back to the built-in output before the device it points at disappears
        if s.ours.values.contains(defaultOutput()) && s.speakerId != 0 { _ = setDefaultOutput(s.speakerId) }
        if AudioHardwareDestroyAggregateDevice(victim.value) == noErr { removed += 1 } else { break }
    }
    let left = scan(cablePrefix).ours.count
    if left > 0 { print("удалено устройств: \(before - left), осталось: \(left)"); exit(1) }
    _ = removed
    print(before > 0 ? "удалено устройств: \(before)" : "нечего удалять")
    exit(0)
}

guard let c = cable else { fail("не найдено устройство «\(cablePrefix)…» — установите виртуальный кабель: brew install blackhole-2ch") }

// Each device is a stacked aggregate: the cable alone, or the cable together with the built-in speakers.
func ensure(uid: String, name: String, subs: [String], main: String) -> AudioDeviceID {
    // Re-scan right before creating: CoreAudio happily makes a second aggregate with a UID that already
    // exists, and two invocations close together would otherwise leave duplicates behind.
    if let d = scan(cablePrefix).ours[uid] { return d }
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: name,
        kAudioAggregateDeviceUIDKey as String: uid,
        kAudioAggregateDeviceIsStackedKey as String: 1, // multi-output, not an aggregate input
        kAudioAggregateDeviceMainSubDeviceKey as String: main,
        kAudioAggregateDeviceSubDeviceListKey as String: subs.map { sub -> [String: Any] in
            sub == main ? [kAudioSubDeviceUIDKey as String: sub]
                        : [kAudioSubDeviceUIDKey as String: sub, kAudioSubDeviceDriftCompensationKey as String: 1]
        },
    ]
    var agg: AudioDeviceID = 0
    let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
    if st != noErr { fail("AudioHardwareCreateAggregateDevice(\(name)): \(st)") }
    return agg
}

let hadIpad = found[IPAD_UID] != nil, hadBoth = found[BOTH_UID] != nil
let ipadOnly = ensure(uid: IPAD_UID, name: IPAD_NAME, subs: [c], main: c)
// The cable is the master clock, not the speakers: a stacked aggregate driven by the built-in output
// leaves the BlackHole branch silent (sound reaches the Mac speakers and never the iPad), while the
// virtual device's clock is rock steady and the speakers take drift compensation happily.
var bothId: AudioDeviceID = 0
if let s = speakers { bothId = ensure(uid: BOTH_UID, name: BOTH_NAME, subs: [c, s], main: c) }
var made: [String] = []
if !hadIpad { made.append("«\(IPAD_NAME)» — звук только на iPad") }
if !hadBoth && speakers != nil { made.append("«\(BOTH_NAME)» — на iPad и на Mac сразу") }
print(made.isEmpty ? "устройства уже есть: «\(IPAD_NAME)», «\(BOTH_NAME)»" : "создано: " + made.joined(separator: "; "))

// --select <uid> restores a specific device (the one the user had chosen before the previous session ended)
let wanted = args.firstIndex(of: "--select").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
// Use the id ensure() just returned rather than looking the device up again: a device created a moment ago
// is not always in the next enumeration yet, and the restore would silently do nothing.
if let w = wanted, (w == BOTH_UID ? bothId : ipadOnly) != 0 {
    let name = w == BOTH_UID ? BOTH_NAME : IPAD_NAME
    print(setDefaultOutput(w == BOTH_UID ? bothId : ipadOnly) ? "вывод Mac возвращён на «\(name)»" : "не удалось вернуть вывод на «\(name)»")
} else if args.contains("--default") {
    if setDefaultOutput(ipadOnly) { print("вывод Mac переключён на «\(IPAD_NAME)» — звук идёт только на iPad") }
    else { print("выберите «\(IPAD_NAME)» в Системные настройки → Звук → Вывод") }
} else {
    print("выберите «\(IPAD_NAME)» в Системные настройки → Звук → Вывод")
}
