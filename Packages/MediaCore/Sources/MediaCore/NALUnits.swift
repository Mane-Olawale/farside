import Foundation

/// Annex B byte streams: NAL units separated by 00 00 01 or 00 00 00 01 start codes.
public enum AnnexB {
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// NAL unit payloads, without start codes. Bytes before the first start code are ignored.
    public static func split(_ stream: Data) -> [Data] {
        stream.withUnsafeBytes { raw -> [Data] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var units: [Data] = []
            var unitStart: Int? = nil
            var i = 0
            while i + 2 < count {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    if let start = unitStart {
                        // A zero before the 3-byte code belongs to a 4-byte start code or to
                        // trailing_zero_8bits, never to the NAL unit.
                        var end = i
                        while end > start, bytes[end - 1] == 0 { end -= 1 }
                        units.append(Data(UnsafeRawBufferPointer(rebasing: raw[start..<end])))
                    }
                    i += 3
                    unitStart = i
                } else {
                    i += 1
                }
            }
            if let start = unitStart, start < count {
                units.append(Data(UnsafeRawBufferPointer(rebasing: raw[start..<count])))
            }
            return units
        }
    }

    /// Joins NAL units with 4-byte start codes.
    public static func join(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            out.append(contentsOf: startCode)
            out.append(unit)
        }
        return out
    }
}

/// The format VideoToolbox uses: each NAL unit preceded by its big-endian length.
public enum LengthPrefixed {
    /// NAL unit payloads, or nil if a length runs past the end of the data.
    public static func split(_ data: Data, prefixLength: Int = 4) -> [Data]? {
        precondition((1...4).contains(prefixLength))
        return data.withUnsafeBytes { raw -> [Data]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var units: [Data] = []
            var i = 0
            while i < bytes.count {
                guard i + prefixLength <= bytes.count else { return nil }
                var length = 0
                for k in 0..<prefixLength { length = (length << 8) | Int(bytes[i + k]) }
                i += prefixLength
                guard length > 0, i + length <= bytes.count else { return nil }
                units.append(Data(UnsafeRawBufferPointer(rebasing: raw[i..<(i + length)])))
                i += length
            }
            return units
        }
    }

    /// Joins NAL units with 4-byte big-endian lengths.
    public static func join(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let n = UInt32(unit.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            out.append(unit)
        }
        return out
    }
}
