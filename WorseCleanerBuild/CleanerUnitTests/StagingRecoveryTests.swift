import Foundation
import XCTest
@testable import WorseCleaner

final class StagingRecoveryTests: XCTestCase {
    private func withFixture(_ run: (URL, URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CleanerRecovery-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches")
        let target = root.appendingPathComponent("foreign-cache")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: caches.appendingPathComponent("original.txt"))
        try Data("foreign".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try run(root, caches, target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8), "foreign")
    }

    func testInterruptedTransactionRestoresTheOriginalDirectoryAndItsContents() throws {
        try withFixture { _, caches, target in
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            // A later authorized call has no in-memory state from the begin call.
            XCTAssertTrue(WQCacheStageRecover(caches.path))
            XCTAssertEqual(try String(contentsOf: caches.appendingPathComponent("original.txt"), encoding: .utf8), "original")
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path + ".wq-preserved"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path + ".wq-transaction.plist"))
            XCTAssertTrue(WQCacheStageRecover(caches.path), "Recovery must be idempotent")
        }
    }

    func testCrashBetweenBackupMoveAndSymlinkCreationCanRecover() throws {
        try withFixture { _, caches, target in
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            try FileManager.default.removeItem(at: caches) // Remove only the staging link.
            XCTAssertTrue(WQCacheStageRecover(caches.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("original.txt").path))
        }
    }

    func testRecoveryFinishesWhenOriginalWasAlreadyRestoredBeforeCrash() throws {
        try withFixture { _, caches, target in
            let fm = FileManager.default
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            try fm.removeItem(at: caches)
            try fm.moveItem(atPath: caches.path + ".wq-preserved", toPath: caches.path)
            XCTAssertTrue(WQCacheStageRecover(caches.path))
            XCTAssertFalse(fm.fileExists(atPath: caches.path + ".wq-transaction.plist"))
        }
    }

    func testReplacementDirectoryIsPreservedAndBlocksRecoveryUntilConflictResolved() throws {
        try withFixture { _, caches, target in
            let fm = FileManager.default
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            try fm.removeItem(at: caches)
            try fm.createDirectory(at: caches, withIntermediateDirectories: false)
            let replacement = caches.appendingPathComponent("new-data.txt")
            try Data("new".utf8).write(to: replacement)
            XCTAssertFalse(WQCacheStageRecover(caches.path))
            XCTAssertEqual(WQCacheStageLastError(), -10)
            XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), "new")
            XCTAssertTrue(fm.fileExists(atPath: caches.path + ".wq-preserved/original.txt"))
            XCTAssertTrue(fm.fileExists(atPath: caches.path + ".wq-transaction.plist"))
            // Resolve only the synthetic conflict in this isolated test directory.
            try fm.moveItem(at: caches, to: caches.deletingLastPathComponent().appendingPathComponent("new-preserved"))
            XCTAssertTrue(WQCacheStageRecover(caches.path))
        }
    }

    func testUnknownLegacyBackupIsNotAdoptedOrRemoved() throws {
        try withFixture { _, caches, target in
            let fm = FileManager.default
            let backup = URL(fileURLWithPath: caches.path + ".wq-preserved")
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data("legacy".utf8).write(to: backup.appendingPathComponent("keep.txt"))
            XCTAssertFalse(WQCacheStageBegin(caches.path, target.path))
            XCTAssertEqual(WQCacheStageLastError(), -9)
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("keep.txt"), encoding: .utf8), "legacy")
            XCTAssertTrue(fm.fileExists(atPath: caches.appendingPathComponent("original.txt").path))
        }
    }

    func testChangedBackupIdentityAndMalformedJournalFailClosed() throws {
        try withFixture { root, caches, target in
            let fm = FileManager.default
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            let backup = URL(fileURLWithPath: caches.path + ".wq-preserved")
            try fm.moveItem(at: backup, to: root.appendingPathComponent("original-preserved"))
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            XCTAssertFalse(WQCacheStageRecover(caches.path))
            XCTAssertEqual(WQCacheStageLastError(), -11)
            try Data("not-a-plist".utf8).write(to: URL(fileURLWithPath: caches.path + ".wq-transaction.plist"))
            XCTAssertFalse(WQCacheStageRecover(caches.path))
            XCTAssertEqual(WQCacheStageLastError(), -12)
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: caches.path), target.path)
        }
    }

    func testMissingCachesAndMissingLibraryAreCreatedOnlyInsideTheFixture() throws {
        try withFixture { _, caches, target in
            let fm = FileManager.default
            try fm.removeItem(at: caches)
            try fm.removeItem(at: caches.deletingLastPathComponent())
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            XCTAssertTrue(WQCacheStageRecover(caches.path))
            var directory: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: caches.path, isDirectory: &directory))
            XCTAssertTrue(directory.boolValue)
        }
    }

    func testNewCacheDataWithoutOriginalDirectoryIsKeptDuringRecovery() throws {
        try withFixture { _, caches, target in
            let fm = FileManager.default
            try fm.removeItem(at: caches)
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            try fm.removeItem(at: caches)
            try fm.createDirectory(at: caches, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: caches.appendingPathComponent("new.txt"))
            XCTAssertTrue(WQCacheStageRecover(caches.path))
            XCTAssertTrue(fm.fileExists(atPath: caches.appendingPathComponent("new.txt").path))
        }
    }

    func testWrongEndTargetDoesNotRemoveTheStagingLink() throws {
        try withFixture { root, caches, target in
            XCTAssertTrue(WQCacheStageBegin(caches.path, target.path))
            XCTAssertFalse(WQCacheStageEnd(caches.path, root.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: caches.path), target.path)
            XCTAssertTrue(WQCacheStageRecover(caches.path))
        }
    }

    func testParentSymlinkIsRejectedWithoutCreatingFilesInItsDestination() throws {
        try withFixture { root, caches, target in
            let fm = FileManager.default
            try fm.removeItem(at: caches.deletingLastPathComponent())
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("Library").path, withDestinationPath: target.path)
            XCTAssertFalse(WQCacheStageBegin(caches.path, target.path))
            XCTAssertEqual(WQCacheStageLastError(), -12)
            XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Caches").path))
        }
    }

    func testFailedSymlinkCreationRollsBackOriginalData() throws {
        try withFixture { _, caches, _ in
            XCTAssertFalse(WQCacheStageBegin(caches.path, String(repeating: "x", count: 8192)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("original.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path + ".wq-preserved"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path + ".wq-transaction.plist"))
        }
    }
}
