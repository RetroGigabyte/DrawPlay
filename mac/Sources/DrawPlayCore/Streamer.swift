import Foundation
import Network

/// Owns the current tablet connection: checks the hello, receives input packets, sends video frames.
/// Tablet -> Mac: 8-byte hello ("DPLY" + u32 PIN, little-endian), then 24-byte input packets.
/// Mac -> tablet: [u8 type][u32 length LE][payload].
final class Streamer {
    private var conn: NWConnection?
    private var inflight = 0
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var bytesSent: UInt64 = 0
    var isConnected: Bool { conn != nil }

    private static let magic: [UInt8] = [0x44, 0x50, 0x4C, 0x59]   // "DPLY"

    /// `authenticate` receives the PIN from the hello and says whether to let this tablet in.
    func accept(_ c: NWConnection, authenticate: @escaping (UInt32) -> Bool) {
        c.start(queue: .main)
        // A connection that never says hello is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak c] in
            guard let c, let self, self.conn !== c, c.state != .cancelled, !self.helloSeen.contains(ObjectIdentifier(c)) else { return }
            c.cancel()
        }
        read(c, Data(), authed: false, authenticate: authenticate)
    }

    private var helloSeen = Set<ObjectIdentifier>()

    private func read(_ c: NWConnection, _ buf: Data, authed: Bool, authenticate: @escaping (UInt32) -> Bool) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            var ok = authed
            if let data { b.append(data) }
            if !ok, b.count >= 8 {
                self.helloSeen.insert(ObjectIdentifier(c))
                let bytes = [UInt8](b.prefix(8))
                let pin = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
                guard Array(bytes[0..<4]) == Streamer.magic, authenticate(pin) else { c.cancel(); return }
                b = Data(b.dropFirst(8))
                ok = true
                self.conn?.cancel()                      // only a verified tablet may replace the current one
                self.conn = c; self.inflight = 0
                self.onLog?("tablet connected: \(c.endpoint)")
                self.onConnect?()
            }
            if ok {
                while b.count >= Packet.size {
                    if let p = Packet(b.prefix(Packet.size)) { self.onPacket?(p) }
                    b = Data(b.dropFirst(Packet.size))
                }
            }
            if done || err != nil {
                if self.conn === c { self.conn = nil; self.onLog?("tablet disconnected"); self.onDisconnect?() }
                return
            }
            self.read(c, b, authed: ok, authenticate: authenticate)
        }
    }

    func close() {
        conn?.cancel(); conn = nil
    }

    /// Returns false if the frame was dropped because the link is backed up.
    @discardableResult
    func send(type: UInt8, _ payload: Data) -> Bool {
        guard let c = conn else { return false }
        if type == 3 && inflight > 4 { return false }
        var msg = Data([type])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { msg.append(contentsOf: $0) }
        msg.append(payload)
        inflight += 1
        bytesSent += UInt64(msg.count)
        c.send(content: msg, completion: .contentProcessed { [weak self] _ in DispatchQueue.main.async { self?.inflight -= 1 } })
        return true
    }
}
