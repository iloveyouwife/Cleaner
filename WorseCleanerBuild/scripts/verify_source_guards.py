#!/usr/bin/env python3
"""Release gate for the existing sandbox, cleanup scope and scan policy."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
src = root / "WorseCleaner"
service = (src / "LimitedCleanerService.swift").read_text()
engine = (src / "CleanerEngine.swift").read_text()
discovery = (src / "WCPathDiscovery.swift").read_text()
model = (src / "WorseCleanerModel.swift").read_text()
grant = (src / "WCGrant.swift").read_text()
query = (src / "worse_query.m").read_text()
ui = (src / "ContentView.swift").read_text()
discovery_objc = (src / "WCContainerDiscovery.m").read_text()
project = (root / "project.yml").read_text()

checks = {
    "Caches/tmp are the only cleanup directories":
        'static let allowedDirectoryComponents = [["Library", "Caches"], ["tmp"]]' in service,
    "Scanning and cleanup share the allowlist":
        "components: allowedDirectoryComponents[0]" in service
        and "components: allowedDirectoryComponents[1]" in service
        and "for components in allowedDirectoryComponents" in service,
    "Permission and read checks use the same allowlist":
        engine.count("LimitedCleanerService.allowedDirectoryComponents") == 2,
    "Cleanup uses no-follow directory handles":
        "O_NOFOLLOW" in service and "O_NOFOLLOW" in engine
        and "unlinkat(directoryDescriptor" in service,
    "Deletion directory failures are counted":
        "summary.failedItemCount += traversalFailures" in service
        and "if result != 0 && errno != ENOENT" in service
        and "private static func openDirectory(" not in service,
    "No system daemon cleanup root":
        "/private/var/mobile/Containers/Data/InternalDaemon" not in service
        and "/private/var/mobile/Containers/Data/InternalDaemon" not in engine,
    "Container comparisons normalize aliases":
        "mergeContainerCandidates" in discovery
        and "seen.insert(containerIdentity(app.path))" in discovery,
    "Unknown LS stamps invalidate name reuse":
        "stampIsCurrent(scanStartLSStamp, scannedLSStamp)" in model
        and "catalogReuseSeconds: TimeInterval = 180" in model,
    "Query staging preserves existing dedicated group caches":
        "WQCacheStageBegin(caches, target)" in query
        and "WQCacheStageEnd(caches, target)" in query
        and "moveItemAtPath:caches toPath:backup" in query
        and "moveItemAtPath:backup toPath:caches" in query
        and "if (cacheExists && ![files removeItemAtPath:caches" not in query,
    "Query token source and authorization flags unchanged":
        "query_set_class(query, 7)" in query
        and "query_set_part(query, 3)" in query
        and "0x0000000800000000ULL" in query
        and "0x0000008000000000ULL" in query
        and "consume_extension(token)" in query
        and "query_free(query);" in query,
    "Interrupted cleanup verifies already deleted items":
        "beforeOpeningDirectory(components)" in service
        and "removal.failedItemCount += 1" in service
        and "return try resultAfterVerification(" in service,
    "Post-cleanup checks never infer bytes freed":
        "postCleanupVerificationFailed" in service
        and "partial.confirmedRemovedItems" in model,
    "Search bulk selection leaves hidden choices untouched":
        "selected.subtracting(visible)" in ui
        and "CleanerSelectionScope.toggle" in ui,
    "LS negative lookup is throttled independently":
        "now - lastMiss < kWCLSReverseRetry" in discovery_objc
        and 'updated[@"lsMissAt"] = @(now);' in discovery_objc
        and 'sameVolume && saved' in discovery_objc
        and 'sameIndexedVolume && miss' in discovery_objc,
    "Container discovery aliases are deduplicated":
        "WCPathDiscovery.uniqueContainers(raw.compactMap" in model
        and "seen.insert(WCPathDiscovery.containerIdentity" in model,
    "Verified grant flags are updated":
        "preferredAlternative = alternative" in grant
        and "if preferredAlternative == nil" not in grant,
    "App discovery requires explicit App Group confirmation":
        "guard canDiscoverApps else { return }" in model
        and "guard !busy, canDiscoverApps else {" in model
        and "clearDiscoveryWhenUnconfirmed()" in model
        and "CleanerDiscoveryGate.allowsDiscovery" in model
        and "if !wasAllowed && !busy" in model,
    "Only manual exclusions determine eligible scan targets":
        "WCScanExclusions.eligibleTargets" in model
        and "enum WCScanExclusions" in engine
        and "protectedCleanerContainer" not in engine,
    "One stored scan denominator, no per-frame recount":
        "@Published private(set) var scanTargetCount = 0" in model
        and "didSet { refreshScanTargetCount() }" in model
        and "model.scanTargetCount" in ui
        and "model.eligibleContainerCount" not in ui,
    "Progress denominator matches manual exclusion filtering":
        "scanTargetCount = targets.count" in model,
    "Exclusion persistence and management normalize all path aliases":
        "WCScanExclusions.normalizedPaths" in model
        and "WCScanExclusions.excludedTargets" in (src / "CleanerExcludedAppsView.swift").read_text(),
    "Uninstalled and excluded selections cannot stay selected":
        "CleanerSelectionScope.retainingEligible" in ui
        and "selected: selectedIDs, apps: model.apps, excludedPaths: excluded" in ui,
    "Available cache bytes are cached only after list changes":
        "@State private var availableSize: Int64 = 0" in ui
        and "CleanerCacheSummary.availableBytes(" in ui
        and "model.apps.reduce" not in ui,
    "Unit test suite included in scheme":
        "CleanerUnitTests: [test]" in project and "- CleanerUnitTests" in project,
}
marketing = re.search(r"MARKETING_VERSION:\s*0\.(\d+)\.0", project)
build = re.search(r"CURRENT_PROJECT_VERSION:\s*(\d+)", project)
checks["Version and build match"] = bool(
    marketing and build and marketing.group(1) == build.group(1)
)
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {label}")
if not all(checks.values()):
    raise SystemExit(1)
