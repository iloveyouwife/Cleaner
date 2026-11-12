import Foundation
import XCTest
@testable import WorseCleaner

final class CleanerUnitTests: XCTestCase {
    func testDiscoveryRequiresBothAvailableAndConfirmedAppGroup() {
        XCTAssertFalse(CleanerDiscoveryGate.allowsDiscovery(
            appGroupReady: false, groupConfirmed: false
        ))
        XCTAssertFalse(CleanerDiscoveryGate.allowsDiscovery(
            appGroupReady: true, groupConfirmed: false
        ))
        XCTAssertFalse(CleanerDiscoveryGate.allowsDiscovery(
            appGroupReady: false, groupConfirmed: true
        ))
        XCTAssertTrue(CleanerDiscoveryGate.allowsDiscovery(
            appGroupReady: true, groupConfirmed: true
        ))
    }

    @MainActor
    func testRevokingPermissionDropsDisplayedCacheAndBlocksDiscovery() {
        let model = WorseCleanerModel()
        let app = target(uuidA)
        model.apps = [app]
        model.usage = [
            app.id: LimitedCleanerUsage(
                cacheBytes: 1024, temporaryBytes: 512, removableItemCount: 2
            )
        ]
        model.scannedAppCount = 1
        model.appGroupReady = false
        model.setGroupConfirmed(false)

        XCTAssertFalse(model.canDiscoverApps)
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertTrue(model.usage.isEmpty)
        XCTAssertEqual(model.scannedAppCount, 0)
        XCTAssertEqual(model.scanTargetCount, 0)

        model.loadApps()
        XCTAssertFalse(model.busy, "No MCM, LaunchServices or inode search without permission.")
        XCTAssertTrue(model.apps.isEmpty)
        model.deepDiscoverApps()
        XCTAssertFalse(model.busy, "Manual deep discovery must not run without permission.")
        model.addManualPath(app.path)
        XCTAssertTrue(model.apps.isEmpty)
        model.completeMissingNamesOnline()
        XCTAssertFalse(model.busy)
    }

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

    func testManualExclusionProgressUses21Of21Not21Of22() {
        let candidates = (0..<22).map { index -> WCTarget in
            let uuid = String(format: "00000000-0000-4000-8000-%012d", index + 1)
            return target(uuid, bundleID: "com.example.app\(index)")
        }
        let excluded = candidates[4]
        let eligible = WCScanExclusions.eligibleTargets(
            candidates, excludedPaths: ["/private" + excluded.path]
        )
        XCTAssertEqual(candidates.count, 22)
        XCTAssertEqual(eligible.count, 21)
        XCTAssertFalse(eligible.contains(where: { $0.id == excluded.id }))
        XCTAssertEqual(WCScanExclusions.eligibleTargets(candidates, excludedPaths: []).count, 22)
    }

    func testCleanerRemainsEligibleUnlessExplicitlyExcluded() {
        let cleaner = target(uuidA, bundleID: "com.example.cleaner")
        let other = target(uuidB, bundleID: "com.example.other")
        let all = [cleaner, other]
        XCTAssertEqual(
            WCScanExclusions.eligibleTargets(all, excludedPaths: []).count, 2
        )
        let filtered = WCScanExclusions.eligibleTargets(
            all, excludedPaths: ["/private" + cleaner.path]
        )
        XCTAssertEqual(filtered.map(\.id), [other.id])
    }

    func testExcludingAppPrunesSelectedIDsButPreservesSearchHiddenSelections() {
        let one = target(uuidA, bundleID: "com.example.one")
        let two = target(uuidB, bundleID: "com.example.two")
        let hidden = target("AA736BDB-944E-48F1-A708-229AED7BDA25", bundleID: "com.example.hidden")
        let chosen: Set<String> = [one.id, two.id, hidden.id]
        let stillChosen = CleanerSelectionScope.retainingEligible(
            selected: chosen, apps: [one, two, hidden],
            excludedPaths: ["/private" + one.path]
        )
        XCTAssertEqual(stillChosen, Set([two.id, hidden.id]))
        // An App removal must also prune selection without clearing all others.
        let afterUninstall = CleanerSelectionScope.retainingEligible(
            selected: stillChosen, apps: [two], excludedPaths: []
        )
        XCTAssertEqual(afterUninstall, Set([two.id]))
    }

    func testExcludedAliasesAgreeInScanListAndManagementList() {
        let app = target(uuidA, bundleID: "com.example.app")
        let other = target(uuidB, bundleID: "com.example.other")
        let excluded = WCScanExclusions.normalizedPaths(["/private" + app.path])
        XCTAssertEqual(excluded, Set([WCPathDiscovery.containerIdentity(app.path)]))
        XCTAssertEqual(
            WCScanExclusions.eligibleTargets([app, other], excludedPaths: excluded).map(\.id),
            [other.id]
        )
        XCTAssertEqual(
            WCScanExclusions.excludedTargets([app, other], excludedPaths: excluded).map(\.id),
            [app.id]
        )
        XCTAssertTrue(
            WCScanExclusions.normalizedPaths([app.path]).isSubset(of: excluded)
        )
    }

    func testCacheSummariesUseVisibleAndSelectedTargetsOnly() {
        let one = target(uuidA, bundleID: "com.example.one")
        let two = target(uuidB, bundleID: "com.example.two")
        let usage: [String: LimitedCleanerUsage] = [
            one.id: LimitedCleanerUsage(cacheBytes: 100, temporaryBytes: 10, removableItemCount: 1),
            two.id: LimitedCleanerUsage(cacheBytes: 200, temporaryBytes: 20, removableItemCount: 1)
        ]
        XCTAssertEqual(
            CleanerCacheSummary.availableBytes(visibleApps: [two], usage: usage), 220
        )
        XCTAssertEqual(
            CleanerCacheSummary.selectedBytes(ids: [one.id], usage: usage), 110
        )
        XCTAssertEqual(
            CleanerCacheSummary.selectedBytes(ids: [one.id, "uninstalled"], usage: usage), 110
        )
        XCTAssertEqual(
            CleanerCacheSummary.availableBytes(visibleApps: [], usage: usage), 0
        )
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

    func testCleanupMidOperationPermissionFailureCountsConfirmedRemovals() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerPartialFailure-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        for path in [caches, tmp, documents] {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let cacheFile = caches.appendingPathComponent("cache.bin")
        let tmpFile = tmp.appendingPathComponent("tmp.bin")
        let docFile = documents.appendingPathComponent("important.txt")
        try Data("abc".utf8).write(to: cacheFile)
        try Data("12345".utf8).write(to: tmpFile)
        try Data("keep".utf8).write(to: docFile)

        var visited: [[String]] = []
        let result = try LimitedCleanerService.clean(
            containerURL: root, rootValidator: { $0.path == root.path },
            beforeOpeningDirectory: { components in
                visited.append(components)
                if components == ["tmp"] {
                    // Simulate EPERM after Caches was actually unlinked,
                    // not an inaccessible directory during the initial scan.
                    throw LimitedCleanerError.inaccessible("tmp", EPERM)
                }
            }
        )
        XCTAssertEqual(visited, [["Library", "Caches"], ["tmp"]])
        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertEqual(result.failedItemCount, 1)
        XCTAssertEqual(result.freedBytes, 3)
        XCTAssertEqual(result.after.cacheBytes, 0)
        XCTAssertEqual(result.after.temporaryBytes, 5)
        XCTAssertFalse(fm.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(fm.fileExists(atPath: tmpFile.path))
        XCTAssertEqual(try String(contentsOf: docFile, encoding: .utf8), "keep")
    }

    func testCleanupPermissionFailureBeforeFirstDeletionReportsNoFreedBytes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerEarlyFailure-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let file = caches.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: file)
        let result = try LimitedCleanerService.clean(
            containerURL: root, rootValidator: { $0.path == root.path },
            beforeOpeningDirectory: { _ in
                throw LimitedCleanerError.inaccessible("Library/Caches", EPERM)
            }
        )
        XCTAssertEqual(result.removedItemCount, 0)
        XCTAssertEqual(result.failedItemCount, 1)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    func testWorseQueryStagingPreservesAppGroupCacheFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerStaging-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let target = root.appendingPathComponent("other-app-cache", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let original = caches.appendingPathComponent("preserve.bin")
        let targetFile = target.appendingPathComponent("target.bin")
        try Data("original".utf8).write(to: original)
        try Data("target".utf8).write(to: targetFile)

        XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: caches.path), target.path)
        XCTAssertTrue(fm.fileExists(atPath: caches.path + ".wq-preserved/preserve.bin"))
        XCTAssertTrue(WQCacheStageEnd(caches.path, target.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertFalse(fm.fileExists(atPath: caches.path + ".wq-preserved"))
        XCTAssertEqual(try Data(contentsOf: targetFile), Data("target".utf8))
    }

    func testWorseQueryStagingRestoresCacheAfterQueryFailure() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerStageFailure-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let original = caches.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: original)
        let missingTarget = root.appendingPathComponent("foreign-unavailable")
        XCTAssertTrue(WQCacheStageBegin(caches.path, missingTarget.path))
        // Simulate a container_query rejection before token acquisition.
        XCTAssertTrue(WQCacheStageEnd(caches.path, missingTarget.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
    }

    func testWorseQueryStagingFailsClosedForLeftoverBackupOrUnexpectedLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "CleanerStageFailClosed-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let backup = URL(fileURLWithPath: caches.path + ".wq-preserved")
        let target = root.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let original = caches.appendingPathComponent("original.txt")
        let preserved = backup.appendingPathComponent("previous.txt")
        try Data("original".utf8).write(to: original)
        try Data("previous".utf8).write(to: preserved)
        XCTAssertFalse(WQCacheStageBegin(caches.path, target.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("previous".utf8))
        XCTAssertTrue(fm.fileExists(atPath: caches.path))

        try fm.removeItem(at: backup)
        try fm.removeItem(at: caches)
        try fm.createSymbolicLink(atPath: caches.path, withDestinationPath: target.path)
        XCTAssertFalse(WQCacheStageBegin(caches.path, target.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: caches.path), target.path)
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertFalse(WQCacheStageEnd(caches.path, root.path))
    }

}
