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
let cablePrefix = args.first(where: { !$0.hasPrefix("--") }) ?? "BlackHole"

var cable: String? = nil, speakers: String? = nil, speakerId: AudioDeviceID = 0
var found: [String: AudioDeviceID] = [:]
for d in allDevices() {
    guard let n = str(d, kAudioObjectPropertyName), let u = str(d, kAudioDevicePropertyDeviceUID) else { continue }
    if u == IPAD_UID || u == BOTH_UID { found[u] = d; continue }
    if n.hasPrefix(cablePrefix) && hasOutput(d) && cable == nil { cable = u }
    if num(d, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && hasOutput(d) && speakers == nil { speakers = u; speakerId = d }
}

if args.contains("--remove") {
    let wasOurs = found.values.contains(defaultOutput())
    var removed = 0
    for (_, d) in found where AudioHardwareDestroyAggregateDevice(d) == noErr { removed += 1 }
    if wasOurs && speakerId != 0 { _ = setDefaultOutput(speakerId) } // never leave the system pointing at a device that is gone
    print(removed > 0 ? "удалено устройств: \(removed)" : "нечего удалять")
    exit(0)
}

guard let c = cable else { fail("не найдено устройство «\(cablePrefix)…» — установите виртуальный кабель: brew install blackhole-2ch") }

// Each device is a stacked aggregate: the cable alone, or the cable together with the built-in speakers.
func ensure(uid: String, name: String, subs: [String], main: String) -> AudioDeviceID {
    if let d = found[uid] { return d }
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
if let s = speakers { _ = ensure(uid: BOTH_UID, name: BOTH_NAME, subs: [s, c], main: s) }
var made: [String] = []
if !hadIpad { made.append("«\(IPAD_NAME)» — звук только на iPad") }
if !hadBoth && speakers != nil { made.append("«\(BOTH_NAME)» — на iPad и на Mac сразу") }
print(made.isEmpty ? "устройства уже есть: «\(IPAD_NAME)», «\(BOTH_NAME)»" : "создано: " + made.joined(separator: "; "))

if args.contains("--default") {
    if setDefaultOutput(ipadOnly) { print("вывод Mac переключён на «\(IPAD_NAME)» — звук идёт только на iPad") }
    else { print("выберите «\(IPAD_NAME)» в Системные настройки → Звук → Вывод") }
} else {
    print("выберите «\(IPAD_NAME)» в Системные настройки → Звук → Вывод")
}
