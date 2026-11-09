import Foundation
import CoreBluetooth

/// Wire protocol shared with the Android VibePad app.
///
/// Audio is a byte stream: every 40 ms the phone emits
/// [version=1][type=1][seq][flags] followed by 160 bytes of IMA ADPCM
/// (8 kHz mono, 4 bit per sample = 4 KB/s).
///
/// The link between this Mac and the phone measures at roughly 4 KB/s: macOS
/// settles on a 50–60 ms connection interval and the controller carries one
/// notification per event. 16 kHz μ-law needed 8 KB/s and lost half of its
/// packets, which is what produced dropouts and growing latency. 8 kHz ADPCM
/// is the highest quality that fits the measured budget.
///
/// The parser upsamples 8 kHz → 16 kHz so the rest of the pipeline (gate,
/// AudioSink) stays at 16 kHz.
enum PhoneProtocol {
    static let service = CBUUID(string: "7A1B0001-4C3D-4E5F-8A9B-0C1D2E3F4A01")
    static let audio = CBUUID(string: "7A1B0002-4C3D-4E5F-8A9B-0C1D2E3F4A01")
    static let control = CBUUID(string: "7A1B0003-4C3D-4E5F-8A9B-0C1D2E3F4A01")

    static let headerBytes = 4
    static let frameBytes = 160
    static let packetBytes = headerBytes + frameBytes

    static let version: UInt8 = 1
    static let typeAudio: UInt8 = 1
    static let typeControl: UInt8 = 2
    /// 闪念胶囊同步（手机 → Mac 上传，独立 TCP 连接，复用同一端口）。
    static let typeCapsule: UInt8 = 5
    /// 胶囊上传回执（Mac → 手机）。
    static let typeCapsuleAck: UInt8 = 6
    /// 转写结果（Mac → 手机）。
    static let typeCapsuleText: UInt8 = 7

    static let opStop: UInt8 = 0x00
    static let opStart: UInt8 = 0x01
    static let opReady: UInt8 = 0x02
    static let opHeartbeat: UInt8 = 0x03
    static let opStatus: UInt8 = 0x04

    // 胶囊帧 payload 的第一个字节。
    static let capBegin: UInt8 = 0x01
    static let capData: UInt8 = 0x02
    static let capEnd: UInt8 = 0x03
    /// 手机把本地胶囊 id 列表发过来，Mac 把已有的转写文本补回去。
    static let capQuery: UInt8 = 0x04
}

/// IMA/DVI ADPCM decoder matching the Android encoder bit-for-bit.
final class PhoneAdpcmDecoder {
    private var predictor = 0
    private var index = 0

    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
        1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767
    ]

    private static let indexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    func reset() {
        predictor = 0
        index = 0
    }

    func decode(_ bytes: [UInt8]) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(Int16(clamping: decodeNibble(Int(byte & 0x0F))))
            out.append(Int16(clamping: decodeNibble(Int((byte >> 4) & 0x0F))))
        }
        return out
    }

    private func decodeNibble(_ code: Int) -> Int {
        let step = Self.stepTable[index]
        var diff = step >> 3
        if code & 1 != 0 { diff += step >> 2 }
        if code & 2 != 0 { diff += step >> 1 }
        if code & 4 != 0 { diff += step }
        predictor += (code & 8 != 0) ? -diff : diff
        predictor = min(max(predictor, -32768), 32767)
        index = min(max(index + Self.indexTable[code], 0), 88)
        return predictor
    }
}

struct PhoneAudioParser {
    private var buffer: [UInt8] = []
    private var decoder = PhoneAdpcmDecoder()
    /// Last 8 kHz sample, carried across packets so the interpolated 16 kHz
    /// stream has no discontinuity at packet boundaries.
    private var lastSample: Int16 = 0

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        decoder.reset()
        lastSample = 0
    }

    mutating func append(_ data: Data) -> [Int16] {
        buffer.append(contentsOf: data)
        var out: [Int16] = []
        while buffer.count >= PhoneProtocol.packetBytes {
            if buffer[0] != PhoneProtocol.version || buffer[1] != PhoneProtocol.typeAudio {
                buffer.removeFirst()
                continue
            }
            let packet = Array(buffer.prefix(PhoneProtocol.packetBytes))
            buffer.removeFirst(PhoneProtocol.packetBytes)
            let payload = Array(packet[PhoneProtocol.headerBytes..<PhoneProtocol.packetBytes])
            let narrow = decoder.decode(payload)
            var previous = lastSample
            out.reserveCapacity(out.count + narrow.count * 2)
            for sample in narrow {
                out.append(previous)
                out.append(Int16((Int(previous) + Int(sample)) / 2))
                previous = sample
            }
            lastSample = previous
        }
        if buffer.count > 8192 {
            buffer.removeAll(keepingCapacity: true)
        }
        return out
    }
}
