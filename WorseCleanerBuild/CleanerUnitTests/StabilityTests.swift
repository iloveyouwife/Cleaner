import Foundation
import XCTest
@testable import WorseCleaner

final class StabilityTests: XCTestCase {
    private let uuid = "6D5EB8BD-80D3-49C8-88A3-98AC3A2564DE"
    private var appPath: String { "/var/mobile/Containers/Data/Application/\(uuid)" }
    private var extensionPath: String { "/var/mobile/Containers/Data/PluginKitPlugin/\(uuid)" }

    func testOwnershipEvidenceRejectsConflictsAndKeepsAgreements() {
        XCTAssertEqual(WCIdentityEvidence.agreedIdentifier(["com.example.real", nil]), "com.example.real")
        XCTAssertEqual(WCIdentityEvidence.agreedIdentifier(["com.example.real", "com.example.real"]), "com.example.real")
        XCTAssertNil(WCIdentityEvidence.agreedIdentifier(["com.example.real", "com.vendor.sdk"]))
        XCTAssertNil(WCIdentityEvidence.agreedIdentifier([nil, nil]))
    }

    func testSingleSDKPreferenceDoesNotIdentifyAnAppWithoutExactPathEvidence() {
        XCTAssertNil(WCIdentityEvidence.pathConfirmedIdentifier(
            ["com.vendor.sdk"], containerPath: appPath, lookup: { _ in nil }
        ))
        XCTAssertNil(WCIdentityEvidence.pathConfirmedIdentifier(
            ["com.example.otherInstalledApp"], containerPath: appPath,
            lookup: { _ in "/var/mobile/Containers/Data/Application/3E8BDFE9-10F6-4EE3-9259-8489DD08FA61" }
        ))
    }

    func testFallbackRequiresOneExactOwnerAndAcceptsPathAliases() {
        XCTAssertEqual(WCIdentityEvidence.pathConfirmedIdentifier(
            ["com.example.real", "com.vendor.sdk"], containerPath: appPath,
            lookup: { $0 == "com.example.real" ? "/private" + self.appPath : nil }
        ), "com.example.real")
        XCTAssertNil(WCIdentityEvidence.pathConfirmedIdentifier(
            ["com.example.first", "com.example.second"], containerPath: appPath,
            lookup: { _ in self.appPath }
        ))
    }

    func testUndiscoveredExclusionsRemainManageableWithoutChangingTheirPaths() throws {
        let target = try WCTarget(bundleID: "com.example.real", name: "Real", path: appPath)
        let saved: Set<String> = [appPath, extensionPath]
        let records = WCScanExclusions.managementTargets([target], excludedPaths: saved)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0], target)
        XCTAssertEqual(Set(records.map { WCPathDiscovery.containerIdentity($0.path) }), saved)
        XCTAssertEqual(WCScanExclusions.managementTargets([], excludedPaths: saved).count, 2)
        XCTAssertEqual(WCScanExclusions.managementTargets([], excludedPaths: []), [])
    }

    func testExcludedManagementDeduplicatesAliasesAndIgnoresUnsafeRows() throws {
        let target = try WCTarget(bundleID: "com.example.real", name: "Real", path: appPath)
        let saved: Set<String> = [appPath, "/private" + appPath, "/etc"]
        let records = WCScanExclusions.managementTargets([target], excludedPaths: saved)
        XCTAssertEqual(records, [target])
        // The view's existing All Restore action can clear invalid legacy records too.
    }

    func testBareUUIDUsesKnownContainerWithoutFilesystemGuessing() throws {
        let target = try WCTarget(bundleID: "com.example.extension", name: "Extension", path: extensionPath)
        XCTAssertEqual(try WCManualContainerPath.resolve(uuid.lowercased(), knownTargets: [target],
            presence: { _ in XCTFail("Known paths should not need a probe"); return .unknown }), extensionPath)
    }

    func testBareUUIDAcceptsOnlyOneVerifiedRoot() throws {
        XCTAssertEqual(try WCManualContainerPath.resolve(uuid, knownTargets: [],
            presence: { $0 == self.extensionPath ? .present : .missing }), extensionPath)
        for other in [WCContainerPresence.present, .unknown] {
            XCTAssertThrowsError(try WCManualContainerPath.resolve(uuid, knownTargets: [],
                presence: { $0 == self.appPath ? .present : other }))
        }
        XCTAssertThrowsError(try WCManualContainerPath.resolve(uuid, knownTargets: [], presence: { _ in .missing }))
    }

    func testFullManualPathKeepsExistingValidationBoundary() throws {
        XCTAssertEqual(try WCManualContainerPath.resolve(" \(appPath)\n", knownTargets: []), appPath)
        XCTAssertThrowsError(try WCManualContainerPath.resolve(appPath + "/Documents", knownTargets: []))
        XCTAssertThrowsError(try WCManualContainerPath.resolve("/var/mobile/Containers/Data/InternalDaemon/\(uuid)", knownTargets: []))
    }

    func testGrantRetriesAlternativeFlagsOnExtensionConsumeFailureButStopsForMissingGroup() {
        var preferred: Bool? = false
        var attempted: [Bool] = []
        let handle = WCGrant.readablePathLocked(
            appPath, groupID: "group.example.cleaner", preferred: &preferred,
            issueToken: { _, _, alt in
                attempted.append(alt)
                return alt ? 42 : -7
            },
            probeOpen: { _ in (true, 0) },
            releaseToken: { _ in XCTFail("No valid handle should be released on -7") }
        )
        XCTAssertEqual(handle, 42)
        XCTAssertEqual(attempted, [false, true])
        XCTAssertEqual(preferred, true)

        var missingCalls = 0
        let missing = WCGrant.readablePathLocked(
            appPath, groupID: "group.example.missing", preferred: &preferred,
            issueToken: { _, _, _ in missingCalls += 1; return -1 },
            probeOpen: { _ in (true, 0) },
            releaseToken: { _ in }
        )
        XCTAssertEqual(missing, -1)
        XCTAssertEqual(missingCalls, 1, "Missing App Group (-1) must not retry alternate flags")
    }

    func testUnidentifiedExtensionAndManualTargetsAreNotCountedAsNamedApps() throws {
        let ext = try WCTarget(bundleID: "容器 70A6DAA1", name: "扩展容器 70A6DAA1", path: extensionPath)
        let app = try WCTarget(bundleID: "容器 6D5EB8BD", name: "App 容器 6D5EB8BD", path: appPath)
        let manual = try WCTarget(bundleID: "manual", name: "手动指定的 App", path: appPath)
        let named = try WCTarget(bundleID: "com.example.real", name: "Real App", path: appPath)
        let idOnly = try WCTarget(bundleID: "com.example.real", name: "com.example.real", path: appPath)

        XCTAssertEqual(WCIdentityBucket.classify(target: ext, source: .unresolved), .unresolved)
        XCTAssertEqual(WCIdentityBucket.classify(target: app, source: .unresolved), .unresolved)
        XCTAssertEqual(WCIdentityBucket.classify(target: manual, source: .unresolved), .unresolved)
        XCTAssertEqual(WCIdentityBucket.classify(target: named, source: .launchServices), .named)
        XCTAssertEqual(WCIdentityBucket.classify(target: idOnly, source: .metadata), .bundleIDOnly)
    }

    func testUnresolvedManualTargetPreservesManualIdentityAcrossInspections() throws {
        let manual = try WCTarget(bundleID: "manual", name: "手动指定的 App", path: appPath)
        let unresolved = WCFileAccess.inspectIdentity(manual, knownNames: [:], knownContainers: [:])
        XCTAssertEqual(unresolved.1, .unresolved)
        XCTAssertEqual(unresolved.0.bundleID, "manual")
        XCTAssertEqual(unresolved.0.name, "手动指定的 App")

        let upgraded = WCFileAccess.inspectIdentity(
            manual,
            knownNames: ["com.example.real": "Real App"],
            knownContainers: ["/private" + appPath: "com.example.real"]
        )
        XCTAssertEqual(upgraded.1, .launchServices)
        XCTAssertEqual(upgraded.0.bundleID, "com.example.real")
        XCTAssertEqual(upgraded.0.name, "Real App")
    }

    func testCachedContainerIndexRejectsMalformedVolumeIdentifiersWithoutCrashing() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("CleanerIndex-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let badArrayPath = tempDir.appendingPathComponent("bad-array.plist")
        let badPayload: [String: Any] = [
            "version": 1,
            "fs0": ["unexpected"],
            "fs1": ["unexpected": 1],
            "apps": [String: Any](),
            "extensions": [String: Any]()
        ]
        let badData = try PropertyListSerialization.data(
            fromPropertyList: badPayload, format: .xml, options: 0
        )
        try badData.write(to: badArrayPath)
        XCTAssertNil(WCReadCachedDataContainersAtPath(badArrayPath.path))

        let missingKeysPath = tempDir.appendingPathComponent("missing-fs.plist")
        let missingPayload: [String: Any] = [
            "version": 1,
            "apps": [String: Any](),
            "extensions": [String: Any]()
        ]
        let missingData = try PropertyListSerialization.data(
            fromPropertyList: missingPayload, format: .xml, options: 0
        )
        try missingData.write(to: missingKeysPath)
        XCTAssertNil(WCReadCachedDataContainersAtPath(missingKeysPath.path))
    }

    func testDeepDirectoryScanEnforcesDepthLimitAndCleansWithinLimit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CleanerDepth-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var current = root.appendingPathComponent("Library/Caches", isDirectory: true)
        for level in 0..<5 {
            current = current.appendingPathComponent("level-\(level)", isDirectory: true)
        }
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: current.appendingPathComponent("payload.bin"))

        XCTAssertThrowsError(try LimitedCleanerService.scan(
            containerURL: root, maximumDepth: 4, rootValidator: { $0.path == root.path }
        )) { error in
            guard case let LimitedCleanerError.inaccessible(_, code) = error else {
                return XCTFail("Expected depth limit inaccessible error")
            }
            XCTAssertEqual(code, ELOOP)
        }

        let cleaned = try LimitedCleanerService.clean(
            containerURL: root, maximumDepth: 8,
            rootValidator: { $0.path == root.path },
            beforeOpeningDirectory: { _ in }
        )
        XCTAssertEqual(cleaned.removedItemCount, 1)
        XCTAssertEqual(cleaned.failedItemCount, 0)
        XCTAssertEqual(cleaned.after.totalBytes, 0)
    }
}
