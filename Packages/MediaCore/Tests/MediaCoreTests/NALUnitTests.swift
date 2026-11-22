import Foundation
import Testing
@testable import MediaCore

@Suite struct NALUnitTests {
    // HEVC header bytes: VPS 0x40, SPS 0x42, PPS 0x44, IDR_W_RADL 0x26, TRAIL_R 0x02.
    let vps = Data([0x40, 0x01, 0x0C, 0x01])
    let sps = Data([0x42, 0x01, 0x01, 0x01, 0x60])
    let pps = Data([0x44, 0x01, 0xC1, 0x72])
    let idr = Data([0x26, 0x01, 0xAF, 0x00, 0x00, 0x03, 0x00, 0x11])
    let trail = Data([0x02, 0x01, 0xD0, 0x09])

    @Test func annexBRoundTrip() {
        let units = [vps, sps, pps, idr]
        #expect(AnnexB.split(AnnexB.join(units)) == units)
    }

    @Test func annexBAcceptsThreeByteStartCodesAndTrailingZeros() {
        var stream = Data([0x00, 0x00, 0x01])
        stream.append(sps)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x01])
        stream.append(trail)
        #expect(AnnexB.split(stream) == [sps, trail])
    }

    @Test func annexBIgnoresLeadingGarbage() {
        var stream = Data([0xFF, 0xEE])
        stream.append(AnnexB.join([trail]))
        #expect(AnnexB.split(stream) == [trail])
    }

    @Test func lengthPrefixedRoundTrip() {
        let units = [vps, sps, pps, idr, trail]
        #expect(LengthPrefixed.split(LengthPrefixed.join(units)) == units)
    }

    @Test func lengthPrefixedRejectsTruncation() {
        let joined = LengthPrefixed.join([idr])
        #expect(LengthPrefixed.split(joined.dropLast()) == nil)
    }

    @Test func lengthPrefixedToAnnexBAndBack() {
        let units = [vps, sps, pps, idr]
        let annexB = AnnexB.join(LengthPrefixed.split(LengthPrefixed.join(units))!)
        #expect(LengthPrefixed.join(AnnexB.split(annexB)) == LengthPrefixed.join(units))
    }

    @Test func hevcTypes() {
        let codec = VideoCodec.hevc
        #expect([vps, sps, pps].allSatisfy(codec.isParameterSet))
        #expect(!codec.isParameterSet(idr))
        #expect(codec.isKeyFrameSlice(idr))
        #expect(!codec.isKeyFrameSlice(trail))
    }

    @Test func h264Types() {
        let codec = VideoCodec.h264
        #expect(codec.isParameterSet(Data([0x67, 0x64])))
        #expect(codec.isParameterSet(Data([0x68, 0xEE])))
        #expect(codec.isKeyFrameSlice(Data([0x65, 0x88])))
        #expect(!codec.isKeyFrameSlice(Data([0x41, 0x9A])))
    }
}

@Suite struct LatestSlotTests {
    @Test func idleStageStartsImmediately() {
        let slot = LatestSlot<Int>()
        #expect(slot.offer(1) == 1)
        #expect(slot.finish() == nil)
        #expect(slot.offer(2) == 2)
    }

    @Test func busyStageKeepsOnlyNewest() {
        let slot = LatestSlot<Int>()
        #expect(slot.offer(1) == 1)
        #expect(slot.offer(2) == nil)
        #expect(slot.offer(3) == nil)
        #expect(slot.takeReplacedCount() == 1)
        #expect(slot.finish() == 3)
        #expect(slot.finish() == nil)
        #expect(slot.offer(4) == 4)
    }
}

@Suite struct HostClockTests {
    @Test func secondsRoundTrip() {
        let ticks = HostClock.ticks(seconds: 1.5)
        #expect(abs(HostClock.seconds(ticks) - 1.5) < 1e-6)
        #expect(abs(HostClock.milliseconds(from: 0, to: HostClock.ticks(seconds: 0.25)) - 250) < 1e-3)
    }
}
