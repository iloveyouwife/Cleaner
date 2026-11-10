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

        let first = preferredAlternative ?? false
        var lastError: Int64 = -8
        for alternative in [first, !first] {
            let handle = worse_query(path, groupID, alternative, true)
            guard handle > 0 else {
                lastError = handle
                // These indicate an unavailable App Group or query library;
                // changing the query flags cannot repair either condition.
                if handle == -1 || handle == -2 { return handle }
                continue
            }

            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
            } else if errno == EPERM {
                // This token was consumed, but sandbox access is still denied.
                // Release it and retry with the other supported query flags.
                worse_query_release(handle)
                lastError = -8
                continue
            }
            // EACCES is a filesystem permission failure, not a token failure.
            // Actual directory readability is separately enforced by the
            // existing scan/cleanup validators.
            if preferredAlternative == nil { preferredAlternative = alternative }
            return handle
        }
        return lastError
    }
}
