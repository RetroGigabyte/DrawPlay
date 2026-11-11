import Foundation

/// Thin wrapper around the `adb` tool, for USB mode. Apps opened from Finder have a minimal PATH,
/// so the usual install locations are searched directly.
enum Adb {
    struct Device: Identifiable, Hashable {
        let serial: String
        let state: String          // device, unauthorized, offline
        let model: String
        var id: String { serial }
        var ready: Bool { state == "device" }
    }

    static var path: String? {
        let env = ProcessInfo.processInfo.environment
        var candidates = [String]()
        for k in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] { if let v = env[k] { candidates.append(v + "/platform-tools/adb") } }
        candidates += [NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ args: [String]) async -> (code: Int32, output: String) {
        guard let exe = path else { return (127, "adb was not found. Install Android platform-tools (brew install android-platform-tools).") }
        return await Task.detached {
            // Output goes to a file, not a pipe: adb may start a background server that keeps a pipe open forever.
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("drawplay-adb-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: out) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let h = try? FileHandle(forWritingTo: out) { p.standardOutput = h; p.standardError = h }
            do { try p.run() } catch { return (1, "could not run adb: \(error.localizedDescription)") }
            p.waitUntilExit()
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    static func devices() async -> [Device] {
        let r = await run(["devices", "-l"])
        return r.output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("*") else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? "Android device"
            return Device(serial: parts[0], state: parts[1], model: model)
        }
    }
}
