import Foundation

/// 24-byte little-endian wire packet, tablet -> Mac.
/// kind: 0 pen, 1 eraser, 2 finger, 3 key.
/// pointer action: 0 down, 1 move, 2 up, 3 hover, 4 hover-exit.
/// key packet: action 0 down / 1 up, `keyCode` = macOS virtual key code, `buttons` = modifier bits
/// (1 shift, 2 control, 4 option, 8 command).
struct Packet {
    static let size = 24
    var kind: UInt8, action: UInt8, pointer: UInt8, buttons: UInt8
    var x: Float, y: Float          // normalized 0...1 within tablet view
    var pressure: Float             // 0...1
    var tiltX: Float, tiltY: Float  // -1...1 (radians/(pi/2))
    var keyCode: UInt16             // key packets only (bytes 4-5)
    var echo: UInt64                // kind 7 (ping reply): the 8 bytes the Mac sent, bytes 4-11

    init?(_ d: Data) {
        guard d.count == Packet.size else { return nil }
        let b = [UInt8](d)
        func f(_ o: Int) -> Float {
            Float(bitPattern: UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24)
        }
        kind = b[0]; action = b[1]; pointer = b[2]; buttons = b[3]
        x = f(4); y = f(8); pressure = f(12); tiltX = f(16); tiltY = f(20)
        keyCode = UInt16(b[4]) | UInt16(b[5]) << 8
        echo = (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[4 + $1]) << UInt64(8 * $1) }
    }
}
