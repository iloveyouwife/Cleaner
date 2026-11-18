import Foundation
import Darwin

// A query may issue a sandbox token without actually allowing a path to be
// opened. Probe the exact read-only target, retry the alternative iOS query
// flags only for EPERM, and reuse the first working flag set during this run.
// Serializing the request also protects worse_query's shared App Group staging
// directory from simultaneous callers. The underlying cleanup policy is not
// changed: only existing call sites may request a scoped grant.
enum WCGrant {
    private static let lock = NSLock()
    private static var preferredAlternative: Bool?

    static func readablePath(_ path: String, groupID: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return readablePathLocked(
            path, groupID: groupID, preferred: &preferredAlternative,
            issueToken: { targetPath, group, alt in worse_query(targetPath, group, alt, true) },
            probeOpen: { targetPath in
                let fd = open(targetPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if fd >= 0 {
                    close(fd)
                    return (true, 0)
                }
                return (false, errno)
            },
            releaseToken: { worse_query_release($0) }
        )
    }

    static func readablePathLocked(
        _ path: String, groupID: String, preferred: inout Bool?,
        issueToken: (String, String, Bool) -> Int64,
        probeOpen: (String) -> (opened: Bool, error: Int32),
        releaseToken: (Int64) -> Void
    ) -> Int64 {
        var preferredAlternative = preferred
        defer { preferred = preferredAlternative }

        let first = preferredAlternative ?? false
        var lastError: Int64 = -8
        for alternative in [first, !first] {
            let handle = issueToken(path, groupID, alternative)
            guard handle > 0 else {
                lastError = handle
                if handle == -1 || handle == -2 || handle == -4 || (-12 ... -9).contains(handle) { return handle }
                continue
            }

            let probe = probeOpen(path)
            if probe.opened {
                preferredAlternative = alternative
                return handle
            } else if probe.error == EPERM {
                releaseToken(handle)
                lastError = -8
                continue
            }
            return handle
        }
        return lastError
    }
}
