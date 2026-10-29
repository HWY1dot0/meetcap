// audiotap: 用 Core Audio process tap (macOS 14.4+) 抓系统音频, 输出 raw PCM 到 stdout
//
// 用法:  audiotap            全局系统混音 (mono)
// 输出:  stdout = f32le 裸 PCM; stderr 首行 = {"sample_rate":..,"channels":..} JSON
// 停止:  SIGINT/SIGTERM 优雅清理; 下游管道关闭时自动退出
//
// 编译:  swiftc -O audiotap.swift -o audiotap
//
// 设计: 不碰用户默认输出设备与聚合配置, 听音链路零侵入(替代 BlackHole/Multi-Output 方案)

import AudioToolbox
import CoreAudio
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("audiotap: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// ---- 1. 建全局 mono tap (混所有进程的输出) ----
let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
desc.name = "audiotap"
desc.muteBehavior = .unmuted
desc.isPrivate = true

var tapID = AudioObjectID(kAudioObjectUnknown)
var err = AudioHardwareCreateProcessTap(desc, &tapID)
guard err == noErr else { die("create tap failed (\(err)) — 需要 macOS 14.4+ 与系统音频录制权限") }

// ---- 2. 读 tap 的流格式 ----
var fmt = AudioStreamBasicDescription()
var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var fmtAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &fmt)
guard err == noErr else { die("get tap format failed (\(err))") }

// ---- 3. 建私有聚合设备, 挂上 tap ----
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "audiotap-agg",
    kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceTapAutoStartKey as String: true,
    kAudioAggregateDeviceTapListKey as String: [
        [kAudioSubTapUIDKey as String: desc.uuid.uuidString]
    ],
]
var aggID = AudioObjectID(0)
err = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
guard err == noErr else { die("create aggregate failed (\(err))") }

var procID: AudioDeviceIOProcID?
var cleanedUp = false
func cleanup() {
    if cleanedUp { return }
    cleanedUp = true
    if let p = procID {
        AudioDeviceStop(aggID, p)
        AudioDeviceDestroyIOProcID(aggID, p)
    }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
}

// ---- 4. IOProc: tap 数据写 stdout; 管道断(EPIPE)则退出 ----
signal(SIGPIPE, SIG_IGN)
err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inInputData))
    for buf in abl {
        guard let p = buf.mData, buf.mDataByteSize > 0 else { continue }
        var off = 0
        let total = Int(buf.mDataByteSize)
        while off < total {
            let n = write(1, p.advanced(by: off), total - off)
            if n <= 0 {  // 下游关闭
                cleanup()
                exit(0)
            }
            off += n
        }
    }
}
guard err == noErr, procID != nil else { die("create ioproc failed (\(err))") }

err = AudioDeviceStart(aggID, procID)
guard err == noErr else { die("start failed (\(err)) — 检查系统设置里的系统音频录制权限") }

FileHandle.standardError.write(
    ("{\"sample_rate\": \(Int(fmt.mSampleRate)), \"channels\": \(Int(fmt.mChannelsPerFrame)), \"format\": \"f32le\"}\n")
        .data(using: .utf8)!)

// ---- 5. 信号处理 + 保活 ----
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for src in [sigInt, sigTerm] {
    src.setEventHandler { cleanup(); exit(0) }
    src.resume()
}
dispatchMain()
