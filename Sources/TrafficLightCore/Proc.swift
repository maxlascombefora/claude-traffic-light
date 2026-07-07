import Darwin
import Foundation

/// Is `pid` a live process? Uses signal 0, which sends nothing but reports reachability.
public func processAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    // EPERM means the process exists but we may not signal it — still alive.
    return errno == EPERM
}

/// The parent pid of `pid`, via sysctl KERN_PROC. nil if it can't be read.
public func parentPID(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard rc == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// The short command name (p_comm) of `pid`, e.g. "claude", "node", "sh".
public func processName(_ pid: Int32) -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard rc == 0, size > 0 else { return nil }
    return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String? in
        guard let base = raw.baseAddress else { return nil }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}

/// Does `pid` have a controlling terminal? A session in a real terminal window does; headless
/// automation (e.g. `claude -p` launched by a daemon, with no tty) does not. Reads kinfo
/// `e_tdev`, which is NODEV (-1) when there's no controlling tty. Returns true if it can't be
/// read, so we never wrongly hide a real window on a transient sysctl failure.
public func hasControllingTerminal(_ pid: Int32) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard rc == 0, size > 0 else { return true }
    return info.kp_eproc.e_tdev != -1
}

/// The process start time (Unix epoch seconds) of `pid`, via sysctl KERN_PROC. nil if it
/// can't be read. A pid + start-time pair uniquely fingerprints a process: after the OS
/// recycles a pid, the new process has a different start time, so a stale record no longer
/// matches. This is what lets liveness survive pid reuse.
public func processStartTime(_ pid: Int32) -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard rc == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}
