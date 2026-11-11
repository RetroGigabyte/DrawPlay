import DrawPlayCore
import Foundation

// usage: drawplayd [usb|wifi] [--size 2560x1600] [--orientation auto|landscape|portrait] [--hidpi] [--port 7878] [--pin 123456] [--probe]
//   usb  (default): only local connections; run `adb reverse tcp:7878 tcp:7878`, tablet host 127.0.0.1
//   wifi          : tablet connects to this Mac's IP and must send the PIN
var cfg = Session.Config(mode: .usb)
var probe = false
var probeRotate = false
var selfTest = false
var awakeProbe = false
var encodeProbe = false
var encodeNoise = false
var encodeVideo = false
var inputTest = false
var focusProbe: String?
var pinGiven = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "usb": cfg.mode = .usb
    case "wifi": cfg.mode = .wifi
    case "--hidpi": cfg.hidpi = true
    case "--selftest-touch": selfTest = true
    case "--quality": if let v = it.next(), let q = VideoQuality(rawValue: v) { cfg.quality = q }
    case "--probe-encode": encodeProbe = true
    case "--noise": encodeNoise = true
    case "--video": encodeVideo = true
    case "--selftest-input": inputTest = true
    case "--probe-awake": awakeProbe = true
    case "--probe-focus": focusProbe = it.next()
    case "--probe": probe = true
    case "--probe-rotate": probe = true; probeRotate = true
    case "--portrait": cfg.orientation = .portrait
    case "--orientation": if let v = it.next(), let o = OrientationMode(rawValue: v) { cfg.orientation = o }
    case "--port": if let v = it.next(), let n = UInt16(v) { cfg.port = n }
    case "--pin": if let v = it.next(), let n = UInt32(v) { cfg.pin = n; pinGiven = true }
    case "--size":
        if let v = it.next() {
            let p = v.lowercased().split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { cfg.pixelWidth = p[0]; cfg.pixelHeight = p[1] }
        }
    default: print("unknown option \(a)"); exit(2)
    }
}

if encodeProbe {
    print(EncoderProbe.run(quality: cfg.quality, width: cfg.pixelWidth, height: cfg.pixelHeight, noise: encodeNoise, video: encodeVideo))
    exit(0)
}

if awakeProbe {
    print(SleepProbe.hold(seconds: 4) ? "held sleep assertions for 4 s" : "could not create assertions")
    exit(0)
}

if let app = focusProbe {
    Task { @MainActor in
        print(await FocusProbe.run(appName: app))
        exit(0)
    }
    RunLoop.main.run()
}

if inputTest {
    Task { @MainActor in
        let r = await InputSelfTest.run()
        print(r.report)
        exit(r.passed ? 0 : 1)
    }
    RunLoop.main.run()
}

if selfTest {
    Task { @MainActor in
        let r = await TouchSelfTest.run()
        print(r.report)
        exit(r.passed ? 0 : 1)
    }
    RunLoop.main.run()
}

if probe {
    let p = cfg.orientation == .portrait
    print(DisplayProbe.run(pixelWidth: p ? cfg.pixelHeight : cfg.pixelWidth, pixelHeight: p ? cfg.pixelWidth : cfg.pixelHeight, hidpi: cfg.hidpi, rotate: probeRotate))
    exit(0)
}
if cfg.mode == .wifi, !pinGiven { cfg.pin = UInt32.random(in: 100_000...999_999) }
if cfg.mode == .wifi { print("Wi-Fi PIN: \(String(format: "%06u", cfg.pin))  (enter it in the tablet app)") }

let sessionConfig = cfg
Task { @MainActor in
    let session = Session(config: sessionConfig)
    session.onEnded = { print($0); exit(1) }
    do { try await session.start() } catch { print("error: \(error.localizedDescription)"); exit(1) }
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler { Task { @MainActor in await session.stop(); exit(0) } }
    src.resume()
    withExtendedLifetime(src) { }
    // keep `src` alive
    Holder.src = src
}
enum Holder { nonisolated(unsafe) static var src: DispatchSourceSignal? }
RunLoop.main.run()      // services timers and the main queue (dispatchMain() would not run run-loop timers)
