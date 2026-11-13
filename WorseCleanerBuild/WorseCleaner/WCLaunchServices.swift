import Foundation
import Darwin

// Read-only LaunchServices CSStore2 name index. Format decoding is adapted
// from kolbicz/WQFiles, WQLaunchServices.m (GPL-3.0-or-later).
// Unlike a fixed iOS-version switch, we test supported record layouts against
// actual discovered container paths. Unknown/ambiguous layouts fall back to
// ordinary metadata rather than assigning a guessed identity.
struct WCLaunchServicesSnapshot {
    let names: [String: String]
    let containers: [String: String]
    let diagnostics: String
}

/// An immutable read result may be reused by the immediately following scan.
/// A missing stamp, changed file, changed group or changed path always invalidates it.
struct WCLaunchServicesRead {
    let snapshot: WCLaunchServicesSnapshot
    let groupID: String
    let storePath: String
    let stamp: WCLaunchServicesStamp

    func snapshotIfCurrent(groupID: String, storePath: String?, stamp: WCLaunchServicesStamp?) -> WCLaunchServicesSnapshot? {
        guard self.groupID == groupID, self.storePath == storePath,
              WCPathDiscovery.stampIsCurrent(self.stamp, stamp) else { return nil }
        return snapshot
    }
}

enum WCLaunchServices {
    private static let maximumBytes = 64 * 1024 * 1024
    private static let maximumID: UInt32 = 0x0100_0000
    private static let maximumRecords = 100_000
    private static let maximumStrings = 200_000
    private static let maximumStringBytes = 8 * 1024 * 1024

    private struct Layout {
        let label: String
        let bundleSize: Int
        let bundleID: Int
        let container: Int
        let name: Int
        let display: Int
        let pluginSize: Int
        let pluginID: Int
        let pluginContainer: Int
    }

    // These offsets are candidates, not a claim that later iOS versions keep
    // the same binary format. A candidate must map real UUID containers.
    private static let layouts: [Layout] = [
        .init(label: "27.0", bundleSize: 0x250, bundleID: 0x0c, container: 0x68,
              name: 0x6c, display: 0x74, pluginSize: 0x118, pluginID: 0, pluginContainer: 0x54),
        .init(label: "26", bundleSize: 0x23c, bundleID: 0x0c, container: 0x64,
              name: 0x68, display: 0x70, pluginSize: 0x104, pluginID: 0, pluginContainer: 0x50),
        .init(label: "27.2a", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c,
              name: 0x70, display: 0x78, pluginSize: 0x120, pluginID: 0, pluginContainer: 0x58),
        .init(label: "27.2b", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c,
              name: 0x70, display: 0x78, pluginSize: 0x120, pluginID: 4, pluginContainer: 0x58),
        .init(label: "27.2c", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c,
              name: 0x70, display: 0x78, pluginSize: 0x120, pluginID: 4, pluginContainer: 0x58),
        .init(label: "27.2d", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c,
              name: 0x70, display: 0x78, pluginSize: 0x120, pluginID: 0, pluginContainer: 0x58)
    ]

    private struct Candidate {
        var names: [String: String] = [:]
        var containers: [String: String] = [:]
        var matched = 0
        var layout = ""
    }

    private static func normalizedPath(_ raw: String) -> String {
        var path = raw
        if path.hasPrefix("/var/") { path = "/private" + path }
        if path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func validContainer(_ raw: String, type: String) -> String? {
        let path = normalizedPath(raw)
        let prefix = "/private/var/mobile/Containers/Data/\(type)/"
        guard path.hasPrefix(prefix),
              UUID(uuidString: String(path.dropFirst(prefix.count))) != nil else { return nil }
        return path
    }

    private static func validStore(_ raw: String) -> Bool {
        let prefix = "/private/var/mobile/Containers/Data/InternalDaemon/"
        guard raw.hasPrefix(prefix) else { return false }
        let rest = String(raw.dropFirst(prefix.count))
        guard rest.count > 36,
              UUID(uuidString: String(rest.prefix(36))) != nil else { return false }
        let suffix = String(rest.dropFirst(36))
        return suffix.hasPrefix("/Library/Caches/com.apple.LaunchServices-")
            && suffix.hasSuffix(".csstore")
            && !suffix.dropFirst("/Library/Caches/".count).contains("/")
    }

    private static func validBundleID(_ name: String?) -> Bool {
        guard let name, name.count > 2, name.count <= 256,
              name.contains("."), !name.hasPrefix("."), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }

    private static func safeName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 120,
              !normalized.hasPrefix("/"), !normalized.contains(".app/") else { return nil }
        for scalar in normalized.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) ||
               CharacterSet.illegalCharacters.contains(scalar) ||
               (0x202A...0x202E).contains(scalar.value) ||
               (0x2060...0x206F).contains(scalar.value) ||
               (0x200B...0x200F).contains(scalar.value) ||
               scalar.value == 0xFEFF { return nil }
        }
        return normalized
    }

    // Read just one validated lsd file, with a file-size cap and a scoped,
    // read-only extension. No daemon path is exposed to cleanup.
    static func load(
        storePath: String?, groupID: String, knownPaths: Set<String>,
        allowUnmatched: Bool = false
    ) -> WCLaunchServicesSnapshot? {
        loadValidated(storePath: storePath, groupID: groupID,
                      knownPaths: knownPaths, allowUnmatched: allowUnmatched)?.snapshot
    }

    static func loadValidated(
        storePath: String?, groupID: String, knownPaths: Set<String>,
        allowUnmatched: Bool = false
    ) -> WCLaunchServicesRead? {
        guard let storePath, validStore(storePath),
              WCFileAccess.accessibleGroups().contains(groupID) else { return nil }
        let cacheRoot = (storePath as NSString).deletingLastPathComponent
        let lease = WCGrant.readablePath(cacheRoot, groupID: groupID)
        defer { if lease > 0 { worse_query_release(lease) } }
        var fileLease: Int64 = -1
        defer { if fileLease > 0 { worse_query_release(fileLease) } }
        var fd = open(storePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 && lease > 0 {
            // Some sandbox extensions cover the file but not its parent.
            fileLease = WCGrant.readablePath(storePath, groupID: groupID)
            if fileLease > 0 {
                fd = open(storePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size >= 4096, initial.st_size <= Int64(maximumBytes) else { return nil }
        guard let bytes = readStoreBytes(byteCount: Int(initial.st_size), readChunk: { buffer, count in
            Darwin.read(fd, &buffer, count)
        }) else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, initial.st_ino == after.st_ino,
              initial.st_size == after.st_size,
              initial.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        guard WCPathDiscovery.stamp(from: initial) == WCPathDiscovery.stamp(from: after),
              let snapshot = parse(bytes, knownPaths: knownPaths, allowUnmatched: allowUnmatched)
        else { return nil }
        return WCLaunchServicesRead(snapshot: snapshot, groupID: groupID,
                                    storePath: storePath, stamp: WCPathDiscovery.stamp(from: after))
    }

    // Reads may be interrupted before producing bytes. Retry only EINTR;
    // EOF, other errors and invalid read lengths still reject this snapshot.
    // The injected reader lets unit tests cover those paths without grants.
    static func readStoreBytes(
        byteCount: Int, readChunk: (inout [UInt8], Int) -> Int
    ) -> Data? {
        guard byteCount >= 0, byteCount <= maximumBytes else { return nil }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while bytes.count < byteCount {
            let requested = min(buffer.count, byteCount - bytes.count)
            let count = readChunk(&buffer, requested)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, count <= requested else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }

    // Kept internal so a binary-fixture test can exercise both known and
    // unsupported layouts without needing a device sandbox extension.
    static func parse(
        _ data: Data, knownPaths: Set<String>, allowUnmatched: Bool = false
    ) -> WCLaunchServicesSnapshot? {
        guard data.count >= 4096, data.count <= maximumBytes,
              data.starts(with: [0x62, 0x64, 0x73, 0x6c]) else { return nil }
        let known = Set(knownPaths.map(normalizedPath))
        let heapStart = data.range(of: Data("<string>".utf8))?.lowerBound ?? 0
        return data.withUnsafeBytes { raw -> WCLaunchServicesSnapshot? in
            guard let b = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let length = raw.count
            func u32(_ offset: Int) -> UInt32 {
                UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8) |
                    (UInt32(b[offset + 2]) << 16) | (UInt32(b[offset + 3]) << 24)
            }
            func goodRef(_ value: UInt32) -> Bool {
                value != 0 && value & 3 == 0 && value >> 2 < maximumID
            }
            // All layout candidates share a string table but can point at
            // different fields. Decode only referenced IDs.
            var bundles = Array(repeating: [[UInt32]](), count: layouts.count)
            var plugins = Array(repeating: [[UInt32]](), count: layouts.count)
            var needed = Set<UInt32>()
            for offset in stride(from: 0, through: length - 8, by: 4) {
                let size = Int(u32(offset + 4))
                guard size >= 0x100, size <= 0x25c, offset + 8 + size <= length else { continue }
                for (index, layout) in layouts.enumerated() {
                    if size == layout.bundleSize {
                        let id = u32(offset + 8 + layout.bundleID)
                        guard goodRef(id), bundles[index].count < maximumRecords else { continue }
                        let fields: [UInt32] = [
                            id, u32(offset + 8 + layout.name),
                            u32(offset + 8 + layout.display),
                            u32(offset + 8 + layout.container)
                        ]
                        bundles[index].append(fields)
                        for ref in fields where goodRef(ref) { needed.insert(ref >> 2) }
                    }
                    if size == layout.pluginSize {
                        let fields: [UInt32] = [
                            u32(offset + 8 + layout.pluginID),
                            u32(offset + 8 + layout.pluginContainer)
                        ]
                        guard fields.allSatisfy(goodRef),
                              plugins[index].count < maximumRecords else { continue }
                        plugins[index].append(fields)
                        needed.insert(fields[0] >> 2)
                        needed.insert(fields[1] >> 2)
                    }
                }
            }
            guard bundles.contains(where: { !$0.isEmpty }),
                  needed.count <= maximumStrings else { return nil }
            var strings: [UInt32: String] = [:]
            var pathStrings: [UInt32: String] = [:]
            var ambiguousPaths = Set<UInt32>()
            var heapStrings = Set<UInt32>()
            var decodedBytes = 0
            for offset in stride(from: 0, through: length - 8, by: 4) {
                let id = u32(offset)
                guard needed.contains(id) else { continue }
                let byteCount = Int(u32(offset + 4))
                guard byteCount > 0, byteCount < 2048,
                      byteCount < length - offset - 8 else { continue }
                if byteCount % 4 != 0 && b[offset + 8 + byteCount] != 0 { continue }
                let sub = UnsafeBufferPointer(start: b + offset + 8, count: byteCount)
                if sub.contains(0) { continue }
                guard let string = String(bytes: sub, encoding: .utf8) else { continue }
                if string.contains("/mobile/Containers/Data/") {
                    if let old = pathStrings[id], old != string {
                        ambiguousPaths.insert(id)
                    } else {
                        pathStrings[id] = string
                    }
                }
                let inHeap = offset >= heapStart
                if strings[id] == nil || (inHeap && !heapStrings.contains(id)) {
                    if strings[id] == nil {
                        decodedBytes += byteCount
                        if decodedBytes > maximumStringBytes { return nil }
                    }
                    strings[id] = string
                    if inHeap { heapStrings.insert(id) }
                }
            }
            func string(_ ref: UInt32) -> String? {
                goodRef(ref) ? strings[ref >> 2] : nil
            }
            func path(_ ref: UInt32) -> String? {
                guard goodRef(ref), !ambiguousPaths.contains(ref >> 2) else { return nil }
                return pathStrings[ref >> 2] ?? strings[ref >> 2]
            }
            var candidates: [Candidate] = []
            for (index, layout) in layouts.enumerated() {
                var candidate = Candidate()
                candidate.layout = layout.label
                var conflicts = Set<String>()
                func claim(_ raw: String?, id: String?, type: String) {
                    guard let raw, validBundleID(id), let id,
                          let p = validContainer(raw, type: type) else { return }
                    if let existing = candidate.containers[p], existing != id {
                        conflicts.insert(p)
                    } else {
                        candidate.containers[p] = id
                    }
                }
                for fields in plugins[index] {
                    claim(path(fields[1]), id: string(fields[0]), type: "PluginKitPlugin")
                }
                for fields in bundles[index] {
                    guard let id = string(fields[0]), validBundleID(id) else { continue }
                    claim(path(fields[3]), id: id, type: "Application")
                    if let name = safeName(string(fields[2])) ?? safeName(string(fields[1])) {
                        candidate.names[id] = name
                    }
                }
                for conflict in conflicts { candidate.containers.removeValue(forKey: conflict) }
                candidate.matched = candidate.containers.keys.filter { known.contains($0) }.count
                candidates.append(candidate)
            }
            let ranked = candidates.sorted {
                if $0.matched != $1.matched { return $0.matched > $1.matched }
                if $0.containers.count != $1.containers.count {
                    return $0.containers.count > $1.containers.count
                }
                return $0.names.count > $1.names.count
            }
            guard var winner = ranked.first, winner.containers.count >= 2,
                  (allowUnmatched || winner.matched > 0) else { return nil }
            // When two layouts have identical evidence, keep only identities
            // they agree on. This avoids wrong names after an OS layout shift.
            let tied = ranked.filter {
                $0.matched == winner.matched &&
                    $0.containers.count == winner.containers.count &&
                    $0.names.count == winner.names.count
            }
            if tied.count > 1 {
                winner.containers = winner.containers.filter { (p, id) in
                    tied.allSatisfy { $0.containers[p] == id }
                }
                winner.names = winner.names.filter { (id, name) in
                    tied.allSatisfy { $0.names[id] == name }
                }
            }
            guard winner.containers.count >= 2,
                  allowUnmatched || winner.containers.keys.contains(where: { known.contains($0) })
            else { return nil }
            let diagnostic = "LaunchServices：CSStore2 布局 \(winner.layout)，匹配已发现容器 \(winner.matched)，读取名称 \(winner.names.count)，可靠路径映射 \(winner.containers.count)。"
            return WCLaunchServicesSnapshot(names: winner.names,
                                            containers: winner.containers,
                                            diagnostics: diagnostic)
        }
    }
}
