// Stats snapshots, signposts, logging categories.

/// The block-coded frame counter drawn by the test pattern app and read back from decoded frames.
///
/// Layout, left to right, one block per cell:
///
///     [W][B] [24 data bits, MSB first] [P] [B][W]
///
/// The two guard cells at each end give the reader a white and a black reference level and mark
/// the row's ends. Data bits carry the counter in Gray code, so a frame captured while the counter
/// changes reads as one of the two neighbouring values instead of garbage. `P` makes the count of
/// set data bits even. White is `true`.
public enum FrameCode {
    public static let dataBits = 24
    public static let cellCount = 2 + dataBits + 1 + 2
    public static let modulus: UInt32 = 1 << UInt32(dataBits)

    /// Cells for `counter`. Counters wrap at 2^24, which is about 39 hours at 120 Hz.
    public static func encode(_ counter: UInt32) -> [Bool] {
        let value = counter % modulus
        let gray = value ^ (value >> 1)
        var cells: [Bool] = [true, false]
        var ones = 0
        for bit in stride(from: dataBits - 1, through: 0, by: -1) {
            let set = (gray >> UInt32(bit)) & 1 == 1
            if set { ones += 1 }
            cells.append(set)
        }
        cells.append(ones % 2 == 1)
        cells.append(contentsOf: [false, true])
        return cells
    }

    /// The counter carried by `cells`, or nil if the guards or parity do not match.
    public static func decode(_ cells: [Bool]) -> UInt32? {
        guard cells.count == cellCount,
              cells[0], !cells[1],
              !cells[cellCount - 2], cells[cellCount - 1]
        else { return nil }
        let data = cells[2..<(2 + dataBits)]
        let ones = data.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard (ones % 2 == 1) == cells[2 + dataBits] else { return nil }
        var gray: UInt32 = 0
        for set in data { gray = (gray << 1) | (set ? 1 : 0) }
        var value = gray
        var shift = gray >> 1
        while shift != 0 {
            value ^= shift
            shift >>= 1
        }
        return value
    }
}
