import CoreHID
import Foundation

var d: [UInt8] = [0x05,0x0D, 0x09,0x04, 0xA1,0x01, 0x85,0x01]
for _ in 0..<10 {
    d += [0x09,0x22, 0xA1,0x02,
          0x09,0x42, 0x09,0x32, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x02, 0x81,0x02,
          0x95,0x06, 0x81,0x03,
          0x09,0x51, 0x75,0x08, 0x95,0x01, 0x15,0x00, 0x26,0xFF,0x00, 0x81,0x02,
          0x05,0x01, 0x09,0x30, 0x09,0x31, 0x15,0x00, 0x26,0xFF,0x7F, 0x75,0x10, 0x95,0x02, 0x81,0x02,
          0x05,0x0D, 0xC0]
}
d += [0x09,0x54, 0x75,0x08, 0x95,0x01, 0x15,0x00, 0x25,0x0A, 0x81,0x02, 0xC0]

let props = HIDVirtualDevice.Properties(descriptor: Data(d), vendorID: 0x1209, productID: 0x0001,
                                         product: "DrawPlay Touch", manufacturer: "DrawPlay", serialNumber: "DP1")
if let dev = HIDVirtualDevice(properties: props) {
    print("device created (init ok)")
    final class Del: HIDVirtualDeviceDelegate {
        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {}
        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data { Data() }
    }
    await dev.activate(delegate: Del())
    print("activated")
    var r = [UInt8](repeating: 0, count: 62); r[0] = 1
    r[1] = 0x03; r[2] = 0; r[3] = 0x00; r[4] = 0x40; r[5] = 0x00; r[6] = 0x40; r[61] = 1
    do { try await dev.dispatchInputReport(data: Data(r), timestamp: .now); print("report sent") } catch { print("report error: \(error)") }
    try await Task.sleep(nanoseconds: 1_500_000_000)
} else { print("init returned nil (likely missing entitlement)") }
