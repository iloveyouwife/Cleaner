import Foundation
import XCTest
@testable import WorseCleaner

final class CleanerUnitTests: XCTestCase {
    func testSearchScrollCollapseTracksOnlyRealPosition() {
        let height: CGFloat = 70
        let offsets: [CGFloat] = [-80, 0, 12, 35, 70, 200, 70, 35, 12, 0]
        let expected: [CGFloat] = [0, 0, 12, 35, 70, 70, 70, 35, 12, 0]
        for (offset, collapse) in zip(offsets, expected) {
            XCTAssertEqual(
                CleanerSearchScrollMetrics.collapseAmount(
                    scrollOffset: offset, fullHeight: height
                ),
                collapse,
                accuracy: 0.001
            )
        }
    }

    func testSearchScrollReturnDoesNotRequireSecondGesture() {
        let height: CGFloat = 70
        // Unlike the v82 near-top gate or 50% threshold, a single reverse
        // movement must always update the visible search height.
        XCTAssertEqual(
            CleanerSearchScrollMetrics.collapseAmount(
                scrollOffset: 35, fullHeight: height
            ), 35
        )
        XCTAssertEqual(
            CleanerSearchScrollMetrics.collapseAmount(
                scrollOffset: 0, fullHeight: height
            ), 0
        )
        XCTAssertEqual(
            CleanerSearchScrollMetrics.collapseAmount(
                scrollOffset: .infinity, fullHeight: height
            ), 0
        )
    }

    private let uuidA = "6D5EB8BD-80D3-49C8-88A3-98AC3A2564DE"
    private let uuidB = "3E8BDFE9-10F6-4EE3-9259-8489DD08FA61"

    private func target(
        _ uuid: String, prefix: String = "/var", bundleID: String = "com.example.sample"
    ) -> WCTarget {
        try! WCTarget(
            bundleID: bundleID, name: "Sample",
            path: "\(prefix)/mobile/Containers/Data/Application/\(uuid)"
        )
    }

    func testAllDiscoverySourcesDeduplicateVarAliases() {
        let primary = target(uuidA)
        let alias = target(uuidA, prefix: "/private/var")
        let another = target(uuidB)
        let result = WCPathDiscovery.uniqueContainers([primary, alias, another, alias])
        XCTAssertEqual(result.map(\.id), [primary.id, another.id])
    }

    func testSearchBulkSelectionKeepsOutsideChoices() {
        let hidden: Set<String> = ["hidden"]
        let visible: Set<String> = ["one", "two"]
        let selected = CleanerSelectionScope.toggle(selected: hidden, visible: visible)
        XCTAssertEqual(selected, Set(["hidden", "one", "two"]))
        XCTAssertEqual(CleanerSelectionScope.toggle(selected: selected, visible: visible), hidden)
        XCTAssertEqual(CleanerSelectionScope.toggle(selected: hidden, visible: []), hidden)
    }

    func testPartialCleanupVerificationErrorNeverGuessesFreedBytes() {
        let error = LimitedCleanerError.postCleanupVerificationFailed(
            removed: 3, failures: 2, reason: "inaccessible")
        XCTAssertEqual(error.confirmedRemovedItems, 3)
        XCTAssertEqual(error.additionalFailureCount, 3)
        XCTAssertTrue((error.errorDescription ?? "").contains("释放字节未计入"))
        let other = LimitedCleanerError.inaccessible("tmp", EPERM)
        XCTAssertEqual(other.confirmedRemovedItems, 0)
        XCTAssertEqual(other.additionalFailureCount, 1)
    }

    func testCleanupPostcheckFailureDoesNotInventFreedBytes() {
        let before = LimitedCleanerUsage(
            cacheBytes: 100, temporaryBytes: 40, removableItemCount: 2
        )
        XCTAssertThrowsError(try LimitedCleanerService.resultAfterVerification(
            before: before, removed: 2, failures: 1,
            verify: { throw LimitedCleanerError.inaccessible("tmp", EPERM) }
        )) { error in
            guard let partial = error as? LimitedCleanerError else {
                return XCTFail("Expected a typed post-check failure")
            }
            XCTAssertEqual(partial.confirmedRemovedItems, 2)
            XCTAssertEqual(partial.additionalFailureCount, 2)
        }
        let verified = try? LimitedCleanerService.resultAfterVerification(
            before: before, removed: 2, failures: 0,
            verify: {
                LimitedCleanerUsage(
                    cacheBytes: 20, temporaryBytes: 10, removableItemCount: 0
                )
            }
        )
        XCTAssertEqual(verified?.freedBytes, 110)
        XCTAssertEqual(verified?.removedItemCount, 2)
    }

    func testExcludedAppsAreNotCountedInScanProgress() {
        let ownHome = target(uuidA).path
        let own = target(uuidA, bundleID: "com.example.cleaner")
        let other = target(uuidB, bundleID: "com.example.other")
        let third = target("AA736BDB-944E-48F1-A708-229AED7BDA25", bundleID: "com.example.third")
        let candidates = [own, other, third]
        // Self target is always excluded; the third target is manually
        // excluded, so only one of three discovered roots is scanned.
        let eligible = WCContainerSafety.eligibleTargets(
            candidates,
            excludedPaths: ["/private" + third.path],
            ownHomePath: ownHome,
            ownBundleID: "com.example.cleaner"
        )
        XCTAssertEqual(eligible.map(\.id), [other.id])
        XCTAssertEqual(eligible.count, 1)
        // Without a self entry: 22 discovered, 1 excluded => 21/21.
        let twentyTwo = Array(repeating: other, count: 22)
        let noExcluded = WCContainerSafety.eligibleTargets(
            twentyTwo, excludedPaths: [],
            ownHomePath: ownHome, ownBundleID: "com.example.cleaner"
        )
        XCTAssertEqual(noExcluded.count, 22)
        let singleExcluded = WCContainerSafety.eligibleTargets(
            [other, third], excludedPaths: [third.path],
            ownHomePath: ownHome, ownBundleID: "com.example.cleaner"
        )
        XCTAssertEqual(singleExcluded.map(\.id), [other.id])
    }

    func testSelfProtectionCoversUUIDAliasBundleIDAndManualEntry() {
        let own = target(uuidA, bundleID: "com.example.cleaner")
        let manualAlias = target(uuidA, prefix: "/private/var", bundleID: "manual")
        let mismatchedPath = target(uuidB, bundleID: "com.example.cleaner")
        let safe = target(uuidB, bundleID: "com.example.other")
        let home = own.path
        XCTAssertTrue(WCContainerSafety.isCleanerContainer(
            own, ownHomePath: home, ownBundleID: "com.example.cleaner"
        ))
        XCTAssertTrue(WCContainerSafety.isCleanerContainer(
            manualAlias, ownHomePath: home, ownBundleID: "com.example.cleaner"
        ))
        XCTAssertTrue(WCContainerSafety.isCleanerContainer(
            mismatchedPath, ownHomePath: home, ownBundleID: "com.example.cleaner"
        ))
        XCTAssertFalse(WCContainerSafety.isCleanerContainer(
            safe, ownHomePath: home, ownBundleID: "com.example.cleaner"
        ))
    }

    func testVarAliasesDoNotDuplicateOneContainer() {
        let existing = target(uuidA)
        let alias = target(uuidA, prefix: "/private/var")
        let result = WCPathDiscovery.mergeContainerCandidates(
            existing: [existing], candidates: [alias], presence: { _ in .present }
        )
        XCTAssertEqual(result.apps.map(\.id), [existing.id])
        XCTAssertFalse(result.changed)
    }

    func testStaleMCMCannotResurrectADeletedContainer() {
        let removed = target(uuidA)
        let present = target(uuidB)
        let result = WCPathDiscovery.mergeContainerCandidates(
            existing: [removed, present], candidates: [removed, present],
            presence: { path in
                WCPathDiscovery.containerIdentity(path) ==
                    WCPathDiscovery.containerIdentity(removed.path) ? .missing : .present
            }
        )
        XCTAssertEqual(result.apps.map(\.id), [present.id])
        XCTAssertTrue(result.changed)
    }

    func testUnknownAccessMustKeepExistingContainers() {
        let old = target(uuidA)
        let result = WCPathDiscovery.mergeContainerCandidates(
            existing: [old], candidates: [], presence: { _ in .unknown }
        )
        XCTAssertEqual(result.apps.map(\.id), [old.id])
        XCTAssertFalse(result.changed)
    }

    func testNewContainerIsAddedOnlyOnce() {
        let old = target(uuidA)
        let new = target(uuidB)
        let alias = target(uuidB, prefix: "/private/var")
        let result = WCPathDiscovery.mergeContainerCandidates(
            existing: [old], candidates: [new, alias], presence: { _ in .present }
        )
        XCTAssertEqual(result.apps.count, 2)
        XCTAssertTrue(result.changed)
    }

    func testManualContainerIsNotRemovedByQuickCheck() {
        let manual = target(uuidA, bundleID: "manual")
        let result = WCPathDiscovery.mergeContainerCandidates(
            existing: [manual], candidates: [], presence: { _ in .missing }
        )
        XCTAssertEqual(result.apps.map(\.id), [manual.id])
        XCTAssertFalse(result.changed)
    }

    func testUnavailableLaunchServicesStampNeverAuthorizesReuse() {
        let good = WCLaunchServicesStamp(
            device: 1, inode: 2, size: 4096,
            modifiedSeconds: 10, modifiedNanoseconds: 0,
            changedSeconds: 10, changedNanoseconds: 0
        )
        let changed = WCLaunchServicesStamp(
            device: 1, inode: 3, size: 4096,
            modifiedSeconds: 10, modifiedNanoseconds: 0,
            changedSeconds: 10, changedNanoseconds: 0
        )
        XCTAssertFalse(WCPathDiscovery.stampIsCurrent(nil, nil))
        XCTAssertFalse(WCPathDiscovery.stampIsCurrent(nil, good))
        XCTAssertFalse(WCPathDiscovery.stampIsCurrent(good, nil))
        XCTAssertFalse(WCPathDiscovery.stampIsCurrent(good, changed))
        XCTAssertTrue(WCPathDiscovery.stampIsCurrent(good, good))
    }

    func testDeletionAllowlistRemainsCachesAndTmpOnly() {
        XCTAssertEqual(
            LimitedCleanerService.allowedDirectoryComponents,
            [["Library", "Caches"], ["tmp"]]
        )
    }

    func testCleanupPreservesDocumentsAndSymlinksAndCountsUnremovedDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerUnitTests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let nested = cache.appendingPathComponent("nested", isDirectory: true)
        let temp = root.appendingPathComponent("tmp", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        for dir in [nested, temp, docs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("cache".utf8).write(to: nested.appendingPathComponent("a.bin"))
        try Data("temp".utf8).write(to: temp.appendingPathComponent("b.bin"))
        let protected = docs.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: protected)
        let link = nested.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: protected.path)

        let result = try LimitedCleanerService.clean(
            containerURL: root, rootValidator: { $0.path == root.path }
        )

        XCTAssertTrue(fm.fileExists(atPath: protected.path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertFalse(fm.fileExists(atPath: temp.appendingPathComponent("b.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: nested.appendingPathComponent("a.bin").path))
        XCTAssertEqual(result.removedItemCount, 2)
        XCTAssertGreaterThanOrEqual(result.failedItemCount, 1)
    }

    func testEmptyCacheDirectoriesDoNotTouchDocuments() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerUnitTests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let preserved = docs.appendingPathComponent("keep.txt")
        try Data("kept".utf8).write(to: preserved)
        let result = try LimitedCleanerService.clean(
            containerURL: root, rootValidator: { $0.path == root.path }
        )
        XCTAssertEqual(result.removedItemCount, 0)
        XCTAssertEqual(result.failedItemCount, 0)
        XCTAssertTrue(fm.fileExists(atPath: preserved.path))
    }
}
