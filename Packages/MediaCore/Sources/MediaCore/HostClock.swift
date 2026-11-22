import Darwin
import QuartzCore

/// Conversions for the host monotonic clock: `mach_absolute_time` ticks, which is also the base
/// of `CACurrentMediaTime`, ScreenCaptureKit display times and drawable presented times.
public enum HostClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom / 1_000_000_000
    }

    public static func ticks(seconds: Double) -> UInt64 {
        UInt64((seconds * 1_000_000_000 * timebase.denom / timebase.numer).rounded())
    }

    /// Milliseconds from `start` to `end`. Negative if `end` is earlier.
    public static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        (seconds(end) - seconds(start)) * 1000
    }
}
