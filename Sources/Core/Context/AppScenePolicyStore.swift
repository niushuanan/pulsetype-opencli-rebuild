import Foundation

struct AppScenePolicy: Identifiable, Codable, Equatable {
    let id: String
    var appName: String
    var bundleID: String
    var appPrompt: String

    init(
        appName: String,
        bundleID: String,
        appPrompt: String
    ) {
        self.id = bundleID
        self.appName = appName
        self.bundleID = bundleID
        self.appPrompt = appPrompt
    }
}

@MainActor
final class AppScenePolicyStore: ObservableObject {
    @Published private(set) var policies: [AppScenePolicy]

    private let defaults: UserDefaults
    private let storageKey = "scene.policy.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.policies = AppScenePolicyStore.loadPolicies(defaults: defaults)
    }

    func policy(for context: FocusedAppContext) -> AppScenePolicy {
        if let existing = policies.first(where: { $0.bundleID == context.bundleID }) {
            return existing
        }
        return AppScenePolicy(
            appName: context.appName,
            bundleID: context.bundleID,
            appPrompt: ""
        )
    }

    func hasStoredPolicy(bundleID: String) -> Bool {
        policies.contains { $0.bundleID == bundleID }
    }

    func upsertPolicy(
        for context: FocusedAppContext,
        appPrompt: String
    ) {
        upsertPolicy(
            appName: context.appName,
            bundleID: context.bundleID,
            appPrompt: appPrompt
        )
    }

    func upsertPolicy(
        appName: String,
        bundleID: String,
        appPrompt: String
    ) {
        let next = AppScenePolicy(
            appName: appName,
            bundleID: bundleID,
            appPrompt: appPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if let index = policies.firstIndex(where: { $0.bundleID == bundleID }) {
            policies[index] = next
        } else {
            policies.append(next)
        }
        persist()
    }

    func removePolicy(bundleID: String) {
        policies.removeAll { $0.bundleID == bundleID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(policies) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadPolicies(defaults: UserDefaults) -> [AppScenePolicy] {
        guard
            let data = defaults.data(forKey: "scene.policy.v1"),
            let decoded = try? JSONDecoder().decode([AppScenePolicy].self, from: data)
        else {
            return []
        }
        return decoded
    }
}
