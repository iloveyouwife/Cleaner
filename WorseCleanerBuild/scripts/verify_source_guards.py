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
    "Query failure releases resources and restores private staging directory":
        "if (![files createSymbolicLinkAtPath:caches" in query
        and "query_free(query);" in query
        and "if (cacheExists && ![files removeItemAtPath:caches" in query
        and "clean_symlink(group);" in query,
    "Post-cleanup checks never infer bytes freed":
        "postCleanupVerificationFailed" in service
        and "partial.confirmedRemovedItems" in model,
    "Search bulk selection leaves hidden choices untouched":
        "selected.subtracting(visible)" in ui
        and "CleanerSelectionScope.toggle" in ui,
    "LS negative lookup is throttled independently":
        "now - lastMiss < kWCLSReverseRetry" in discovery_objc
        and 'updated[@"lsMissAt"] = @(now);' in discovery_objc,
    "Container discovery aliases are deduplicated":
        "WCPathDiscovery.uniqueContainers(raw.compactMap" in model
        and "seen.insert(WCPathDiscovery.containerIdentity" in model,
    "Verified grant flags are updated":
        "preferredAlternative = alternative" in grant
        and "if preferredAlternative == nil" not in grant,
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
