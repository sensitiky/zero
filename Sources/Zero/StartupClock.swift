import Darwin
import Foundation

/// Measures cold start from process creation to first frame.
///
/// Reads the kernel's own start time for this pid rather than timing from `main`: a good chunk of a
/// cold start is dyld and runtime setup before any of our code runs, and measuring from `main` would
/// report a number that flatters us by hiding it.
///
/// Off unless `ZERO_MEASURE_STARTUP` is set, so an NFR check never becomes noise in normal use.
enum StartupClock {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ZERO_MEASURE_STARTUP"] != nil
    }

    /// Seconds since the kernel created this process, or nil if it cannot be read.
    static func elapsedSinceProcessStart() -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }

        let started = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        let nowSeconds = Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000
        return nowSeconds - startSeconds
    }

    static func reportFirstFrame() {
        guard isEnabled, let elapsed = elapsedSinceProcessStart() else { return }
        FileHandle.standardError.write(
            Data(String(format: "zero: first frame at %.3fs after process start\n", elapsed).utf8)
        )
    }
}
