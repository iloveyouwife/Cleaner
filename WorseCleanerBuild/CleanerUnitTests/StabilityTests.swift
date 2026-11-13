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
}
