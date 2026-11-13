import Foundation

/// Pure ownership checks. Display names and preference filenames alone are
/// deliberately insufficient to identify another application's data container.
enum WCIdentityEvidence {
    static func agreedIdentifier(_ evidence: [String?]) -> String? {
        let ids = Set(evidence.compactMap { $0 })
        return ids.count == 1 ? ids.first : nil
    }

    static func pathConfirmedIdentifier(
        _ candidates: Set<String>, containerPath: String,
        lookup: (String) -> String?
    ) -> String? {
        let identity = WCPathDiscovery.containerIdentity(containerPath)
        let confirmed = candidates.filter { candidate in
            guard let path = lookup(candidate), WCFileAccess.isValidApplicationContainer(path) else {
                return false
            }
            return WCPathDiscovery.containerIdentity(path) == identity
        }
        return confirmed.count == 1 ? confirmed.first : nil
    }
}

enum WCManualContainerPath {
    static func resolve(
        _ input: String, knownTargets: [WCTarget],
        presence: (String) -> WCContainerPresence = WCPathDiscovery.containerPresence
    ) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if WCFileAccess.isValidApplicationContainer(input) {
            return URL(fileURLWithPath: input).standardizedFileURL.path
        }
        guard let uuid = UUID(uuidString: input) else { throw WCFailure.invalidTarget }
        let known = WCPathDiscovery.uniqueContainers(knownTargets.filter {
            UUID(uuidString: URL(fileURLWithPath: $0.path).lastPathComponent) == uuid
        })
        if known.count == 1 { return known[0].path }
        guard known.isEmpty else { throw WCFailure.unresolvedManualContainer }

        let roots = ["Application", "PluginKitPlugin"].map {
            "/var/mobile/Containers/Data/\($0)/\(uuid.uuidString)"
        }
        let observations = roots.map { ($0, presence($0)) }
        let present = observations.filter { $0.1 == .present }
        // EPERM/unknown on the other root is not proof that only one exists.
        guard present.count == 1, observations.allSatisfy({ $0.1 != .unknown }) else {
            throw WCFailure.unresolvedManualContainer
        }
        return present[0].0
    }
}
