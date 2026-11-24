// audiotap: 用 Core Audio process tap (macOS 14.4+) 抓系统音频, 输出 raw PCM 到 stdout
//
// 用法:  audiotap                        全局系统混音 (mono)
//        audiotap --only <路径>           只抓可执行文件在该路径下的进程(如 /Applications/zoom.us.app)
//        audiotap --exclude-from <目录>   全局混音, 但排除目录里登记的应用。目录里每个文件代表一场
//                                         只录某应用的录音: 文件名 = 那场录音的 pid, 内容 = 应用路径;
//                                         那个 pid 已不在就忽略
// 输出:  stdout = f32le 裸 PCM; stderr 首行 = {"sample_rate":..,"channels":..} JSON
// 停止:  SIGINT/SIGTERM 优雅清理; 下游管道关闭时自动退出
//
// 编译:  swiftc -O audiotap.swift -o audiotap
//
// 设计: 不碰用户默认输出设备与聚合配置, 听音链路零侵入(替代 BlackHole/Multi-Output 方案)。
//       --only / --exclude-from 的进程名单每秒重算一次: 会议软件晚于录音启动、
//       中途换了出声的子进程、另一场录音开始或结束, 都能跟上。

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("audiotap: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// ---- 0. 参数 ----
var onlyPath: String?
var excludeDir: String?
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let flag = argv.removeFirst()
    guard !argv.isEmpty else { die("\(flag) 缺少参数") }
    switch flag {
    case "--only": onlyPath = argv.removeFirst()
    case "--exclude-from": excludeDir = argv.removeFirst()
    default: die("未知参数 \(flag)")
    }
}
if onlyPath != nil && excludeDir != nil { die("--only 与 --exclude-from 不能同时用") }

// ---- 1. 找出名单里的进程(Core Audio 的进程对象) ----
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

/// 路径 → 以 "/" 结尾的前缀: 应用包里的主程序和各个 helper 都算这个应用
func prefix(_ path: String) -> String {
    let p = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath
    return p.hasSuffix("/") ? p : p + "/"
}

/// 系统记的「这个进程替哪个应用干活」: Safari 等应用的声音由系统的 WebKit 进程代出,
/// 可执行文件不在应用包里, 得靠归属关系认。私有接口, 取不到就只按路径认
typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
let responsiblePid = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFn.self) }

func executable(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

/// 属于这些应用(可执行文件在其路径下, 或归属于它)、且正在使用音频的进程
func audioProcesses(under prefixes: [String]) -> [AudioObjectID] {
    guard !prefixes.isEmpty else { return [] }
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
    func listed(_ exe: String?) -> Bool {
        guard let exe else { return false }
        return prefixes.contains { exe.hasPrefix($0) || exe + "/" == $0 }
    }
    var matched: [AudioObjectID] = []
    for obj in objects {
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddr = address(kAudioProcessPropertyPID)
        guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }
        var mine = listed(executable(pid))
        if !mine, let owner = responsiblePid?(pid), owner > 0, owner != pid { mine = listed(executable(owner)) }
        if mine { matched.append(obj) }
    }
    return matched.sorted()
}

/// 当前该抓(--only)或该排除(--exclude-from)的进程
func listedProcesses() -> [AudioObjectID] {
    if let onlyPath { return audioProcesses(under: [prefix(onlyPath)]) }
    guard let excludeDir,
          let names = try? FileManager.default.contentsOfDirectory(atPath: excludeDir) else { return [] }
    var prefixes: [String] = []
    for name in names {
        guard let pid = pid_t(name), kill(pid, 0) == 0,  // 登记者还活着才算数
              let path = try? String(contentsOfFile: excludeDir + "/" + name, encoding: .utf8),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        prefixes.append(prefix(path))
    }
    return audioProcesses(under: prefixes)
}

func describe(_ processes: [AudioObjectID]) -> CATapDescription {
    let desc = onlyPath != nil
        ? CATapDescription(monoMixdownOfProcesses: processes)
        : CATapDescription(monoGlobalTapButExcludeProcesses: processes)
    desc.name = "audiotap"
    desc.muteBehavior = .unmuted
    desc.isPrivate = true
    return desc
}

// ---- 2. 建 tap + 私有聚合设备 + IOProc; 名单变了就整套重建 ----
var tapID = AudioObjectID(kAudioObjectUnknown)
var aggID = AudioObjectID(kAudioObjectUnknown)
var procID: AudioDeviceIOProcID?
var fmt = AudioStreamBasicDescription()
var lastData = DispatchTime.now().uptimeNanoseconds   // 最近一次收到音频数据(IOProc 线程写, 主线程读)
var lastBuild = DispatchTime.now().uptimeNanoseconds

func teardown() {
    if let p = procID {
        AudioDeviceStop(aggID, p)
        AudioDeviceDestroyIOProcID(aggID, p)
        procID = nil
    }
    if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    aggID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
}

var cleanedUp = false
func cleanup() {
    if cleanedUp { return }
    cleanedUp = true
    teardown()
}

/// 成功返回 nil, 失败返回原因
func start(_ processes: [AudioObjectID]) -> String? {
    let desc = onlyPath != nil
        ? CATapDescription(monoMixdownOfProcesses: processes)
        : CATapDescription(monoGlobalTapButExcludeProcesses: processes)
    desc.name = "audiotap"
    desc.muteBehavior = .unmuted
    desc.isPrivate = true
    var err = AudioHardwareCreateProcessTap(desc, &tapID)
    guard err == noErr else { return "create tap failed (\(err)) — 需要 macOS 14.4+ 与系统音频录制权限" }

    var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var fmtAddr = address(kAudioTapPropertyFormat)
    err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &fmt)
    guard err == noErr else { return "get tap format failed (\(err))" }

    let aggDict: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "audiotap-agg",
        kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceTapAutoStartKey as String: true,
        kAudioAggregateDeviceTapListKey as String: [
            [kAudioSubTapUIDKey as String: desc.uuid.uuidString]
        ],
    ]
    err = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
    guard err == noErr else { return "create aggregate failed (\(err))" }

    // tap 数据写 stdout; 管道断(EPIPE)则退出
    err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, _, _ in
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))
        lastData = DispatchTime.now().uptimeNanoseconds
        for buf in abl {
            guard let p = buf.mData, buf.mDataByteSize > 0 else { continue }
            var off = 0
            let total = Int(buf.mDataByteSize)
            while off < total {
                let n = write(1, p.advanced(by: off), total - off)
                if n <= 0 { exit(0) }  // 下游关闭; 进程退出时系统回收 tap 与聚合设备
                off += n
            }
        }
    }
    guard err == noErr, procID != nil else { return "create ioproc failed (\(err))" }
    err = AudioDeviceStart(aggID, procID)
    guard err == noErr else { return "start failed (\(err)) — 检查系统设置里的系统音频录制权限" }
    lastBuild = DispatchTime.now().uptimeNanoseconds
    return nil
}

/// 名单里有进程正在出声
func anyPlaying(_ processes: [AudioObjectID]) -> Bool {
    processes.contains { obj in
        var playing: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &playing) == noErr && playing != 0
    }
}

signal(SIGPIPE, SIG_IGN)
var current = listedProcesses()
if let problem = start(current) { die(problem) }

FileHandle.standardError.write(
    ("{\"sample_rate\": \(Int(fmt.mSampleRate)), \"channels\": \(Int(fmt.mChannelsPerFrame)), \"format\": \"f32le\"}\n")
        .data(using: .utf8)!)

/// 名单变了就整套重建(tap 的进程名单建好后改不了; 断流约零点几秒)。
/// 另有一道保险: 只录的应用明明在出声, 却 3 秒没收到数据, 也重建一次(10 秒内最多一次)
func refresh() {
    let now = listedProcesses()
    let clock = DispatchTime.now().uptimeNanoseconds
    // lastData 由音频线程随时更新, 可能比 clock 还新: 无符号数直接相减会溢出崩溃
    func seconds(since t: UInt64) -> Double { clock > t ? Double(clock - t) / 1e9 : 0 }
    let stalled = onlyPath != nil && now == current && anyPlaying(now)
        && seconds(since: lastData) > 3 && seconds(since: lastBuild) > 10
    guard now != current || stalled else { return }
    if stalled { FileHandle.standardError.write("audiotap: 应用在出声但没收到数据, 重建\n".data(using: .utf8)!) }
    current = now
    teardown()
    if let problem = start(now) { die(problem) }
}

var watcher: DispatchSourceTimer?
if onlyPath != nil || excludeDir != nil {
    // 有进程开始或停止使用音频时系统立刻通知; 每秒再查一次, 兜住登记目录的变化
    var listAddr = address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, .main) { _, _ in refresh() }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1.0)
    timer.setEventHandler { refresh() }
    timer.resume()
    watcher = timer
}

// ---- 7. 信号处理 + 保活 ----
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for src in [sigInt, sigTerm] {
    src.setEventHandler { cleanup(); exit(0) }
    src.resume()
}
dispatchMain()
