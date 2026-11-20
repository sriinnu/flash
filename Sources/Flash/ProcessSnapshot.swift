import Darwin
import Foundation
import FlashCore

/// The process table, read with libproc: no `ps` subprocess, nothing that
/// needs a permission prompt. Arguments and environment come from
/// KERN_PROCARGS2, which works for your own processes.
enum ProcessSnapshot {

    /// pid, parent, name and start time for every process.
    static func table() -> [Int32: ProcessRecord] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [:] }
        var table: [Int32: ProcessRecord] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                               + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            table[pid] = ProcessRecord(pid: pid, ppid: Int32(info.pbi_ppid),
                                       name: name.isEmpty ? comm : name, started: started)
        }
        return table
    }

    /// Fills path, working directory, args and the environment keys Flash reads.
    static func fill(_ record: inout ProcessRecord) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, record.pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0,
              let parsed = ProcessRecord.parseProcArgs(Array(bytes.prefix(size))) else { return }
        var vnode = proc_vnodepathinfo()
        let vsize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(record.pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vsize) == vsize {
            record.cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        record.path = parsed.path
        record.args = parsed.args
        record.environment = parsed.environment
    }

    /// Who is waiting on the dialog that appeared at `at`, if a
    /// command-line client is.
    static func keychainRequester(at date: Date = Date()) -> KeychainRequester? {
        var table = table()
        let candidates = KeychainAttribution.candidates(in: table, at: date)
        guard let pid = candidates.first else { return nil }
        for p in [pid] + KeychainAttribution.ancestors(of: pid, in: table).map(\.pid) {
            if var record = table[p] {
                fill(&record)
                table[p] = record
            }
        }
        var requester = KeychainAttribution.describe(pid, in: table)
        requester?.others = candidates.count - 1
        return requester
    }
}
