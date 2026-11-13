import Foundation
import XCTest
@testable import WorseCleaner

/// Synthetic CSStore2 fixtures contain no device data or private app names.
/// Records and string tables use the external format, then exercise the actual parser.
final class LaunchServicesParserTests: XCTestCase {
    private struct Layout {
        let size: Int, id: Int, container: Int, name: Int, display: Int
        let pluginSize: Int, pluginID: Int, pluginContainer: Int
    }
    private let layouts = [
        Layout(size: 0x250, id: 0x0c, container: 0x68, name: 0x6c, display: 0x74,
               pluginSize: 0x118, pluginID: 0, pluginContainer: 0x54),
        Layout(size: 0x23c, id: 0x0c, container: 0x64, name: 0x68, display: 0x70,
               pluginSize: 0x104, pluginID: 0, pluginContainer: 0x50),
        Layout(size: 0x25c, id: 0x0c, container: 0x6c, name: 0x70, display: 0x78,
               pluginSize: 0x120, pluginID: 0, pluginContainer: 0x58),
        Layout(size: 0x25c, id: 0x10, container: 0x6c, name: 0x70, display: 0x78,
               pluginSize: 0x120, pluginID: 4, pluginContainer: 0x58),
        Layout(size: 0x25c, id: 0x0c, container: 0x6c, name: 0x70, display: 0x78,
               pluginSize: 0x120, pluginID: 4, pluginContainer: 0x58),
        Layout(size: 0x25c, id: 0x10, container: 0x6c, name: 0x70, display: 0x78,
               pluginSize: 0x120, pluginID: 0, pluginContainer: 0x58)
    ]
    private let a = "/private/var/mobile/Containers/Data/Application/6D5EB8BD-80D3-49C8-88A3-98AC3A2564DE"
    private let b = "/private/var/mobile/Containers/Data/Application/3E8BDFE9-10F6-4EE3-9259-8489DD08FA61"
    private let plugin = "/private/var/mobile/Containers/Data/PluginKitPlugin/70A6DAA1-6226-4608-847B-FC7E12CB2C27"

    private func put(_ value: UInt32, at offset: Int, in data: inout Data) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    private func fixture(
        layout: Int = 0, paths: [String]? = nil, displayName: String = "First App",
        includePlugin: Bool = true
    ) -> Data {
        let l = layouts[layout]
        var data = Data(repeating: 0, count: 8192)
        data.replaceSubrange(0..<4, with: [0x62, 0x64, 0x73, 0x6c])
        data.replaceSubrange(2048..<2056, with: Array("<string>".utf8))
        let roots = paths ?? [a, b]
        var strings: [(UInt32, String)] = []
        for (index, path) in roots.enumerated() {
            let offset = 64 + index * 768
            let id = UInt32(100 + index * 4)
            put(UInt32(l.size), at: offset + 4, in: &data)
            put(id << 2, at: offset + 8 + l.id, in: &data)
            put((id + 1) << 2, at: offset + 8 + l.container, in: &data)
            put((id + 2) << 2, at: offset + 8 + l.name, in: &data)
            put((id + 2) << 2, at: offset + 8 + l.display, in: &data)
            strings += [(id, "com.example.app\(index)"), (id + 1, path),
                        (id + 2, index == 0 ? displayName : "Second App")]
        }
        if includePlugin {
            let offset = 1600
            put(UInt32(l.pluginSize), at: offset + 4, in: &data)
            put(200 << 2, at: offset + 8 + l.pluginID, in: &data)
            put(201 << 2, at: offset + 8 + l.pluginContainer, in: &data)
            strings += [(200, "com.example.app0.extension"), (201, plugin)]
        }
        var cursor = 4096
        for (id, string) in strings {
            appendString(id, bytes: Array(string.utf8), to: &data, cursor: &cursor)
        }
        return data
    }

    private func appendString(_ id: UInt32, bytes: [UInt8], to data: inout Data, cursor: inout Int) {
        put(id, at: cursor, in: &data)
        put(UInt32(bytes.count), at: cursor + 4, in: &data)
        data.replaceSubrange((cursor + 8)..<(cursor + 8 + bytes.count), with: bytes)
        cursor = (cursor + 8 + bytes.count + 1 + 3) & ~3
    }

    func testAllSixSupportedLayoutsMapAppsExtensionsAndNames() throws {
        for index in layouts.indices {
            let result = try XCTUnwrap(WCLaunchServices.parse(fixture(layout: index), knownPaths: [a, b]))
            XCTAssertEqual(result.containers[a], "com.example.app0", "layout \(index)")
            XCTAssertEqual(result.containers[b], "com.example.app1", "layout \(index)")
            XCTAssertEqual(result.containers[plugin], "com.example.app0.extension", "layout \(index)")
            XCTAssertEqual(result.names["com.example.app0"], "First App")
        }
    }

    func testUnknownLayoutTruncatedDataAndBadMagicAreRejected() {
        var unknown = fixture(includePlugin: false)
        put(0x260, at: 68, in: &unknown)
        put(0x260, at: 836, in: &unknown)
        XCTAssertNil(WCLaunchServices.parse(unknown, knownPaths: [a, b]))
        XCTAssertNil(WCLaunchServices.parse(Data(fixture().prefix(4096)), knownPaths: [a, b]))
        XCTAssertNil(WCLaunchServices.parse(Data(repeating: 0, count: 8192), knownPaths: [a]))
        XCTAssertNil(WCLaunchServices.parse(Data(), knownPaths: []))
    }

    func testNormalParsingRequiresKnownPathsWhileDiscoveryMayAcceptUnmatchedRecords() {
        XCTAssertNil(WCLaunchServices.parse(fixture(), knownPaths: []))
        XCTAssertNotNil(WCLaunchServices.parse(fixture(), knownPaths: [], allowUnmatched: true))
        let aliases = Set([a, b].map { String($0.dropFirst("/private".count)) })
        XCTAssertNotNil(WCLaunchServices.parse(fixture(), knownPaths: aliases))
    }

    func testConflictingContainerOwnershipAndUnsafeContainerPathsAreRejected() {
        XCTAssertNil(WCLaunchServices.parse(fixture(paths: [a, a], includePlugin: false), knownPaths: [a]))
        XCTAssertNil(WCLaunchServices.parse(fixture(paths: [a, b + "/Documents"], includePlugin: false), knownPaths: [a]))
        XCTAssertNil(WCLaunchServices.parse(fixture(paths: [a], includePlugin: false), knownPaths: [a]))
    }

    func testMissingOrConflictingStringReferencesCannotCreateOwnership() {
        var missing = fixture(includePlugin: false)
        put(999 << 2, at: 64 + 8 + layouts[0].container, in: &missing)
        XCTAssertNil(WCLaunchServices.parse(missing, knownPaths: [a, b]))
        var conflicting = fixture(includePlugin: false)
        var cursor = 6500
        appendString(101, bytes: Array(b.utf8), to: &conflicting, cursor: &cursor)
        XCTAssertNil(WCLaunchServices.parse(conflicting, knownPaths: [a, b]))
        var invalidUTF8 = fixture(includePlugin: false)
        // The first referenced Bundle ID must decode as UTF-8.
        invalidUTF8[4104] = 0xff
        XCTAssertNil(WCLaunchServices.parse(invalidUTF8, knownPaths: [a, b]))
    }

    func testEqualEvidenceLayoutsWithDifferentOwnersAreRejected() {
        var data = fixture(layout: 2, includePlugin: false)
        var cursor = 6500
        for index in 0..<2 {
            let stringID = UInt32(300 + index)
            put(stringID << 2, at: 64 + index * 768 + 8 + 0x10, in: &data)
            appendString(stringID, bytes: Array("com.other.app\(index)".utf8), to: &data, cursor: &cursor)
        }
        XCTAssertNil(WCLaunchServices.parse(data, knownPaths: [a, b]))
    }

    func testControlCharactersAreNotAcceptedAsDisplayNames() throws {
        let result = try XCTUnwrap(WCLaunchServices.parse(fixture(displayName: "Fake\u{202E}Name"), knownPaths: [a, b]))
        XCTAssertNil(result.names["com.example.app0"])
        XCTAssertEqual(result.containers[a], "com.example.app0")
    }

    func testReadReuseRejectsChangedFileGroupPathAndUnknownStamp() {
        let snapshot = WCLaunchServicesSnapshot(names: [:], containers: [:], diagnostics: "fixture")
        let stamp = WCLaunchServicesStamp(device: 1, inode: 2, size: 8192, modifiedSeconds: 3,
                                         modifiedNanoseconds: 4, changedSeconds: 5, changedNanoseconds: 6)
        let changed = WCLaunchServicesStamp(device: 1, inode: 2, size: 8192, modifiedSeconds: 3,
                                           modifiedNanoseconds: 4, changedSeconds: 7, changedNanoseconds: 6)
        let read = WCLaunchServicesRead(snapshot: snapshot, groupID: "group.first", storePath: "/store", stamp: stamp)
        XCTAssertNotNil(read.snapshotIfCurrent(groupID: "group.first", storePath: "/store", stamp: stamp))
        XCTAssertNil(read.snapshotIfCurrent(groupID: "group.other", storePath: "/store", stamp: stamp))
        XCTAssertNil(read.snapshotIfCurrent(groupID: "group.first", storePath: "/other", stamp: stamp))
        XCTAssertNil(read.snapshotIfCurrent(groupID: "group.first", storePath: "/store", stamp: changed))
        XCTAssertNil(read.snapshotIfCurrent(groupID: "group.first", storePath: "/store", stamp: nil))
    }
}
